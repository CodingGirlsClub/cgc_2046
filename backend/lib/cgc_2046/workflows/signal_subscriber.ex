defmodule Cgc2046.Workflows.SignalSubscriber do
  @moduledoc """
  信号订阅方骨架（异步链路深化 PR-B；plan 2026-08-14-003 Q1-Q3/Q9-Q11/D2-D3）。

  订阅方经 `use` 注入共享骨架，业务模块只剩 `handle/2` 函数子句与业务体。
  订阅生命周期（订阅/失败即崩/forwarder DOWN 重订阅）、rescue 壳、幂等 claim
  时机、消费键派生全部由本骨架唯一持有——**幂等语义事实以本 moduledoc 为
  唯一权威**（历史六订阅方的散落注释已删）。

  ## 使用

      use Cgc2046.Workflows.SignalSubscriber,
        patterns: ["enrollment.completed"],
        idempotency: :claim_first

      @impl Cgc2046.Workflows.SignalSubscriber
      def handle("enrollment.completed", %{"enrollment_id" => id}), do: ...

  opts：

  - `patterns`：订阅的信号类型列表（必填、非空字符串列表；生成 `patterns/0`
    供测试断言接线）。
  - `idempotency`：幂等策略枚举（必填），四策略语义如下。缺 `handle/2`
    回调在编译期告警（behaviour 检查）。

  ## 幂等四策略（Q2 如实映射六订阅方现状语义；PR-B 评审 P1 增补第四值）

  - `:claim_first`：副作用前先 claim（NotificationSubscriber / SpeakerSubscriber）。
    首投 claim 成功 → 执行 `handle/2`；重复投递 `{:error, :already_claimed}` →
    返回 `:duplicate` 跳过执行。claim 成功后执行失败不回滚 claim（副作用均可
    达重投/对账路径，失败可见性靠 error 日志与 E-10 对账扫描）。
  - `:claim_in_handle`：claim 时机由模块在 `handle/2` 内自决——业务校验链通过后、
    副作用前调 `claim/3`（LearningInstantiator）。校验不过（如无已发布学习定义、
    瞬时读失败）不烧 claim，重投仍可推进；重复投递由模块自行归一化（LI 归一为
    `:ok`，同其旧 `instantiate_from_signal/2` 语义）。消费键派生仍由本骨架唯一持有。
  - `:claim_after_effects`：全部副作用成功（`handle/2` 返回 `:ok`）才 claim
    （SponsorshipEndedSubscriber / ResearchRunReaper）；`{:error, reason}` 不落
    claim、只记 error 日志不 crash forwarder——重投（SignalPublishWorker 重试
    或对账）仍会执行，逃逸行不会与「已完成」claim 并存。
  - `:state_based`：不写 claim，靠业务状态守卫幂等（ResearchInstantiator 的
    find_or_create run）。

  ## 消费键规则（Q12）

  claim 键 = `payload["idempotency_key"] <> ":" <> 消费者短名`（模块名最后一段
  `Macro.underscore`，如 `:learning_instantiator`）。生产者键由 SignalEmitter
  统一注入（`"<type>:<record_id>"`），消费者作用域后缀保证多订阅方对同一信号
  各自独立去重。payload 缺 `idempotency_key` = 生产者契约违约：记 error 并丢弃
  （不执行副作用）。

  ## 订阅生命周期（Q3 / D3）

  init 逐 pattern 订阅，任一失败即 `{:stop, reason}`（进程不启动，监督树
  重启重试，不再 Logger.warning 后聋着活）。转发进程（JidoAdapter 内 spawn
  的 forwarder）与订阅方进程崩溃隔离；其 DOWN 由骨架 monitor 捕获并自动
  重建该 pattern 订阅（自 LearningInstantiator 上收，六方共享；重订阅失败
  同样 {:stop, reason} 交监督树）。信号投递统一经 `run/3`——生产 forwarder
  与测试（`deliver/2`）同码。
  """

  require Logger

  alias Cgc2046.Workflows.SignalIdempotency

  @idempotency_strategies [:claim_first, :claim_in_handle, :claim_after_effects, :state_based]

  @callback handle(String.t(), map()) :: :ok | {:error, term()}

  # --- 投递入口（生产 forwarder 与测试同码） -----------------------------------

  @doc """
  同步投递一条信号给订阅方模块（`%{type: type, data: data}`，与 JidoAdapter
  解包后的形状一致）。按模块声明的幂等策略执行 claim 时机并调用 `handle/2`。

  返回 `:ok` / `:duplicate`（claim_first 重复投递）/ `{:error, reason}`（副作用
  失败、缺消费键或 rescue 捕获——forwarder 忽略返回值，不 crash）。
  """
  @spec deliver(module(), %{type: String.t(), data: map()}) ::
          :ok | :duplicate | {:error, term()}
  def deliver(module, %{type: type, data: data}) do
    run(module, type, data)
  end

  @doc """
  消费键 claim 助手（`:claim_in_handle` 策略模块在业务校验链通过后、副作用前
  调用）。键派生与缺失契约违约的丢弃逻辑由本骨架唯一持有。

  返回 `{:ok, full_key}`（首次登记）| `:duplicate`（同键已消费，调用方按需
  归一化）| `{:error, :missing_idempotency_key}`（payload 缺幂等键，丢弃）。
  """
  @spec claim(module(), String.t(), map()) ::
          {:ok, String.t()} | :duplicate | {:error, :missing_idempotency_key}
  def claim(module, type, data) do
    with {:ok, key} <- consumer_key(module, type, data) do
      case SignalIdempotency.claim(type, key, data["workspace_id"]) do
        :ok -> {:ok, key}
        {:error, :already_claimed} -> :duplicate
      end
    end
  end

  @doc false
  # forwarder 回调入口（JidoAdapter.subscribe 的 fun）；与 deliver/2 同码。
  def run(module, type, data) do
    case module.__signal_subscriber_config__().idempotency do
      strategy when strategy in [:state_based, :claim_in_handle] ->
        module.handle(type, data)

      :claim_first ->
        case claim(module, type, data) do
          {:ok, _key} -> module.handle(type, data)
          :duplicate -> :duplicate
          {:error, _reason} = error -> error
        end

      :claim_after_effects ->
        with {:ok, key} <- consumer_key(module, type, data) do
          case module.handle(type, data) do
            :ok ->
              case SignalIdempotency.claim(type, key, data["workspace_id"]) do
                :ok -> :ok
                {:error, :already_claimed} -> :ok
              end

            {:error, reason} = error ->
              Logger.error(
                "#{inspect(module)} effects failed for #{type}: #{inspect(reason)}; " <>
                  "claim skipped for redelivery"
              )

              error
          end
        end
    end
  rescue
    error ->
      Logger.error("#{inspect(module)} handling #{type} crashed: #{Exception.message(error)}")

      {:error, {:crashed, Exception.message(error)}}
  end

  defp consumer_key(module, type, data) do
    case data do
      %{"idempotency_key" => key} when is_binary(key) ->
        {:ok, key <> ":" <> consumer_suffix(module)}

      _other ->
        Logger.error(
          "#{inspect(module)} received #{type} without payload idempotency_key " <>
            "(SignalEmitter 注入契约违约，信号丢弃)"
        )

        {:error, :missing_idempotency_key}
    end
  end

  defp consumer_suffix(module) do
    module |> Module.split() |> List.last() |> Macro.underscore()
  end

  # --- use 注入 -----------------------------------------------------------------

  defmacro __using__(opts) do
    patterns = Keyword.fetch!(opts, :patterns)
    idempotency = Keyword.fetch!(opts, :idempotency)

    unless patterns != [] and Enum.all?(patterns, &is_binary/1) do
      raise ArgumentError, "patterns 须为非空字符串列表：#{inspect(patterns)}"
    end

    unless idempotency in @idempotency_strategies do
      raise ArgumentError,
            "idempotency 须为 #{inspect(@idempotency_strategies)} 之一：#{inspect(idempotency)}"
    end

    quote do
      use GenServer

      require Logger

      @behaviour Cgc2046.Workflows.SignalSubscriber

      @doc "当前订阅的信号类型列表（骨架 init 逐个订阅；测试断言接线用）。"
      def patterns, do: unquote(patterns)

      @doc false
      def __signal_subscriber_config__ do
        %{idempotency: unquote(idempotency)}
      end

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

      @impl GenServer
      def init(_opts) do
        case subscribe_all() do
          {:ok, subscriptions} -> {:ok, %{subscriptions: subscriptions}}
          {:error, reason} -> {:stop, reason}
        end
      end

      @impl GenServer
      def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
        case Map.pop(state.subscriptions, ref) do
          {pattern, subscriptions} when is_binary(pattern) ->
            Logger.warning(
              "#{inspect(__MODULE__)} forwarder for #{pattern} down: #{inspect(reason)}; " <>
                "resubscribing"
            )

            case subscribe_pattern(pattern, subscriptions) do
              {:ok, subscriptions} ->
                {:noreply, %{state | subscriptions: subscriptions}}

              {:error, reason} ->
                Logger.error(
                  "#{inspect(__MODULE__)} resubscribe failed for #{pattern}: #{inspect(reason)}; " <>
                    "stopping for supervisor restart"
                )

                {:stop, reason, state}
            end

          {_missing, _} ->
            {:noreply, state}
        end
      end

      def handle_info(_other, state), do: {:noreply, state}

      defp subscribe_all do
        Enum.reduce_while(patterns(), {:ok, %{}}, fn pattern, {:ok, acc} ->
          case subscribe_pattern(pattern, acc) do
            {:ok, acc} -> {:cont, {:ok, acc}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end

      # 订阅失败返回 {:error, reason}：init 即停（Q3，监督树重启重试，不聋着活）。
      defp subscribe_pattern(pattern, acc) do
        case Cgc2046.Workflows.JidoAdapter.subscribe(pattern, fn type, data ->
               Cgc2046.Workflows.SignalSubscriber.run(__MODULE__, type, data)
             end) do
          {:ok, _subscription_id, monitor_ref} ->
            {:ok, Map.put(acc, monitor_ref, pattern)}

          {:error, reason} ->
            {:error, {:subscribe_failed, pattern, reason}}
        end
      end
    end
  end
end
