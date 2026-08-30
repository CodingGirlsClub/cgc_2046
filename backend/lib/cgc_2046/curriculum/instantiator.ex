defmodule Cgc2046.Curriculum.Instantiator do
  @moduledoc """
  教研 workflow 实例化（Slice C #39，阶段 6;ADR-0009 PR③ 自
  Workflows.ResearchInstantiator 迁入改名；S6 起 **event-only**）。

  Event launch → 创建教研 WorkflowRun + start_run。领域模型 §2.3：每个
  Event 实例化一个教研 workflow 实例，instance key 为 `"event_\#{id}"`。

  **S6 收窄说明**：course 侧教研 run 已被课程教研流程（`type=
  :course_preparation` 的 prep run，见 `Curriculum.Prep` /
  `Curriculum.PrepInstantiator`）取代——本模块不再订阅 `course.launched`，
  也不再为 `course_` key 实例化（存量 dev 行的回收由 Reaper / 对账规则⑤的
  自然 aging 承担，Event 侧语义不变）。

  ## 幂等（state_based，骨架不写 claim）

  同一 Event/Course 已有非终态 run（pending/running/waiting）→ 返回已有 run，
  不重复创建。终态 run（succeeded/failed/cancelled/expired）后可重新实例化。

  ## 信号订阅（生产路径）

  订阅 `event.launched` 信号，收到信号 → 解析实体/教研定义 → 调 `launch/3`。
  订阅骨架（订阅生命周期 / DOWN 重订阅 / rescue 壳）由
  `Cgc2046.Workflows.SignalSubscriber` 统一持有。

  异步路径是 best-effort：信号不含租户，需按 entity_id 反查实体拿 workspace_id，
  再取该租户已 published 的教研定义（多个时取最新）。任一环节失败只记日志。
  """
  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["event.launched"],
    idempotency: :state_based,
    consumer_key: "instantiator"

  require Ash.Query
  require Logger

  alias Cgc2046.Workflows.{WorkflowDefinition, WorkflowRun}

  # --- 公开 API --------------------------------------------------------------

  @doc """
  教研 workflow 实例化：Event launch → 创建 WorkflowRun + start_run。

  - `workspace_id`：租户（= Event 的 workspace_id）
  - `definition_id`：已 published 的教研 WorkflowDefinition ID
  - `input`：run 输入（含 `key`/`event_id`/`title`/`research_requirements`）

  幂等：同一 Event 已有非终态 run → 返回已有 run（不重复创建）。

  返回 `{:ok, run}`（waiting/succeeded/failed 均返回 run，调用方按 status 判定）
  或 `{:error, reason}`。
  """
  @spec launch(String.t(), String.t(), map()) ::
          {:ok, WorkflowRun.t()} | {:error, term()}
  def launch(workspace_id, definition_id, input)
      when is_binary(workspace_id) and is_binary(definition_id) and is_map(input) do
    with {:ok, defn} <- fetch_definition(workspace_id, definition_id),
         :ok <- ensure_curriculum_definition(defn),
         :ok <- ensure_create_guards(input),
         {:ok, run, _status} <-
           WorkflowRun.find_or_create_and_start(workspace_id, defn, input,
             key: instance_key(input)
           ) do
      {:ok, run}
    end
  end

  # --- 信号处理 ----------------------------------------------------------------

  # 信号 → 解析实体/教研定义 → launch/3。signal.data 形态（Event launch action
  # 发布）：%{"event_id" => id, "title" => ..., "research_requirements" => ...}。
  # （ADR-0009 KD8/R9：信号 payload 键逐字节冻结，`research_requirements` 键名不随
  # 属性改名。）
  @impl Cgc2046.Workflows.SignalSubscriber
  def handle(_type, %{"event_id" => event_id} = data) when is_binary(event_id) do
    instantiate(event_id, data)
  end

  def handle(_type, data) do
    Logger.warning("Curriculum.Instantiator received signal without entity id: #{inspect(data)}")
    :ok
  end

  # 按 entity_id 反查实体 → 校验实体已 launch（status == :open，孤儿 run 防护：
  # 信号先于事务提交发布时，draft 实体不得实例化）→ 取该租户已 published 的教研
  # 定义 → `launch/3`。任一环节失败返回 `:ok`（best-effort，不抛错）。
  defp instantiate(event_id, data) do
    with {:ok, entity} <- fetch_entity(:event, event_id),
         :ok <- ensure_launched(entity),
         :ok <- ensure_curriculum_enabled(entity),
         {:ok, %WorkflowDefinition{} = defn} <- fetch_curriculum_definition(entity.workspace_id) do
      input = %{
        "event_id" => event_id,
        "title" => data["title"],
        "research_requirements" => data["research_requirements"] || %{}
      }

      # #13：不得丢弃 launch/3 返回值——创建成功但 start 失败（hibernate 写失败等）
      # 时 run 已落库但未启动，静默丢弃会让故障不可见。best-effort 语义保持
      # （异步路径不抛错），失败记 error 日志供对账。
      case launch(entity.workspace_id, defn.id, input) do
        {:ok, %WorkflowRun{} = run} ->
          # #14：run 创建成功 → 回写实体 workflow_run_id（产物引用链；失败只记日志，
          # 不阻塞实例化——引用可对账补写）。
          link_curriculum_run(entity, run)

        {:error, reason} ->
          Logger.error(
            "Curriculum.Instantiator launch failed for event #{event_id}: #{inspect(reason)}"
          )

          :ok
      end
    else
      {:error, reason} ->
        Logger.warning(
          "Curriculum.Instantiator skipped instantiation for event #{event_id}: #{inspect(reason)}"
        )

        :ok

      # 无已 published 教研定义（read_first 返回 nil）是合法场景，走 skipped 而非 unexpected。
      {:ok, nil} ->
        Logger.warning(
          "Curriculum.Instantiator skipped instantiation for event #{event_id}: :curriculum_definition_not_found"
        )

        :ok

      other ->
        Logger.warning(
          "Curriculum.Instantiator unexpected instantiation result for event #{event_id}: #{inspect(other)}"
        )

        :ok
    end
  end

  # --- 私有实现 --------------------------------------------------------------

  defp fetch_definition(workspace_id, definition_id) do
    case Ash.get(WorkflowDefinition, definition_id, tenant: workspace_id, authorize?: false) do
      {:ok, defn} -> {:ok, defn}
      {:error, _} -> {:error, :definition_not_found}
    end
  end

  defp ensure_curriculum_definition(%WorkflowDefinition{type: :curriculum, status: :published}),
    do: :ok

  defp ensure_curriculum_definition(%WorkflowDefinition{type: type, status: status}) do
    {:error, {:definition_not_curriculum_published, type, status}}
  end

  # 异步路径：按 entity_id 反查 offering（PK 全局唯一，global?(true) 下可不带 tenant）。
  # 读取唯一真源 = Offering；错误坍缩 :not_found（原 :event_not_found/:course_not_found
  # 仅进日志无消费方，D6 审计）。
  defp fetch_entity(kind, entity_id), do: Cgc2046.Offering.fetch(kind, entity_id)

  # 孤儿 run 防护：信号先于 launch 事务提交发布（change 回调在事务内，提交失败
  # 时事件仍为 draft 但信号已发），异步路径必须校验实体已 launch 才实例化。
  defp ensure_launched(%{status: :open}), do: :ok
  defp ensure_launched(%{status: status}), do: {:error, {:entity_not_launched, status}}

  # #6 + U6(#180/R14):教研开关门控 = Event 的退出通道
  # (curriculum_enabled = 「这场活动不使用教研链路」,轻聚会场景);Course 已不走
  # 本模块实例化(S6 收窄,教研由 course_preparation prep run 承担)。
  defp ensure_curriculum_enabled(%{curriculum_enabled: true}), do: :ok

  defp ensure_curriculum_enabled(%{curriculum_enabled: false}),
    do: {:error, :curriculum_disabled}

  # #14：run 创建成功后回写实体 workflow_run_id（产物引用链）。
  # 失败只记日志不阻塞——引用可对账补写（best-effort，同 launch 容错语义）。
  defp link_curriculum_run(entity, run) do
    attrs = %{workflow_run_id: run.id}

    case entity
         |> Ash.Changeset.for_update(
           :link_curriculum_run,
           attrs,
           tenant: entity.workspace_id,
           authorize?: false
         )
         |> Ash.update(tenant: entity.workspace_id, authorize?: false) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Curriculum.Instantiator link_curriculum_run failed for #{entity.__struct__} #{entity.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # 异步路径：取该租户已 published 的教研定义。多个时取最新（version desc，
  # inserted_at desc 兜底）——read_one 无排序时 Postgres 返回任意行，实例化
  # 会跑错 workflow（low-1）；且 read_one + sort 会因多行报 MultipleResults，
  # 取排序首行必须用 read_first。
  defp fetch_curriculum_definition(workspace_id) do
    WorkflowDefinition
    |> Ash.Query.filter(type == :curriculum and status == :published)
    |> Ash.Query.sort(version: :desc, inserted_at: :desc)
    |> Ash.read_first(tenant: workspace_id, authorize?: false)
  end

  # BLOCKING 3 修复：ensure_launched 与 INSERT 之间的窗口内 close 会种下孤儿 run
  # （reaper 已扫过、claim 已写）。创建前重读实体二次校验；残余极小窗口由对账
  # 扫描（E-10）兜底。前置守卫留调用侧（PR-F D5）——统一入口只内化
  # create→start 顺序与非终态去重。
  defp ensure_create_guards(input) do
    with {:ok, entity} <- fetch_entity(:event, input_entity_id(input)),
         :ok <- ensure_launched(entity) do
      :ok
    end
  end

  # instance key 派生（"event_#{id}"；input 自带 key 时原样使用）。
  defp instance_key(input) do
    case Map.get(input, "key") || Map.get(input, :key) do
      nil ->
        "event_#{input_entity_id(input)}"

      key ->
        key
    end
  end

  defp input_entity_id(input) do
    Map.get(input, "event_id") || Map.get(input, :event_id)
  end
end
