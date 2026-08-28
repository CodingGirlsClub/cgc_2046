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
  - `idempotency`：幂等策略枚举（必填），四策略语义如下。`handle/2`、
    `before_claim/2`、`effects/3` 均为 `@optional_callbacks`（编译期不告警缺
    实现）：非 claim_in_handle 策略实现 `handle/2`，claim_in_handle 实现
    `before_claim/2` + `effects/3`（缺双回调在投递时 `raise ArgumentError`）。
  - `max_retries`：bus 退避重试上限（可选，默认 30）。达到后转低频无限探测
    而非放弃（#244）。测试 fixture 注入小值使 give-up→探测→恢复秒级完成。
  - `probe_interval_ms`：探测模式下两次 `:bus_resubscribe` 探测的间隔毫秒
    （可选，默认 30_000）。

  ## 幂等四策略（Q2 如实映射六订阅方现状语义；PR-B 评审 P1 增补第四值）

  - `:claim_first`：副作用前先 claim（NotificationSubscriber / SpeakerSubscriber）。
    首投 claim 成功 → 执行 `handle/2`；重复投递 `{:error, :already_claimed}` →
    返回 `:duplicate` 跳过执行。claim 成功后执行失败不回滚 claim（副作用均可
    达重投/对账路径，失败可见性靠 error 日志与 E-10 对账扫描）。
  - `:claim_in_handle`：**双回调结构**（架构深化 G 方向②）——模块实现
    `before_claim/2`（校验链）+ `effects/3`（副作用），claim 时机由骨架持有：
    `before_claim` 返回 `{:ok, ctx}` → 骨架 claim → `effects(type, data, ctx)`；
    返回 `:skip` / `{:error, _}` → 不烧 claim、归一化 `:ok`（best-effort，重投
    仍可推进；warning 由 before_claim 内保留文案承担，骨架不重复记日志；缺
    idempotency_key 同样归一化不上抛）；claim 重复投递 `:duplicate`
    → `:ok`（不重复执行 effects）。声明该策略但未实现双回调 → `raise ArgumentError`。
    消费键派生仍由本骨架唯一持有。历史 post-hoc 检测方案（B 版）因无法区分
    「校验不过合法 skip」与「忘调 claim」被证伪，弃用。
  - `:claim_after_effects`：全部副作用成功（`handle/2` 返回 `:ok`）才 claim
    （SponsorshipEndedSubscriber / Curriculum.Reaper）；`{:error, reason}` 不落
    claim、只记 error 日志不 crash forwarder——重投（SignalPublishWorker 重试
    或对账）仍会执行，逃逸行不会与「已完成」claim 并存。
  - `:state_based`：不写 claim，靠业务状态守卫幂等（Curriculum.Instantiator 的
    find_or_create run）。

  ## 消费键规则（Q12）

  claim 键 = `payload["idempotency_key"] <> ":" <> 消费者短名`（模块名最后一段
  `Macro.underscore`，如 `:learning_instantiator`）。生产者键由 SignalEmitter
  统一注入（`"<type>:<record_id>"`），消费者作用域后缀保证多订阅方对同一信号
  各自独立去重。payload 缺 `idempotency_key` = 生产者契约违约：记 error 并丢弃
  （不执行副作用）。

  ## 订阅生命周期（Q3 / D3 / #120）

  init 逐 pattern 订阅，任一失败即 `{:stop, reason}`（进程不启动，监督树
  重启重试，不再 Logger.warning 后聋着活）；唯一例外是 bus 未注册
  （`:not_found`）——顺序上 bus 先于全部订阅方启动，此为防御分支，走退避
  重试而非 `{:stop}`。转发进程（JidoAdapter 内 spawn 的 forwarder）与订阅方
  进程崩溃隔离；其 DOWN 由骨架 monitor 捕获并自动重建该 pattern 订阅
  （自 LearningInstantiator 上收，全部 8 订阅方共享；重订阅失败同样
  {:stop, reason} 交监督树）。

  **bus 重启重订阅（#120）**：订阅表存于 bus 进程内存（无 journal），bus 崩溃
  重启后清空，而订阅方 monitor 的是 forwarder——bus 死不产生任何 DOWN。故
  骨架 init 时额外 monitor bus pid，收到 bus DOWN 后：demonitor 并对全部旧
  forwarder 走 drain 回收（`JidoAdapter.drain_forwarders`——投递 `:reclaim`
  等在途投递完成后自退，spawn 无 link 不回收则每次 bus 重启泄漏），再对全部
  patterns 重订阅。**drain 语义（#245）**：claim 与 effects 必须在 forwarder
  进程内同步执行——forwarder 在 `fun.()` 执行中收不到消息，`:reclaim` 落邮箱
  仅在 fun 跑完后处理，kill 截断「claim 已烧、effects 未执行」的窗口因此闭合；
  若未来 effects 异步化则前提失效，drain 降级为超时强杀（不劣化旧行为）。残余
  窗口：fun 卡死超过 drain 超时（5s）仍被强杀截断——概率缩小非零，兜底是
  SignalIdempotency claim + E-10 对账。drain 在旁路 waiter 异步完成，bus DOWN
  恢复路径照旧立即退避重订阅。重订阅的顺序是「先 whereis → 先 monitor pid →
  按 pid 订阅 → 核对 whereis 仍 == pid」（advisor M2）：订阅行与 monitor 落在
  同一 bus incarnation，消灭「订阅落旧 bus、monitor 新 bus，旧 bus 死亡无感知」
  的静默失聪；订阅在途 bus 被杀的 exit 被 catch 归一化，不炸订阅方。退避
  重试（`:not_found` / 瞬错如 `:timeout`）一律不 `{:stop}`：指数退避 100ms
  起 ×2 封顶 5s（防 crash-loop、重订阅风暴、one_for_one 共享强度预算耗尽）。
  退避耗尽（max_retries 次）不放弃——转低频无限探测（#244）：一次性 error
  告警 + telemetry `:give_up` 后按 probe_interval 持续 `:bus_resubscribe`
  探测（`bus_retries` 保持 max 不递增防刷屏）；bus 回归 → 全量重订阅成功 →
  自动回到正常态并 telemetry `:recovered`（订阅方永不永久失聪，>2min outage
  后 30s 内恢复）。重启窗口内已丢信号不可恢复，兜底是 SignalIdempotency
  claim + E-10 对账扫描。已恢复订阅时杂散 `:bus_resubscribe` 消息是真
  no-op（`map_size` guard，防双订阅双投递）。信号投递统一经 `run/3`——
  生产 forwarder 与测试（`deliver/2`）同码。
  """

  require Logger

  alias Cgc2046.Workflows.SignalIdempotency

  @idempotency_strategies [:claim_first, :claim_in_handle, :claim_after_effects, :state_based]

  # D7（E-10 #125）：信号投递 telemetry——与 NotificationFanout 的
  # `[:cgc2046, :notification_fanout, :deliver]` 事件族同构（measurements %{count}，
  # metadata status/type/detail）；死信可见性由 E-10 对账规则⑥（oban_jobs discarded
  # 7 天窗口）承担，不扩 Oban discard 插件。
  @telemetry_event [:cgc2046, :signal, :deliver]

  # #244：bus 退避 give-up（进入探测模式）与探测恢复（bus 回归重订阅成功）的
  # 一次性事件——give_up measurements %{retries}、recovered measurements %{count}，
  # metadata subscriber 名，与既有 deliver 事件族同构。
  @telemetry_give_up_event [:cgc2046, :signal_subscriber, :give_up]
  @telemetry_recovered_event [:cgc2046, :signal_subscriber, :recovered]

  @callback handle(String.t(), map()) :: :ok | {:error, term()}

  # claim_in_handle 双回调（架构深化 G，方向②）：before_claim 校验链（通过返回
  # ctx 供 effects 消费；:skip / {:error, _} 不烧 claim）+ effects 副作用。claim
  # 时机由骨架持有（before_claim 后、effects 前），不再依赖模块自调。
  @callback before_claim(String.t(), map()) ::
              {:ok, term()} | :skip | {:error, term()}

  @callback effects(String.t(), map(), term()) :: :ok | {:error, term()}

  @optional_callbacks handle: 2, before_claim: 2, effects: 3

  # --- 投递入口（生产 forwarder 与测试同码） -----------------------------------

  @doc """
  同步投递一条信号给订阅方模块（`%{type: type, data: data}`，与 JidoAdapter
  解包后的形状一致）。按模块声明的幂等策略执行 claim 时机：claim_first /
  claim_after_effects / state_based 调用 `handle/2`；claim_in_handle 调用
  `before_claim/2` + `effects/3` 双回调（claim 由骨架持有）。

  返回 `:ok` / `:duplicate`（claim_first 重复投递）/ `{:error, reason}`（副作用
  失败、缺消费键或 rescue 捕获——forwarder 忽略返回值，不 crash）。
  """
  @spec deliver(module(), %{type: String.t(), data: map()}) ::
          :ok | :duplicate | {:error, term()}
  def deliver(module, %{type: type, data: data}) do
    run(module, type, data)
  end

  @doc """
  消费键 claim 助手（**骨架内部使用**：claim_first 分支与 claim_in_handle 的
  run_claim_in_handle 调用；订阅方不再自调——双回调结构化后 claim 时机由
  骨架持有）。键派生与缺失契约违约的丢弃逻辑由本骨架唯一持有。

  返回 `{:ok, full_key}`（首次登记）| `:duplicate`（同键已消费，骨架归一化
  为跳过 effects）| `{:error, :missing_idempotency_key}`（payload 缺幂等键，
  归一化 :ok 丢弃）。
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
  # 投递结果统一 emit `[:cgc2046, :signal, :deliver]` telemetry（D7）。
  def run(module, type, data) do
    result = do_run(module, type, data)
    emit(module, type, result)
    result
  end

  defp do_run(module, type, data) do
    case module.__signal_subscriber_config__().idempotency do
      :claim_in_handle ->
        run_claim_in_handle(module, type, data)

      :state_based ->
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
    # 编程错误（如声明 claim_in_handle 未实现双回调）向上抛，交 forwarder/监督树
    # 处理；其余运行时异常照旧捕获归一化为 {:error, {:crashed, _}}。
    error in ArgumentError ->
      reraise error, __STACKTRACE__

    error ->
      Logger.error("#{inspect(module)} handling #{type} crashed: #{Exception.message(error)}")

      {:error, {:crashed, Exception.message(error)}}
  end

  # D7：metadata status/detail 同 NotificationFanout `[:cgc2046, :notification_fanout,
  # :deliver]` 事件族同构；type 为信号类型、subscriber 为消费方短名（路由/归因用）。
  defp emit(module, type, result) do
    {status, detail} =
      case result do
        :ok -> {:ok, nil}
        :duplicate -> {:duplicate, nil}
        {:error, reason} -> {:error, reason}
      end

    :telemetry.execute(@telemetry_event, %{count: 1}, %{
      status: status,
      type: type,
      detail: detail,
      subscriber: module |> Module.split() |> List.last()
    })
  end

  # #244：bus 退避 give-up / 探测恢复一次性事件（quote 注入代码经骨架函数 emit，
  # 与 @telemetry_event 同构——属性单一持有于骨架模块，订阅方不重复声明）。
  @doc false
  def emit_give_up(module, retries) do
    :telemetry.execute(@telemetry_give_up_event, %{retries: retries}, %{
      subscriber: module |> Module.split() |> List.last()
    })
  end

  @doc false
  def emit_recovered(module) do
    :telemetry.execute(@telemetry_recovered_event, %{count: 1}, %{
      subscriber: module |> Module.split() |> List.last(),
      was_probe: true
    })
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

  # G（2026-08-17-004，方向②）：claim_in_handle 双回调执行。before_claim 校验
  # 通过 → 骨架 claim → effects；:skip / {:error, _} → 不烧 claim、归一化 :ok
  # （warning 由 before_claim 内保留文案承担，骨架不重复记日志）；claim
  # :duplicate → :ok（不重复执行 effects）。缺 idempotency_key（claim 返回
  # {:error, _}）归一化为 :ok 不上抛——consumer_key 已在该路径记违约日志。
  # 声明策略但未实现双回调 = 编程错误，raise ArgumentError。
  defp run_claim_in_handle(module, type, data) do
    unless function_exported?(module, :before_claim, 2) and
             function_exported?(module, :effects, 3) do
      raise ArgumentError,
            "#{inspect(module)} declares idempotency: :claim_in_handle but does not " <>
              "implement before_claim/2 and effects/3"
    end

    case module.before_claim(type, data) do
      {:ok, ctx} ->
        case claim(module, type, data) do
          {:ok, _key} ->
            case module.effects(type, data, ctx) do
              :ok ->
                :ok

              {:error, reason} = error ->
                Logger.error(
                  "#{inspect(module)} claim_in_handle effects failed for #{type}: #{inspect(reason)}"
                )

                error
            end

          :duplicate ->
            :ok

          {:error, _reason} ->
            :ok
        end

      :skip ->
        # 校验不过/无定义等合法 skip：不烧 claim、归一化 :ok（重投仍可推进）。
        # 详细 warning 由 before_claim 内保留文案承担——骨架不重复记日志
        # （G 方向②，避免每次合法 skip 双重噪声）。
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  # --- use 注入 -----------------------------------------------------------------

  defmacro __using__(opts) do
    patterns = Keyword.fetch!(opts, :patterns)
    idempotency = Keyword.fetch!(opts, :idempotency)

    # #244：退避参数可注入（仅测试 fixture 用毫秒级小值；生产默认不变）。
    # max_retries 默认 30；probe_interval_ms 默认 30s——give-up 后转低频无限探测。
    max_retries = Keyword.get(opts, :max_retries, 30)
    probe_interval_ms = Keyword.get(opts, :probe_interval_ms, 30_000)

    unless patterns != [] and Enum.all?(patterns, &is_binary/1) do
      raise ArgumentError, "patterns 须为非空字符串列表：#{inspect(patterns)}"
    end

    unless idempotency in @idempotency_strategies do
      raise ArgumentError,
            "idempotency 须为 #{inspect(@idempotency_strategies)} 之一：#{inspect(idempotency)}"
    end

    # #244（B1）：退避参数编译期校验（与 patterns/idempotency 守卫同契约）——
    # 非正整数会在 give-up 分支 raise（crash-loop 根监督树）或静默改变退避语义
    # （max_retries 字符串 → 项序永假 → 永不 give-up 的失聪回退）；0 探测间隔
    # 即热循环风暴。编译期失败，零运行时成本。
    unless is_integer(max_retries) and max_retries > 0 do
      raise ArgumentError, "max_retries 须为正整数：#{inspect(max_retries)}"
    end

    unless is_integer(probe_interval_ms) and probe_interval_ms > 0 do
      raise ArgumentError, "probe_interval_ms 须为正整数毫秒：#{inspect(probe_interval_ms)}"
    end

    quote do
      use GenServer

      require Logger

      @behaviour Cgc2046.Workflows.SignalSubscriber

      # bus 退避重试参数（#120 / #244）：100ms 起 ×2 封顶 5s；max_retries 次仍
      # 无 bus 则转低频无限探测（30s 间隔），不再放弃失聪。
      @bus_retry_base_ms 100
      @bus_retry_cap_ms 5_000
      @bus_max_retries unquote(max_retries)
      @bus_probe_interval_ms unquote(probe_interval_ms)

      @doc "当前订阅的信号类型列表（骨架 init 逐个订阅；测试断言接线用）。"
      def patterns, do: unquote(patterns)

      @doc false
      def __signal_subscriber_config__ do
        %{idempotency: unquote(idempotency)}
      end

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

      @impl GenServer
      def init(_opts) do
        case full_resubscribe(initial_state()) do
          {:ok, state} ->
            {:ok, state}

          {:error, :bus_missing, state} ->
            # 防御（#120）：bus 未注册——顺序上 bus 先于全部订阅方启动（child
            # #6 vs #8-15），此为兜底。退避重试而非 {:stop}，防 init 竞态崩循环。
            {:ok, schedule_bus_retry(state)}

          {:error, reason, _state} ->
            {:stop, reason}
        end
      end

      # bus DOWN（#120）：订阅表存于 bus 进程内存，随 bus 消亡；forwarder 却
      # 活着（spawn 无 link）——没有 forwarder DOWN 可感知，故骨架自 monitor
      # bus。回收全部旧 forwarder（防泄漏）后退避重订阅：bus 刚死，立即重订阅
      # 大概率仍 :not_found，交给统一退避路径。
      @impl GenServer
      def handle_info({:DOWN, ref, :process, _pid, reason}, %{bus_monitor: ref} = state) do
        Logger.warning(
          "#{inspect(__MODULE__)} signal bus down: #{inspect(reason)}; " <>
            "reclaiming forwarders and resubscribing on backoff"
        )

        {:noreply,
         state
         |> reclaim_forwarders()
         |> Map.merge(%{bus_monitor: nil, bus_retries: 0})
         |> schedule_bus_retry()}
      end

      @impl GenServer
      def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
        case Map.pop(state.subscriptions, ref) do
          {pattern, subscriptions} when is_binary(pattern) ->
            Logger.warning(
              "#{inspect(__MODULE__)} forwarder for #{pattern} down: #{inspect(reason)}; " <>
                "resubscribing"
            )

            state = %{
              state
              | subscriptions: subscriptions,
                forwarders: Map.delete(state.forwarders, ref)
            }

            case subscribe_pattern(pattern, state) do
              {:ok, state} ->
                {:noreply, state}

              {:error, :bus_missing} ->
                # bus 恰好缺席（bus DOWN 尚在邮箱排队）：订阅表已随 bus 消亡，
                # 全部 patterns 都需重建——转入统一 bus 退避路径，不 {:stop}。
                # 先 demonitor+flush 排队中的 bus DOWN（advisor A4）：防它稍后
                # 再触发 bus DOWN 分支形成双定时链 / bus_retries 跨路径错乱。
                {:noreply,
                 state
                 |> demonitor_bus_monitor()
                 |> reclaim_forwarders()
                 |> schedule_bus_retry()}

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

      # 退避重试到期（#120）：bus 回归则全量重订阅（先 whereis 探测，未回归时
      # 不 spawn 空 forwarder）。subscriptions 非空 = 已恢复（杂散定时器）→ 真
      # no-op 防重复订阅双投递——map 模式 %{subscriptions: %{}} 是子集匹配、
      # 匹配任意 map，不构成空守卫（advisor M1），故用 map_size guard。
      @impl GenServer
      def handle_info(:bus_resubscribe, %{subscriptions: subscriptions} = state)
          when map_size(subscriptions) == 0 do
        case Cgc2046.Workflows.JidoAdapter.whereis_bus() do
          {:ok, _pid} ->
            # #244：探测模式下恢复（was_probing）→ 发 recovered 一次性事件
            was_probing = state.bus_probing

            case full_resubscribe(state) do
              {:ok, state} ->
                if was_probing do
                  Cgc2046.Workflows.SignalSubscriber.emit_recovered(__MODULE__)
                end

                {:noreply, state}

              {:error, :bus_missing, state} ->
                {:noreply, schedule_bus_retry(state)}

              # 瞬错（如 :timeout）同样退避不 {:stop}（advisor M3）：退避路径下
              # {:stop} 计入 one_for_one 共享强度预算（3 次/5s），crash-loop 下
              # 正是放大器——耗尽即根监督树停机。退避重试有界；max_retries 次
              # 后转低频无限探测（#244，不再放弃）。探测态瞬错（bus 已注册但
              # subscribe 持续失败）降 warning——30s 低频下每订阅方一行，不绕过
              # 不刷屏设计，文案同正常退避态。
              {:error, reason, state} ->
                log_level = if state.bus_probing, do: :warning, else: :error

                Logger.log(
                  log_level,
                  "#{inspect(__MODULE__)} bus resubscribe failed: #{inspect(reason)}; " <>
                    "retrying on backoff"
                )

                {:noreply, schedule_bus_retry(state)}
            end

          {:error, :not_found} ->
            {:noreply, schedule_bus_retry(state)}
        end
      end

      def handle_info(:bus_resubscribe, state), do: {:noreply, state}

      def handle_info(_other, state), do: {:noreply, state}

      defp initial_state do
        %{
          subscriptions: %{},
          forwarders: %{},
          bus_monitor: nil,
          bus_retries: 0,
          bus_probing: false
        }
      end

      # 完整重订阅（init / 退避重试共用；advisor M2 顺序）：先 whereis → 先
      # monitor pid → 再**按 pid** 订阅全部 patterns → 完成后核对 whereis 仍
      # == pid。monitor 先行保证：订阅建立后该 incarnation 的任何死亡必产
      # DOWN（消灭「订阅落 B1、monitor B2，B1 死亡无感知」的 #120 同款静默
      # 失聪）；按 pid 订阅保证订阅行与 monitor 同 incarnation（按名字订阅会
      # 在间隙遭遇替换）。末尾核对处理「订阅成功但 bus 随即被替换、DOWN 仍在
      # 邮箱排队」的窗口：显式 demonitor+flush（顺带清掉该 DOWN）+ reclaim +
      # 退避，不依赖邮箱排队延迟。失败路径先回收已建 forwarder（幂等）。
      defp full_resubscribe(state) do
        case Cgc2046.Workflows.JidoAdapter.whereis_bus() do
          {:ok, pid} ->
            bus_monitor = Process.monitor(pid)

            case subscribe_all(state, pid) do
              {:ok, state} ->
                if bus_still_registered_as?(pid) do
                  {:ok, %{state | bus_monitor: bus_monitor, bus_retries: 0, bus_probing: false}}
                else
                  Process.demonitor(bus_monitor, [:flush])
                  {:error, :bus_missing, reclaim_forwarders(state)}
                end

              {:error, reason} ->
                Process.demonitor(bus_monitor, [:flush])
                {:error, reason, reclaim_forwarders(state)}
            end

          {:error, :not_found} ->
            {:error, :bus_missing, state}
        end
      end

      defp bus_still_registered_as?(pid) do
        case Cgc2046.Workflows.JidoAdapter.whereis_bus() do
          {:ok, ^pid} -> true
          _other -> false
        end
      end

      defp subscribe_all(state, bus_pid) do
        Enum.reduce_while(patterns(), {:ok, state}, fn pattern, {:ok, acc} ->
          case subscribe_pattern(pattern, acc, bus_pid) do
            {:ok, acc} -> {:cont, {:ok, acc}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end

      # 订阅失败返回 {:error, reason}：init 即停（Q3，监督树重启重试，不聋着活）。
      # :not_found（bus 未注册）归一化为 :bus_missing，走退避路径（#120）。
      # GenServer.call 在途对端被 :kill → exit(:killed)：jido bus_call 只 catch
      # noproc/timeout，会穿透炸掉订阅方进程——try/catch 归一化 :not_found
      # （bus 确实没了），走退避不 {:stop}（advisor M3）。
      defp subscribe_pattern(pattern, state, bus_pid \\ nil) do
        result =
          try do
            Cgc2046.Workflows.JidoAdapter.subscribe(
              pattern,
              fn type, data ->
                Cgc2046.Workflows.SignalSubscriber.run(__MODULE__, type, data)
              end,
              bus_pid
            )
          catch
            :exit, _reason -> {:error, :not_found}
          end

        case result do
          {:ok, _subscription_id, monitor_ref, forwarder_pid} ->
            {:ok,
             %{
               state
               | subscriptions: Map.put(state.subscriptions, monitor_ref, pattern),
                 forwarders: Map.put(state.forwarders, monitor_ref, forwarder_pid)
             }}

          {:error, :not_found} ->
            {:error, :bus_missing}

          {:error, reason} ->
            {:error, {:subscribe_failed, pattern, reason}}
        end
      end

      # 回收全部 forwarder（#120/#245）：先 demonitor+flush（防 forwarder 退出的
      # DOWN 入邮箱误触发重订阅分支），再走 drain 协议——对每个 forwarder 投递
      # :reclaim 并等在途投递（claim+effects 同步链）完成后自退，超时强杀兜底。
      # drain 在旁路 waiter 异步完成，bus DOWN 恢复路径（退避重订阅）不被阻塞。
      defp reclaim_forwarders(%{subscriptions: subscriptions, forwarders: forwarders} = state) do
        Enum.each(subscriptions, fn {ref, _pattern} -> Process.demonitor(ref, [:flush]) end)

        forwarders
        |> Map.values()
        |> Cgc2046.Workflows.JidoAdapter.drain_forwarders()

        %{state | subscriptions: %{}, forwarders: %{}}
      end

      # demonitor 现有 bus monitor 并置 nil（advisor A4）：forwarder-DOWN
      # :bus_missing 路径转入统一退避前 flush 排队中的 bus DOWN，防双定时链。
      # monitor 已触发（oneshot 自动解除）时 demonitor 是 no-op，幂等。
      defp demonitor_bus_monitor(%{bus_monitor: ref} = state) when is_reference(ref) do
        Process.demonitor(ref, [:flush])
        %{state | bus_monitor: nil}
      end

      defp demonitor_bus_monitor(state), do: state

      # bus 退避重试（#120）：指数退避 100ms 起 ×2 封顶 5s；max_retries 次仍无
      # bus 则转低频无限探测（#244）——不再放弃失聪：give_up 一次性告警 +
      # telemetry 后按 probe_interval 持续探测（bus_retries 保持 max 不递增、
      # bus_probing 置位，防日志/事件刷屏）；bus 回归由 :bus_resubscribe guard
      # 分支全量重订阅自动恢复。不 crash-loop、不重订阅风暴。
      defp schedule_bus_retry(%{bus_retries: retries} = state) do
        if retries >= @bus_max_retries do
          if state.bus_probing do
            # 探测往返：bus 仍缺，仅再调度一次低频探测，不重复告警/事件
            Process.send_after(self(), :bus_resubscribe, @bus_probe_interval_ms)
            state
          else
            Logger.error(
              "#{inspect(__MODULE__)} bus resubscribe gave up after #{retries} retries " <>
                "(bus not back); switching to low-frequency probing every " <>
                "#{@bus_probe_interval_ms}ms - auto-recovery on bus return; " <>
                "SignalIdempotency claim + E-10 reconciliation is the backstop"
            )

            Cgc2046.Workflows.SignalSubscriber.emit_give_up(__MODULE__, retries)

            Process.send_after(self(), :bus_resubscribe, @bus_probe_interval_ms)
            %{state | bus_probing: true}
          end
        else
          Process.send_after(self(), :bus_resubscribe, bus_retry_delay(retries))
          %{state | bus_retries: retries + 1}
        end
      end

      defp bus_retry_delay(n) do
        min(@bus_retry_base_ms * Integer.pow(2, min(n, 6)), @bus_retry_cap_ms)
      end
    end
  end
end
