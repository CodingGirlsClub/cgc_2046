defmodule Cgc2046.Learning.LearningInstantiator do
  @moduledoc """
  学习 workflow 实例化（E-7 #122）。

  学习是**协议而非 DAG**：执行在 Learner 侧 OpenClacky（BYO），平台不编排。
  本模块只做触发——`enrollment.completed` → 幂等种 learning run（实例化后即
  `running`，纯 `:start` 状态机流转，不经 Engine 执行 node_def）。

  - **实例 key**：`"enrollment_<enrollment_id>"`（一个报名 = 一个 learning run；
    expired 后重提 → 新 enrollment → 新 key）。
  - **幂等两层**：① claim-in-handle（校验链通过后、launch 前经骨架 `claim/3`
    登记，键 = 消费者作用域——校验不过不烧 claim，重投仍可推进）；② find_or_create
    非终态 run（`Curriculum.Instantiator` 同款，终态后可重新实例化）。
  - **定义获取**：租户内已 published 的 `type=learning` 定义（多个取最新，
    version desc + inserted_at desc）。无 published 定义 → warning skip 供对账
    （E-10 规则：confirmed enrollment 无 learning run）。

  订阅骨架（订阅生命周期 / DOWN 重订阅 / rescue 壳）由
  `Cgc2046.Workflows.SignalSubscriber` 统一持有。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["enrollment.completed"],
    idempotency: :claim_in_handle,
    consumer_key: "learning_instantiator"

  require Ash.Query
  require Logger

  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Workflows.{WorkflowDefinition, WorkflowRun}

  # --- 公开 API --------------------------------------------------------------

  @doc """
  学习 workflow 实例化：创建 learning WorkflowRun + `:start`（pending → running）。

  - `workspace_id`：租户（= Enrollment 所属 Event/Course 的 workspace_id）
  - `definition_id`：已 published 的学习 WorkflowDefinition ID
  - `input`：run 输入（含 `enrollment_id`/`user_id`/`event_id` 或 `course_id`/`title`；
    `enrollment_id` 是授权账本的锚——学员授权经它反查 Enrollment，设计 §4.1）

  幂等：同一 definition + instance key 已有非终态 run → 返回已有 run（不重复创建）。
  """
  @spec launch(String.t(), String.t(), map()) :: {:ok, WorkflowRun.t()} | {:error, term()}
  def launch(workspace_id, definition_id, input)
      when is_binary(workspace_id) and is_binary(definition_id) and is_map(input) do
    with {:ok, defn} <- fetch_definition(workspace_id, definition_id),
         :ok <- ensure_learning_definition(defn),
         :ok <- ensure_create_guards(input),
         {:ok, run, _status} <-
           WorkflowRun.find_or_create_and_start(workspace_id, defn, input,
             key: instance_key(input),
             # 学习 run 无平台侧执行步骤：纯 :start（pending → running），不经
             # :start_run 的 Engine.run（设计 §5——协议而非 DAG）。
             start_action: :start
           ) do
      {:ok, run}
    end
  end

  # --- 信号处理（claim_in_handle 双回调，架构深化 G 方向②）------------------

  # before_claim：校验链（设计 §3）——enrollment 存在且 status=confirmed（孤儿
  # 防护）→ 反查 entity（Event/Course）拿 workspace_id + title → 取该租户已
  # published 的学习定义。校验通过 → `{:ok, ctx}`（骨架随后 claim + effects）；
  # 失败 → `:skip` / `{:error, reason}`（不烧 claim，重投仍可推进；best-effort
  # 语义由骨架归一化为 :ok）。claim 由骨架持有，本模块不再自调；校验失败日志
  # 文案保留（G 红线）。
  @impl Cgc2046.Workflows.SignalSubscriber
  def before_claim(_type, %{"enrollment_id" => enrollment_id} = data)
      when is_binary(enrollment_id) do
    with {:ok, %Enrollment{} = enrollment} <- Enrollment.anchor(data),
         :ok <- ensure_confirmed(enrollment),
         {:ok, entity} <- fetch_entity(enrollment),
         {:ok, %WorkflowDefinition{} = defn} <- fetch_learning_definition(entity.workspace_id) do
      {:ok,
       %{
         enrollment: enrollment,
         entity: entity,
         defn: defn,
         workspace_id: entity.workspace_id
       }}
    else
      {:error, reason} ->
        Logger.warning(
          "LearningInstantiator skipped instantiation for enrollment #{enrollment_id}: #{inspect(reason)}"
        )

        {:error, reason}

      # 无已 published 学习定义（read_first 返回 nil）是合法场景，走 skipped 而非
      # unexpected（同 curriculum/instantiator.ex 模式；供 E-10 对账）。
      {:ok, nil} ->
        Logger.warning(
          "LearningInstantiator skipped instantiation for enrollment #{enrollment_id}: :learning_definition_not_found"
        )

        :skip
    end
  end

  def before_claim(_type, data) do
    Logger.warning("LearningInstantiator received signal without enrollment id: #{inspect(data)}")

    :skip
  end

  # effects：校验链通过 + 骨架 claim 后执行——find_or_create run（幂等第二层，
  # 同一 definition + instance key 已有非终态 run → 返回已有 run）。best-effort：
  # launch 失败记 error 并归一化为 :ok（失败可见性靠 error 日志与 E-10 对账扫描）。
  @impl Cgc2046.Workflows.SignalSubscriber
  def effects(_type, _data, ctx) do
    input = %{
      "enrollment_id" => ctx.enrollment.id,
      "user_id" => ctx.enrollment.user_id,
      "event_id" => ctx.enrollment.event_id,
      "course_id" => ctx.enrollment.course_id,
      "title" => Cgc2046.Offering.title(ctx.entity),
      # S8（ADR-0011 L6）：course 报名绑 Course.current_revision_id（发布后）
      # 进 input_snapshot；无 revision 的存量课程 nil 宽限（key 后缀 "none"）。
      # event 报名不绑定（event 无 revision 概念，key 走 "none" 分支）。
      "course_revision_id" => current_revision_id(ctx)
    }

    case launch(ctx.workspace_id, ctx.defn.id, input) do
      {:ok, %WorkflowRun{}} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "LearningInstantiator launch failed for enrollment #{ctx.enrollment.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # --- 私有实现 --------------------------------------------------------------

  # 孤儿防护：信号先于报名事务提交发布时，enrollment 可能不存在或未 confirmed。
  # 读取委托 Enrollment.anchor/1（锚定单源，架构深化 E）。
  defp ensure_confirmed(%Enrollment{status: :confirmed}), do: :ok

  defp ensure_confirmed(%Enrollment{status: status}),
    do: {:error, {:enrollment_not_confirmed, status}}

  # 反查 offering 拿 workspace_id + title（设计 §3 校验链；信号 payload 无 title）。
  # 读取唯一真源 = Offering（按 enrollment 的 event_id/course_id 分派；错误坍缩
  # :not_found——原 :entity_not_found 仅进日志无消费方，D6 审计）。
  defp fetch_entity(%Enrollment{event_id: event_id}) when is_binary(event_id),
    do: Cgc2046.Offering.fetch(:event, event_id)

  defp fetch_entity(%Enrollment{course_id: course_id}) when is_binary(course_id),
    do: Cgc2046.Offering.fetch(:course, course_id)

  defp fetch_entity(%Enrollment{}), do: {:error, :not_found}

  defp fetch_definition(workspace_id, definition_id) do
    case Ash.get(WorkflowDefinition, definition_id, tenant: workspace_id, authorize?: false) do
      {:ok, defn} -> {:ok, defn}
      {:error, _} -> {:error, :definition_not_found}
    end
  end

  defp ensure_learning_definition(%WorkflowDefinition{type: :learning, status: :published}),
    do: :ok

  defp ensure_learning_definition(%WorkflowDefinition{type: type, status: status}) do
    {:error, {:definition_not_learning_published, type, status}}
  end

  # 异步路径：取该租户已 published 的学习定义。多个时取最新（version desc，
  # inserted_at desc 兜底）——read_first 取排序首行（同 curriculum 先例）。
  defp fetch_learning_definition(workspace_id) do
    WorkflowDefinition
    |> Ash.Query.filter(type == :learning and status == :published)
    |> Ash.Query.sort(version: :desc, inserted_at: :desc)
    |> Ash.read_first(tenant: workspace_id, authorize?: false)
  end

  # ensure_confirmed 与 INSERT 之间的窗口内报名可能转 cancelled（取消联动属 E-2
  # 范围）——创建前重读 enrollment 二次校验（对齐 curriculum BLOCKING 3 修复）；
  # 残余极小窗口由对账扫描（E-10）兜底。前置守卫留调用侧（PR-F D5）——统一入口
  # 只内化 create→start 顺序与非终态去重。读取委托 Enrollment.anchor/1（锚定
  # 单源，架构深化 E）。
  defp ensure_create_guards(input) do
    with {:ok, %Enrollment{} = enrollment} <- Enrollment.anchor(input),
         :ok <- ensure_confirmed(enrollment) do
      :ok
    end
  end

  # instance key（S8/ADR-0011 L6）：`Runs.instance_key/2` 单源——
  # "learning_<enrollment_id>_<revision_id|none>"（含 revision：一个报名对
  # 一个课程版本 = 一个 run；与 start_learning_run 工具路径幂等互通，R36）。
  # input 自带 key 时原样使用（测试直调口径）。
  defp instance_key(input) do
    Map.get(input, "key") || Map.get(input, :key) ||
      Cgc2046.Learning.Runs.instance_key(
        input_enrollment_id(input),
        Map.get(input, "course_revision_id") || Map.get(input, :course_revision_id)
      )
  end

  # course 报名的当前 published revision（无 revision / event 报名 → nil）
  defp current_revision_id(%{entity: %Cgc2046.Courses.Course{} = course}),
    do: course.current_revision_id

  defp current_revision_id(_ctx), do: nil

  defp input_enrollment_id(input) do
    case Enrollment.anchored_id(input) do
      {:ok, enrollment_id} -> enrollment_id
      {:error, :no_enrollment_anchor} -> nil
    end
  end
end
