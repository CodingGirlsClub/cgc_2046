defmodule Cgc2046.Workflows.ResearchRunReaper do
  @moduledoc """
  教研 run 回收（E-9 #124，总纲:171「event.ended → stop 回收」）。

  订阅 `event.ended` / `course.ended` → 停该实体的非终态教研 run
  （WorkflowRun :cancel——含 checkpoint 清理与 finished_at）。

  与 ResearchInstantiator 同款 GenServer 骨架：Application 启动时订阅信号；
  测试直接调 handle_signal/1（信号总线异步投递在 POC 已验证，测试不覆盖
  异步路径）。订阅回调在 JidoAdapter.subscribe 转发的独立进程中执行，
  rescue 兜底防订阅进程崩溃。

  ## 幂等语义（codex 评审 BLOCKING 2/3 修复后）

  - **claim 后置**：先执行副作用（cancel 本身幂等——非终态过滤 + cancel
    状态守卫），成功后写 claim 作执行标记。失败不写 claim → 重投仍会执行，
    不会出现「claim 永久化吞掉逃逸 run」。重复投递重放副作用无害（幂等）。
  - **非 research 不碰**：按 `definition.type == :research` 过滤（BLOCKING 5），
    同 instance key 的其他类型 run 不受影响。
  - **竞态兜底**：ResearchInstantiator 建 run 前二次校验实体 open（BLOCKING 3）；
    残余窗口（二次校验与 INSERT 之间 close）由对账扫描 E-10 发现。
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
        stop_runs_then_claim("event.ended", "event_#{event_id}")

      {_, course_id} when is_binary(course_id) ->
        stop_runs_then_claim("course.ended", "course_#{course_id}")

      _ ->
        Logger.warning("ResearchRunReaper received signal without entity id: #{inspect(data)}")
    end

    :ok
  rescue
    e ->
      Logger.warning("ResearchRunReaper signal handling failed: #{Exception.message(e)}")
      :ok
  end

  # 先执行后 claim：cancel 幂等，重复投递重放无害；失败不写 claim → 重投仍执行。
  defp stop_runs_then_claim(signal_type, entity_key) do
    stop_runs(entity_key)

    case SignalIdempotency.claim(signal_type, "#{signal_type}:#{entity_key}:research_run_reaper") do
      :ok -> :ok
      {:error, :already_claimed} -> :ok
    end
  end

  # instance key 存于 input_snapshot["key"]（research_instantiator 写入约定）。
  # WorkflowRun multitenancy global?(true)：无 tenant 全局读（同 expiry worker）。
  # 限定 definition.type == :research（BLOCKING 5：不碰同 key 的其他类型 run）。
  defp stop_runs(key) do
    WorkflowRun
    |> Ash.Query.filter(
      definition.type == :research and status in @non_terminal_statuses and
        input_snapshot["key"] == ^key
    )
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
