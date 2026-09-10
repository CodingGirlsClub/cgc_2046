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
    patterns: ["enrollment.completed", "course_revision.published"],
    idempotency: :claim_in_handle,
    consumer_key: "learning_instantiator"

  require Ash.Query
  require Logger

  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Learning.Runs
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
           create_with_collision_fallback(workspace_id, defn, input) do
      {:ok, run}
    end
  end

  # D8：key 降级为可读标签；并发双种撞 partial unique index（user ×
  # revision 非终态唯一）→ 回读非终态 run 兜底（best-effort 信号路径
  # 与 Runs.start 工具路径共用同一语义）。
  defp create_with_collision_fallback(workspace_id, defn, input) do
    WorkflowRun.find_or_create_and_start(workspace_id, defn, input,
      key: instance_key(input),
      # 学习 run 无平台侧执行步骤：纯 :start（pending → running），不经
      # :start_run 的 Engine.run（设计 §5——协议而非 DAG）。
      start_action: :start
    )
  rescue
    Ecto.ConstraintError ->
      case Cgc2046.Learning.Runs.non_terminal_run(
             Map.get(input, "user_id") || Map.get(input, :user_id),
             workspace_id,
             Map.get(input, "course_revision_id") || Map.get(input, :course_revision_id)
           ) do
        {:ok, %WorkflowRun{} = run} -> {:ok, run, :existing}
        other -> other
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
  def before_claim("enrollment.completed", %{"enrollment_id" => enrollment_id} = data)
      when is_binary(enrollment_id) do
    with {:ok, %Enrollment{} = enrollment} <- Enrollment.anchor(data),
         :ok <- ensure_confirmed(enrollment),
         {:ok, entity} <- fetch_entity(enrollment),
         {:ok, revision} <- fetch_anchor_revision(entity),
         :ok <- ensure_no_active_run(enrollment, entity, revision),
         {:ok, %WorkflowDefinition{} = defn} <- fetch_learning_definition(entity.workspace_id) do
      {:ok,
       %{
         enrollment: enrollment,
         entity: entity,
         revision: revision,
         defn: defn,
         workspace_id: entity.workspace_id
       }}
    else
      # D8：user × revision 已有非终态 run（双通道另一通道已种）——汇流不烧
      # claim；终态后重学放行（预查只覆盖非终态）。
      {:ok, :run_exists} ->
        Logger.info(
          "LearningInstantiator skipped instantiation for enrollment #{enrollment_id}: :run_exists"
        )

        :skip

      # 课程未发布（无锚）：不种空协议 run，等 course_revision.published
      # 信号补种（1i）——归一 :skip，不烧 claim，报名侧无感。
      {:ok, :unpublished_course} ->
        Logger.info(
          "LearningInstantiator skipped instantiation for enrollment #{enrollment_id}: :unpublished_course"
        )

        :skip

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

  # 1i 补种信号：课程发布（换绑 current_revision）→ 对该课程从未开始学习的
  # confirmed 报名补种 run。校验链：payload 锚点反查 revision（published
  # 门）→ 课程一致性对账 → 学习定义。
  def before_claim(
        "course_revision.published",
        %{"course_id" => course_id, "course_revision_id" => revision_id} = data
      )
      when is_binary(course_id) and is_binary(revision_id) do
    workspace_id = data["workspace_id"]

    with {:ok, revision_or_nil} <- fetch_published_anchor(workspace_id, revision_id),
         {:ok, %Cgc2046.Curriculum.CourseRevision{} = revision} <-
           require_published(revision_or_nil),
         :ok <- ensure_revision_course(revision, course_id),
         {:ok, course} <- fetch_course(workspace_id, course_id),
         {:ok, %WorkflowDefinition{} = defn} <- fetch_learning_definition(workspace_id) do
      {:ok,
       %{
         course: course,
         revision: revision,
         defn: defn,
         workspace_id: workspace_id
       }}
    else
      {:ok, :unpublished_course} ->
        Logger.info(
          "LearningInstantiator skipped reseed for course #{course_id}: revision not published"
        )

        :skip

      {:ok, nil} ->
        Logger.warning(
          "LearningInstantiator skipped reseed for course #{course_id}: :learning_definition_not_found"
        )

        :skip

      {:error, reason} ->
        Logger.warning(
          "LearningInstantiator skipped reseed for course #{course_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  def before_claim(_type, data) do
    Logger.warning(
      "LearningInstantiator received signal without enrollment/course anchor: #{inspect(data)}"
    )

    :skip
  end

  # effects：校验链通过 + 骨架 claim 后执行——find_or_create run（幂等第二层，
  # 同一 definition + instance key 已有非终态 run → 返回已有 run）。best-effort：
  # launch 失败记 error 并归一化为 :ok（失败可见性靠 error 日志与 E-10 对账扫描）。
  @impl Cgc2046.Workflows.SignalSubscriber
  def effects("course_revision.published", _data, ctx) do
    # 1i 补种：课程 confirmed 报名 ∪ 锚定本 revision 的活动 confirmed 报名，
    # 逐学员判定「该课程从未开始任何学习 run」（latest_run_for 任意状态
    # 空）→ 补种；进行中/学过任一版本的学员不打扰（换版不打断、重学主动）。
    ctx.workspace_id
    |> confirmed_enrollments_for_revision(ctx.course.id, ctx.revision.id)
    |> Enum.each(&maybe_reseed_run(ctx, &1))

    :ok
  end

  def effects(_type, _data, ctx) do
    input = %{
      "enrollment_id" => ctx.enrollment.id,
      "user_id" => ctx.enrollment.user_id,
      "event_id" => ctx.enrollment.event_id,
      # D8：锚定 event 注入配套课 course_id（revision.course_id）——镜像出
      # subject_course_id，否则 runs_query/active_run_for/get_learning_state
      # 对活动来源 run 全失明；course 报名维持 enrollment.course_id。
      "course_id" => anchor_course_id(ctx),
      "title" => Cgc2046.Offering.title(ctx.entity),
      # 锚定 revision 入快照（无锚事件型 run 为 nil，key 走 "none" 后缀宽限）。
      "course_revision_id" => ctx.revision && ctx.revision.id
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

  # 补种单学员：从未开始 → launch（幂等内建）；launch 失败记 error 归一
  # :ok（对账规1 兜底可见）。
  defp maybe_reseed_run(ctx, enrollment) do
    if is_nil(Runs.latest_run_for(%{id: enrollment.user_id}, ctx.workspace_id, ctx.course.id)) do
      input = %{
        "enrollment_id" => enrollment.id,
        "user_id" => enrollment.user_id,
        "course_id" => ctx.course.id,
        "title" => ctx.course.title,
        "course_revision_id" => ctx.revision.id
      }

      case launch(ctx.workspace_id, ctx.defn.id, input) do
        {:ok, %WorkflowRun{}} ->
          :ok

        {:error, reason} ->
          Logger.error(
            "LearningInstantiator reseed failed for enrollment #{enrollment.id}: #{inspect(reason)}"
          )

          :ok
      end
    else
      :ok
    end
  end

  # 课程 confirmed 报名 ∪ 锚定本 revision 的活动 confirmed 报名（D1 索引）。
  defp confirmed_enrollments_for_revision(workspace_id, course_id, revision_id) do
    course_rows =
      Enrollment
      |> Ash.Query.filter(
        workspace_id == ^workspace_id and course_id == ^course_id and status == :confirmed
      )
      |> Ash.read!(authorize?: false)

    event_ids =
      Cgc2046.Events.Event
      |> Ash.Query.filter(workspace_id == ^workspace_id and course_revision_id == ^revision_id)
      |> Ash.Query.select([:id])
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.id)

    event_rows =
      Enrollment
      |> Ash.Query.filter(
        workspace_id == ^workspace_id and event_id in ^event_ids and status == :confirmed
      )
      |> Ash.read!(authorize?: false)

    course_rows ++ event_rows
  end

  defp require_published(%Cgc2046.Curriculum.CourseRevision{} = revision), do: {:ok, revision}
  defp require_published(nil), do: {:ok, :unpublished_course}

  # 信号 payload 的 course_id 与 revision 归属对账（漂移 → error 重投可见）。
  defp ensure_revision_course(%{course_id: course_id}, course_id), do: :ok

  defp ensure_revision_course(_revision, _course_id),
    do: {:error, :revision_course_mismatch}

  defp fetch_course(workspace_id, course_id) do
    case Ash.get(Cgc2046.Courses.Course, course_id, tenant: workspace_id, authorize?: false) do
      {:ok, nil} -> {:error, :course_not_found}
      {:ok, course} -> {:ok, course}
      {:error, _} -> {:error, :course_not_found}
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

  # 无锚（事件型 run）：无 revision 维度可查，直通放行（基线语义）。
  defp ensure_no_active_run(_enrollment, _entity, nil), do: :ok

  # 课程无锚直通：携带 :unpublished_course 标记交 else 归一 :skip（1i）。
  defp ensure_no_active_run(_enrollment, _entity, :unpublished_course),
    do: {:ok, :unpublished_course}

  # D8 预查（claim 前）：同一 user 在同一锚点 revision 已有非终态 run →
  # {:ok, :run_exists}（汇流 skip，不烧 claim）。查询失败原样上抛（重投
  # 可推进，不误烧 claim）。
  defp ensure_no_active_run(enrollment, entity, revision) do
    case Cgc2046.Learning.Runs.resumable_run(
           enrollment.user_id,
           entity.workspace_id,
           revision.id
         ) do
      {:ok, nil} -> :ok
      {:ok, %WorkflowRun{}} -> {:ok, :run_exists}
      {:error, _} = err -> err
    end
  end

  # instance key（issue #505 D8）：`Runs.instance_key/2` 单源——
  # "learning_<user_id>_<revision_id>"（一个学员对一个课程版本 = 一个活跃
  # run；与 start_learning_run 工具路径幂等互通）。key 仅为可读标签，去重
  # 真源 = subject 列预查 + partial unique index。
  # input 自带 key 时原样使用（测试直调口径）。
  defp instance_key(input) do
    Map.get(input, "key") || Map.get(input, :key) ||
      Cgc2046.Learning.Runs.instance_key(
        Map.get(input, "user_id") || Map.get(input, :user_id),
        Map.get(input, "course_revision_id") || Map.get(input, :course_revision_id)
      )
  end

  # course 报名锚 = 课程当前 published revision；无锚（未发布）→
  # {:ok, :unpublished_course}——不种空协议 run，等 course_revision.published
  # 信号补种（1i）。event 报名锚 = 配套课 course_revision_id；无锚 →
  # {:ok, nil}：事件型 run（纯协议）照常实例化（基线语义保留）。
  defp fetch_anchor_revision(%Cgc2046.Courses.Course{current_revision_id: nil}),
    do: {:ok, :unpublished_course}

  defp fetch_anchor_revision(%Cgc2046.Events.Event{course_revision_id: nil}),
    do: {:ok, nil}

  defp fetch_anchor_revision(%Cgc2046.Courses.Course{
         current_revision_id: id,
         workspace_id: workspace_id
       }),
       do: fetch_published_anchor(workspace_id, id)

  defp fetch_anchor_revision(%Cgc2046.Events.Event{
         course_revision_id: id,
         workspace_id: workspace_id
       }),
       do: fetch_published_anchor(workspace_id, id)

  # 锚点须仍 published（published_at 非空），否则种出的 run 读不到内容；
  # 撤下/草稿按无锚处理。
  defp fetch_published_anchor(workspace_id, revision_id) do
    Cgc2046.Curriculum.CourseRevision
    |> Ash.Query.filter(id == ^revision_id and not is_nil(published_at))
    |> Ash.read_one(authorize?: false, tenant: workspace_id)
  end

  # D8：course_id 真源——course 报名 = enrollment.course_id；锚定 event =
  # 配套 revision 所属 course（镜像 subject_course_id 的前提）；事件型
  # run（无锚）→ nil。
  defp anchor_course_id(%{enrollment: %Enrollment{course_id: course_id}})
       when is_binary(course_id),
       do: course_id

  defp anchor_course_id(%{revision: %{course_id: course_id}}), do: course_id

  defp anchor_course_id(_ctx), do: nil
end
