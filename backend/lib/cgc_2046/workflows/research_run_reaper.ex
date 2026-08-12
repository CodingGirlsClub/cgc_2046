defmodule Cgc2046.Workflows.ResearchRunReaper do
  @moduledoc """
  教研 run 回收（E-9 #124，总纲:171「event.ended → stop 回收」）。

  订阅 `event.ended` / `course.ended` → 停该实体的非终态教研 run
  （WorkflowRun :cancel——含 checkpoint 清理与 finished_at）。

  与 ResearchInstantiator 同款 GenServer 骨架：Application 启动时订阅信号；
  测试直接调 handle_signal/1（信号总线异步投递在 POC 已验证，测试不覆盖
  异步路径）。订阅回调在 JidoAdapter.subscribe 转发的独立进程中执行，
  rescue 兜底防订阅进程崩溃。

  幂等两层（#124 验收）：
  - signal_idempotency claim（PR #121）：消费方作用域幂等键
    `"<signal_type>:<entity_key>:research_run_reaper"`，先 claim 后执行，
    同键重复投递只执行一次；
  - 业务幂等：非终态过滤 + cancel 状态守卫双层兜底；单 run 失败记日志不
    中断整批（best-effort，失败可见性交对账扫描 E-10）。

  发布方是 best-effort 至少一次投递：claim 保证至多一次执行，执行中途失败
  由对账发现（重放语义与 Idea 7 一起维护）。
  """

  use GenServer

  require Logger

  alias Cgc2046.Workflows.{JidoAdapter, SignalIdempotency, WorkflowRun}

  require Ash.Query

  @signal_patterns ["event.ended", "course.ended"]
  @non_terminal_statuses [:pending, :running, :waiting]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # 订阅失败不阻塞启动（信号总线在 Application children 中先于本模块启动）。
    Enum.each(@signal_patterns, fn pattern ->
      case JidoAdapter.subscribe(pattern, &handle_signal/1, nil) do
        {:ok, _sub_id} ->
          :ok

        {:error, reason} ->
          Logger.warning("ResearchRunReaper subscribe #{pattern} failed: #{inspect(reason)}")
      end
    end)

    {:ok, %{}}
  end

  # 信号 → 按 entity instance key（"event_#{id}" / "course_#{id}"）停教研 run。
  # signal.data 形态（close/cancel action 发布）：%{"event_id" => id, "title" => ...}
  # 或 %{"course_id" => id, ...}。
  def handle_signal(signal) do
    data = Map.get(signal, :data) || %{}

    case {Map.get(data, "event_id"), Map.get(data, "course_id")} do
      {event_id, _} when is_binary(event_id) ->
        stop_runs_if_unclaimed("event.ended", "event_#{event_id}")

      {_, course_id} when is_binary(course_id) ->
        stop_runs_if_unclaimed("course.ended", "course_#{course_id}")

      _ ->
        Logger.warning("ResearchRunReaper received signal without entity id: #{inspect(data)}")
    end

    :ok
  rescue
    e ->
      Logger.warning("ResearchRunReaper signal handling failed: #{Exception.message(e)}")
      :ok
  end

  # claim 先于执行：同键重复投递只执行一次（消费方作用域键，多消费方互不冲突；
  # workspace_id 仅观测，claim/3 第三参传 nil）。
  defp stop_runs_if_unclaimed(signal_type, entity_key) do
    case SignalIdempotency.claim(signal_type, "#{signal_type}:#{entity_key}:research_run_reaper") do
      :ok -> stop_runs(entity_key)
      {:error, :already_claimed} -> :ok
    end
  end

  # instance key 存于 input_snapshot["key"]（research_instantiator 写入约定）。
  # WorkflowRun multitenancy global?(true)：无 tenant 全局读（同 expiry worker）。
  defp stop_runs(key) do
    WorkflowRun
    |> Ash.Query.filter(status in @non_terminal_statuses and input_snapshot["key"] == ^key)
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn run ->
      case run
           |> Ash.Changeset.for_update(:cancel, %{}, tenant: run.workspace_id, authorize?: false)
           |> Ash.update(tenant: run.workspace_id, authorize?: false) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("ResearchRunReaper cancel failed for run #{run.id}: #{inspect(reason)}")
      end
    end)
  end
end
