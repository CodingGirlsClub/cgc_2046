defmodule Cgc2046.Learning.Runs do
  @moduledoc """
  学习 run 上下文（role-agent-journeys-v2 S8；ADR-0011 L6）：learning
  WorkflowRun 的启动/查询/投影/完成判定/停滞口径的**单源**。

  学习是**协议而非 DAG**：平台只持有 run 壳 + 不可变 `Learning.Attempt`
  证据流，掌握态由 `Mastery` 纯投影派生，下一动作由 `NextAction` 纯函数
  推荐。本模块是这些纯函数与 Ash 读面之间的粘合层。

  - **instance key**：`instance_key/2` = `"learning_<enrollment_id>_<revision_id>"`
    （revision 缺失兜底 `"none"`）——一个报名对一个课程版本 = 一个 learning
    run。`LearningInstantiator`（enrollment.completed 异步路径）与
    `start_learning_run` 工具（学员主动路径）共用同一 key，R36 幂等在两
    路径间成立。
  - **revision 绑定走 input_snapshot**（ADR-0011 L6 权威）：run 创建期把
    `course_revision_id` 固化进 `input_snapshot`（enrollment 锚同款先例），
    generic 引擎表零域列零 opt；`revision_of/1` 是该域事实的唯一读取面。
  - **启动幂等（R36）**：`start/3` 先按 key 查**任意状态** run，命中即返回
    `{:ok, run, :existing}`（终态也返回——完成后重学新版会换 key；同版重进
    是 resume 语义，§B#11）。
  - **完成判定（R39/AE10）**：`complete_when_mastered/1` = running ∧ 绑定
    revision ∧ 必修集非空且全 ever_mastered → `:complete`。submit 工具在
    attempt 落库后即时调用（**非同事务** §B#12——completion 失败不回滚账本；
    不等 5 分钟 worker），worker 兜底同款调用。
  - **停滞口径（D6-③/R50）**：`stagnant_cutoff/1` + `stagnant?/2`，活动
    时间 = 最新 attempt `created_at`，零 attempt 回退 run `inserted_at`。
    LearningProgressWorker 提醒与对账规则⑦只引用本模块。
  """

  require Ash.Query

  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.{Content, CourseRevision}
  alias Cgc2046.Learning.{Attempt, Mastery, NextAction, ReviewSchedule, RunProjection}
  alias Cgc2046.Workflows.{WorkflowDefinition, WorkflowRun}

  # 停滞阈值（天，D6-③）：LearningProgressWorker 提醒与 ReconciliationScanWorker
  # 规则⑦同源——修改只在此一处。
  @stagnation_threshold_days 7

  @active_statuses [:pending, :running, :waiting]

  # --- instance key -------------------------------------------------------------

  @doc """
  学习 run 实例 key（issue #505 D8）：`"learning_<user_id>_<revision_id>"`——
  user × revision 维度（一个学员对一个课程版本 = 一个活跃 run，活动/课程
  双通道汇入）。key 降级为**可读标签**：去重真源 = `resumable_run/3`
  （subject 列预查）+ workflow_runs 的 partial unique index；存量
  enrollment 维度 key 不动，`"none"` 后缀仅存量宽限（新 run 恒带 revision）。
  """
  @spec instance_key(String.t(), String.t() | nil) :: String.t()
  def instance_key(user_id, revision_id) do
    "learning_#{user_id}_#{revision_id || "none"}"
  end

  # --- 授权谓词（工具层/GraphQL 共用） --------------------------------------------

  @doc "本人 confirmed enrollment 存在性（学习循环启动与提交的工具层授权）。"
  @spec confirmed_enrollment?(term(), String.t(), String.t()) :: boolean()
  def confirmed_enrollment?(%{id: actor_id}, workspace_id, course_id)
      when is_binary(workspace_id) and is_binary(course_id) do
    Enrollment
    |> Ash.Query.filter(
      workspace_id == ^workspace_id and course_id == ^course_id and
        user_id == ^actor_id and status == :confirmed
    )
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [] -> false
      [_] -> true
    end
  end

  def confirmed_enrollment?(_actor, _workspace_id, _course_id), do: false

  @doc """
  user × revision 非终态 learning run 预查（issue #505 D8 去重真源）：
  subject 列口径（subject_user_id × subject_course_revision_id ×
  pending/running/waiting），instantiator claim 前与 `start/3` 共用。
  """
  @spec non_terminal_run(String.t(), String.t(), String.t()) ::
          {:ok, WorkflowRun.t() | nil} | {:error, term()}
  def non_terminal_run(user_id, workspace_id, revision_id)
      when is_binary(user_id) and is_binary(workspace_id) and is_binary(revision_id) do
    WorkflowRun
    |> Ash.Query.filter(
      definition.type == :learning and
        subject_user_id == ^user_id and
        subject_course_revision_id == ^revision_id and
        status in ^@active_statuses
    )
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false, tenant: workspace_id)
  end

  @doc """
  user × revision **可 resume** learning run 预查（D8 汇流口径）：进行中
  （pending/running/waiting）∨ 已完成（succeeded）→ 命中（同版重进 =
  resume 查看，完成不重置学业）；failed/cancelled/expired 视为可重学，
  返回 `{:ok, nil}` 放行新种。instantiator claim 前与 `start/3` 共用。
  """
  @spec resumable_run(String.t(), String.t(), String.t()) ::
          {:ok, WorkflowRun.t() | nil} | {:error, term()}
  def resumable_run(user_id, workspace_id, revision_id)
      when is_binary(user_id) and is_binary(workspace_id) and is_binary(revision_id) do
    WorkflowRun
    |> Ash.Query.filter(
      definition.type == :learning and
        subject_user_id == ^user_id and
        subject_course_revision_id == ^revision_id and
        status in ^(@active_statuses ++ [:succeeded])
    )
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false, tenant: workspace_id)
  end

  @doc """
  挂载授权（issue #505 D4/D9）：本人对「锚定了该课程任一 revision 的活动」
  有 confirmed 报名。与 `confirmed_enrollment?/3` 并列的独立谓词——课程
  通道原语义不动，活动通道经 D1 索引（events.course_revision_id）反查。
  revision 撤版不撤销授权（K1：读哪个版本由 stale_revision 话术另行约束）。
  """
  @spec mounted_enrollment?(term(), String.t(), String.t()) :: boolean()
  def mounted_enrollment?(%{id: actor_id}, workspace_id, course_id)
      when is_binary(workspace_id) and is_binary(course_id) do
    with revision_ids when revision_ids != [] <- revision_ids_of(workspace_id, course_id),
         event_ids when event_ids != [] <- anchored_event_ids(workspace_id, revision_ids) do
      Enrollment
      |> Ash.Query.filter(
        workspace_id == ^workspace_id and user_id == ^actor_id and
          event_id in ^event_ids and status == :confirmed
      )
      |> Ash.exists?(authorize?: false)
    else
      _ -> false
    end
  end

  def mounted_enrollment?(_actor, _workspace_id, _course_id), do: false

  defp revision_ids_of(workspace_id, course_id) do
    Cgc2046.Curriculum.CourseRevision
    |> Ash.Query.filter(course_id == ^course_id)
    |> Ash.Query.select([:id])
    |> Ash.read!(authorize?: false, tenant: workspace_id)
    |> Enum.map(& &1.id)
  end

  defp anchored_event_ids(workspace_id, revision_ids) do
    Cgc2046.Events.Event
    |> Ash.Query.filter(course_revision_id in ^revision_ids)
    |> Ash.Query.select([:id])
    |> Ash.read!(authorize?: false, tenant: workspace_id)
    |> Enum.map(& &1.id)
  end

  @doc """
  本人学习 run 持有性（任意状态，含 close/cancel 后）：「曾学过」读面授权——
  替代 S8 删除的 LearningRecord 记忆持有者层。

  租户收紧（#349 A）：与 `active_run_for`/`latest_run_for` 同款 `tenant` 读取
  （`runs_query/2` 单源）——他台 run（course↔workspace 不变量被未来写路径
  破坏时）不构成授权，fail-closed。
  """
  @spec learning_run_holder?(term(), String.t(), String.t()) :: boolean()
  def learning_run_holder?(%{id: _actor_id} = actor, workspace_id, course_id)
      when is_binary(workspace_id) and is_binary(course_id) do
    actor
    |> runs_query(course_id)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false, tenant: workspace_id)
    |> case do
      [] -> false
      [_] -> true
    end
  end

  def learning_run_holder?(_actor, _workspace_id, _course_id), do: false

  # --- 启动（R36） ----------------------------------------------------------------

  @doc """
  启动（或幂等返回）学员对课程当前 published revision 的 learning run。

  链：confirmed enrollment（无 → forbidden）→ 课程存在（租户收紧）→ 有
  published revision → 租户最新 published `type=learning` 定义 → 按 key 查
  任意状态 run（命中 → `{:ok, run, :existing}`）→ 否则 create+start
  （`{:ok, run, :created}`；**revision 经 input 直带**——`input_snapshot
  ["course_revision_id"]` 创建期固化，ADR-0011 L6，引擎面零膨胀）。

  错误一律 `{:error, String.t()}`（MCP 工具直返；"forbidden" 前缀供 Wrapper
  归类审计）。
  """
  @spec start(term(), String.t(), String.t()) ::
          {:ok, WorkflowRun.t(), :existing | :created} | {:error, String.t()}
  def start(actor, workspace_id, course_id) do
    with :ok <- ensure_enrolled(actor, workspace_id, course_id),
         {:ok, course} <- Course.fetch_scoped(workspace_id, course_id),
         {:ok, revision} <- fetch_current_revision(workspace_id, course),
         {:ok, definition} <- fetch_learning_definition(workspace_id) do
      # D8（issue #505）：user × revision 非终态去重（subject 列预查为真源，
      # key 降级为可读标签）——活动/课程双通道报名汇入同一 run。
      case resumable_run(actor.id, workspace_id, revision.id) do
        {:ok, %WorkflowRun{} = run} ->
          {:ok, run, :existing}

        {:ok, nil} ->
          with {:ok, enrollment} <- fetch_enrollment(actor, workspace_id, course_id) do
            input = %{
              "enrollment_id" => enrollment.id,
              "user_id" => actor.id,
              "course_id" => course.id,
              "title" => course.title,
              "course_revision_id" => revision.id
            }

            create_learning_run(workspace_id, definition, input)
          end
      end
    end
  end

  @doc """
  学员在某课程的非终态 learning run（pending/running/waiting；inserted_at desc
  首条）。revision 单调递增，inserted_at 最新即绑定最新版本——「latest revision
  first」的代理。
  """
  @spec active_run_for(term(), String.t(), String.t()) :: WorkflowRun.t() | nil
  def active_run_for(actor, workspace_id, course_id) do
    actor
    |> runs_query(course_id)
    |> Ash.Query.filter(status in ^@active_statuses)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false, tenant: workspace_id)
  end

  @doc "学员在某课程的最新 learning run（任意状态；完成态仍可展示，供 get_learning_state / GraphQL）。"
  @spec latest_run_for(term(), String.t(), String.t()) :: WorkflowRun.t() | nil
  def latest_run_for(actor, workspace_id, course_id) do
    actor
    |> runs_query(course_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false, tenant: workspace_id)
  end

  @doc """
  run 绑定的课程版本（未绑定 → `{:ok, nil}`；租户收紧）。
  **input_snapshot 单源**（ADR-0011 L6）：`input_snapshot["course_revision_id"]`
  是 run × revision 域事实的唯一读取面。
  """
  @spec revision_of(WorkflowRun.t()) :: {:ok, CourseRevision.t() | nil}
  def revision_of(%WorkflowRun{} = run) do
    case bound_revision_id(run) do
      revision_id when is_binary(revision_id) ->
        Cgc2046.Curriculum.revision_by_id(run.workspace_id, revision_id)

      _ ->
        {:ok, nil}
    end
  end

  @doc "run 的全部 attempts（created_at 升序 = 评价时间序）。"
  @spec attempts_for(WorkflowRun.t()) :: [Attempt.t()]
  def attempts_for(%WorkflowRun{} = run) do
    Attempt
    |> Ash.Query.filter(learning_run_id == ^run.id)
    |> Ash.Query.sort(created_at: :asc)
    |> Ash.read!(authorize?: false, tenant: run.workspace_id)
  end

  @doc "run 的掌握投影：Mastery.states(attempts, objectives)。"
  @spec states_for(WorkflowRun.t(), [map()]) :: %{String.t() => Mastery.state_entry()}
  def states_for(%WorkflowRun{} = run, objectives) when is_list(objectives) do
    run |> attempts_for() |> Mastery.states(objectives)
  end

  # --- 完成判定（R39/AE10） --------------------------------------------------------

  @doc """
  完成判定：run running ∧ 绑定 revision ∧ 必修非空全 ever_mastered →
  `:complete`（置 succeeded）。

  返回 `{:ok, outcome, run}`，outcome ∈ `:completed | :incomplete | :not_running`；
  `:incomplete` 覆盖「未绑版本 / 必修集为空 / 尚有未掌握必修」。update 失败
  （乐观锁竞态等）→ `{:error, reason}`。**非同事务由调用方保证**（§B#12：
  submit 即时调用不回滚账本，worker 兜底）。
  """
  @spec complete_when_mastered(WorkflowRun.t()) ::
          {:ok, :completed | :incomplete | :not_running, WorkflowRun.t()} | {:error, term()}
  def complete_when_mastered(%WorkflowRun{status: :running} = run) do
    with {:ok, %CourseRevision{} = revision} <- revision_of(run),
         objectives when objectives != [] <- Content.objectives(revision.content),
         states <- states_for(run, objectives),
         true <- Mastery.all_required_ever_mastered?(states, objectives) do
      case run
           |> Ash.Changeset.for_update(:complete, %{},
             tenant: run.workspace_id,
             authorize?: false
           )
           |> Ash.update(tenant: run.workspace_id, authorize?: false) do
        {:ok, completed} -> {:ok, :completed, completed}
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> {:ok, :incomplete, run}
    end
  end

  def complete_when_mastered(%WorkflowRun{} = run), do: {:ok, :not_running, run}

  # --- 停滞口径（D6-③/R50） --------------------------------------------------------

  @doc "学习 run 停滞阈值（天；提醒与对账规则⑦同源）。"
  def stagnation_threshold_days, do: @stagnation_threshold_days

  @doc "停滞判定 cutoff：最后活动时间严格早于此（7 天前）视为停滞。"
  @spec stagnant_cutoff(DateTime.t()) :: DateTime.t()
  def stagnant_cutoff(now \\ DateTime.utc_now()) do
    DateTime.add(now, -@stagnation_threshold_days, :day)
  end

  @doc """
  run 最后活动时间（R50 口径）：最新 attempt `created_at`；零 attempt 回退
  run `inserted_at`（从未评价的学习以其启动时间计）。
  """
  @spec last_activity_at(WorkflowRun.t()) :: DateTime.t()
  def last_activity_at(%WorkflowRun{} = run) do
    Attempt
    |> Ash.Query.filter(learning_run_id == ^run.id)
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false, tenant: run.workspace_id)
    |> case do
      %Attempt{created_at: created_at} -> created_at
      nil -> run.inserted_at
    end
  end

  @doc "停滞判定：最后活动时间严格早于 cutoff（now - 7 天）。"
  @spec stagnant?(WorkflowRun.t(), DateTime.t()) :: boolean()
  def stagnant?(%WorkflowRun{} = run, now \\ DateTime.utc_now()) do
    case last_activity_at(run) do
      nil -> false
      at -> DateTime.compare(at, stagnant_cutoff(now)) == :lt
    end
  end

  # --- 学习状态投影（get_learning_state / GraphQL 共用） -----------------------------

  @doc """
  学员学习状态投影（S8；get_learning_state 工具与 GraphQL courseLearningDetail
  共用单源）。

  - run 不存在 → 当前 published revision 的 objectives，全 unassessed；
  - run 绑定当前 revision → 当前 revision objectives + run 掌握投影；
  - run 绑定**旧** revision → 报 run 自己 revision 的 objectives + states，
    `stale_revision: true`（学完旧版前不被新版内容 silently 换底）。

  `review_queue`（R45）由 `ReviewSchedule.due/3` 从同一批 attempts 派生
  （needs_review 恒立即到期 / 里程碑按序消费）；`next_action` 按投影同一份
  objectives+states+review_queue 计算（完成 → nil，AE10：完成守卫先行，
  复习到期不再打扰已完成课程）。
  """
  @spec learning_state(term(), Course.t() | nil) :: map()
  # 事件型 enrollment（无 course）→ 空投影（objectives [] / progress 0,0,false /
  # next nil——事件学习不走 objective 循环，行仍展示）
  def learning_state(_actor, nil) do
    %{
      run: nil,
      revision_id: nil,
      revision_number: nil,
      stale_revision: false,
      objectives: [],
      review_queue: [],
      next_action: nil,
      progress: %{mastered_required: 0, total_required: 0, complete: false}
    }
  end

  def learning_state(actor, %Course{} = course) do
    workspace_id = course.workspace_id
    run = latest_run_for(actor, workspace_id, course.id)
    current = current_revision(workspace_id, course)

    {revision, stale?} = resolve_projection_revision(run, current)
    run_row = if is_nil(run), do: nil, else: run_summary(run, revision)

    objectives = if revision, do: Content.objectives_with_issue(revision.content), else: []

    attempts =
      case {run, revision} do
        {%WorkflowRun{input_snapshot: %{"course_revision_id" => rid}}, %CourseRevision{id: rid}}
        when not is_nil(rid) ->
          attempts_for(run)

        _ ->
          []
      end

    states = Mastery.states(attempts, objectives)
    review_queue = ReviewSchedule.due(attempts, objectives, DateTime.utc_now())

    %{
      run: run_row,
      revision_id: revision && revision.id,
      revision_number: current && current.number,
      stale_revision: stale?,
      objectives: project_objectives(objectives, states),
      review_queue: review_queue,
      next_action: NextAction.next(objectives, states, review_queue),
      progress: progress(objectives, states)
    }
  end

  @doc """
  本人学习 run 投影列表（myLearningRuns 读面；issue #505 D8 user 维度）：

  `subject_user_id == actor.id` 直查（全局读，本人锚单条件即充分）——
  活动/课程双通道汇入的 run 无论锚在哪条 enrollment 上都归学员本人；
  definition 投影元数据随查询加载 → `RunProjection.project_run/2`。
  读失败降级 `[]`（附挂信息不阻断主读，与 discover_offerings 同纪律）。

  只投影 `subject_course_id` 非空的 run（#507）：无配套课的事件型 run 无
  objective 循环可展示，不进学习页（event 参与语义由 myEnrollments 承担）；
  活动挂配套课后 run 带 course 锚，正常进入学习闭环（#505 D8）；已取消
  offering 的 run 由 `RunProjection.project_run/2` 排除。
  """
  @spec my_learning_runs(term()) :: {:ok, [map()]}
  def my_learning_runs(%{id: actor_id} = actor) do
    WorkflowRun
    |> Ash.Query.filter(
      # 只投影有 course 锚的 run（#507）：无配套课的事件型 run 无 objective
      # 可展示；活动挂配套课后 run 经 D8 注入 course_id 正常进入（#505）。
      definition.type == :learning and subject_user_id == ^actor_id and
        not is_nil(subject_course_id)
    )
    |> Ash.Query.load(definition: [:type, :node_def, steps: [:step_key, :title]])
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, %{results: results}} -> {:ok, project_rows(results, actor)}
      {:ok, runs} when is_list(runs) -> {:ok, project_rows(runs, actor)}
      {:error, _reason} -> {:ok, []}
    end
  end

  def my_learning_runs(_actor), do: {:ok, []}

  defp project_rows(runs, actor) do
    titles = load_target_titles(runs)

    runs
    |> Enum.map(&RunProjection.project_run(&1, actor, titles))
    |> Enum.reject(&is_nil/1)
  end

  # 展示用快照标题：run 锚的 enrollment 行的 target_title 计算（快照优先
  # → offering 标题回落）；按租户分组批量读，避免逐 run N+1。
  defp load_target_titles(runs) do
    runs
    |> Enum.group_by(& &1.workspace_id)
    |> Enum.flat_map(fn {workspace_id, group} ->
      ids = group |> Enum.map(& &1.subject_enrollment_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

      Enrollment
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.load(:target_title)
      |> Ash.read!(authorize?: false, tenant: workspace_id)
    end)
    |> Map.new(&{&1.id, &1.target_title})
  end

  # D9（issue #505）：课程 confirmed 报名 ∨ 挂载授权（锚定活动的 confirmed
  # 报名）——活动报名者在 OpenClacky 直接启动配套课学习。
  defp ensure_enrolled(actor, workspace_id, course_id) do
    if confirmed_enrollment?(actor, workspace_id, course_id) or
         mounted_enrollment?(actor, workspace_id, course_id) do
      :ok
    else
      {:error, "forbidden: confirmed enrollment required to start learning"}
    end
  end

  defp fetch_current_revision(workspace_id, %Course{current_revision_id: nil}),
    do: {:error, "course has no published revision yet (workspace #{workspace_id})"}

  defp fetch_current_revision(workspace_id, %Course{current_revision_id: revision_id}) do
    case Cgc2046.Curriculum.revision_by_id(workspace_id, revision_id) do
      {:ok, nil} -> {:error, "published revision not found: #{revision_id}"}
      {:ok, revision} -> {:ok, revision}
      {:error, _} -> {:error, "failed to load course revision"}
    end
  end

  defp current_revision(_workspace_id, %Course{current_revision_id: nil}), do: nil

  defp current_revision(workspace_id, %Course{current_revision_id: revision_id}) do
    case Cgc2046.Curriculum.revision_by_id(workspace_id, revision_id) do
      {:ok, revision} -> revision
      _ -> nil
    end
  end

  # 公开供测试直接驱动（同 PrepInstantiator.fetch_prep_definition 先例）
  @doc false
  def fetch_learning_definition(workspace_id) do
    WorkflowDefinition
    |> Ash.Query.filter(type == :learning and status == :published)
    |> Ash.Query.sort(version: :desc, inserted_at: :desc)
    |> Ash.read_first(authorize?: false, tenant: workspace_id)
    |> case do
      {:ok, nil} -> {:error, "no published learning workflow definition"}
      {:ok, definition} -> {:ok, definition}
      {:error, _} -> {:error, "failed to load learning workflow definition"}
    end
  end

  # D9：input 锚的 enrollment 行——优先课程报名行（双通道并存时课程行优先，
  # 来源快照语义更直）；无课程行 → 挂载授权的活动报名行（最新一条）。
  defp fetch_enrollment(%{id: actor_id}, workspace_id, course_id) do
    Enrollment
    |> Ash.Query.filter(
      workspace_id == ^workspace_id and course_id == ^course_id and
        user_id == ^actor_id and status == :confirmed
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> fetch_mounted_enrollment(actor_id, workspace_id, course_id)
      {:ok, enrollment} -> {:ok, enrollment}
      {:error, _} -> {:error, "failed to load enrollment"}
    end
  end

  defp fetch_mounted_enrollment(actor_id, workspace_id, course_id) do
    with revision_ids when revision_ids != [] <- revision_ids_of(workspace_id, course_id),
         event_ids when event_ids != [] <- anchored_event_ids(workspace_id, revision_ids) do
      Enrollment
      |> Ash.Query.filter(
        workspace_id == ^workspace_id and user_id == ^actor_id and
          event_id in ^event_ids and status == :confirmed
      )
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one(authorize?: false)
      |> case do
        {:ok, nil} -> {:error, "forbidden: confirmed enrollment required to start learning"}
        {:ok, enrollment} -> {:ok, enrollment}
        {:error, _} -> {:error, "failed to load enrollment"}
      end
    else
      _ -> {:error, "forbidden: confirmed enrollment required to start learning"}
    end
  end

  defp runs_query(%{id: actor_id}, course_id) do
    WorkflowRun
    |> Ash.Query.filter(
      definition.type == :learning and
        subject_course_id == ^course_id and subject_user_id == ^actor_id
    )
  end

  # D8 创建路径：key 为可读标签；并发双种撞 partial unique index
  # （subject_user_id × subject_course_revision_id 非终态唯一）→ 回读转
  # :existing（预查与索引之间的窄窗口兜底）。
  defp create_learning_run(workspace_id, definition, input) do
    WorkflowRun.find_or_create_and_start(workspace_id, definition, input,
      key: instance_key(input["user_id"], input["course_revision_id"]),
      start_action: :start
    )
  rescue
    Ecto.ConstraintError ->
      case non_terminal_run(input["user_id"], workspace_id, input["course_revision_id"]) do
        {:ok, %WorkflowRun{} = run} -> {:ok, run, :existing}
        other -> other
      end
  end

  # 投影用 revision 选择：run 绑旧版 → run 自己版本 + stale；否则当前版本
  defp resolve_projection_revision(nil, current), do: {current, false}

  defp resolve_projection_revision(%WorkflowRun{} = run, current) do
    bound_id = bound_revision_id(run)

    cond do
      is_nil(bound_id) ->
        {current, false}

      current && current.id == bound_id ->
        {current, false}

      true ->
        case revision_of(run) do
          {:ok, %CourseRevision{} = bound} -> {bound, true}
          _ -> {current, false}
        end
    end
  end

  defp bound_revision_id(%WorkflowRun{subject_course_revision_id: revision_id})
       when is_binary(revision_id), do: revision_id

  defp bound_revision_id(%WorkflowRun{input_snapshot: snapshot}) when is_map(snapshot),
    do: snapshot["course_revision_id"]

  defp bound_revision_id(%WorkflowRun{}), do: nil

  defp run_summary(%WorkflowRun{} = run, revision) do
    %{
      id: run.id,
      status: to_string(run.status),
      revision_id: bound_revision_id(run),
      revision_number: revision && revision.number
    }
  end

  defp project_objectives(objectives, states) do
    Enum.map(objectives, fn objective ->
      entry = Map.get(states, objective["id"], %{})
      missing = NextAction.missing_prereq_ids(objective, states)

      %{
        id: objective["id"],
        title: objective["title"],
        required: Content.required_objective?(objective),
        issue_id: objective["issue_id"],
        prereq_ids: prereq_ids(objective),
        mastery: to_string(Map.get(entry, :state, :unassessed)),
        ever_mastered: Map.get(entry, :ever_mastered, false),
        locked: not NextAction.unlocked?(objective, states),
        missing_prereq_ids:
          Enum.map(missing, fn prereq_id ->
            %{id: prereq_id, title: title_of(objectives, prereq_id)}
          end),
        attempt_count: Map.get(entry, :attempt_count, 0),
        last_attempt_at: Map.get(entry, :last_attempt_at)
      }
    end)
  end

  defp title_of(objectives, objective_id) do
    case Enum.find(objectives, &(&1["id"] == objective_id)) do
      %{"title" => title} -> title
      _ -> nil
    end
  end

  defp progress(objectives, states) do
    required = Enum.filter(objectives, &Content.required_objective?/1)
    mastered = Enum.count(required, &Mastery.ever_mastered?(states, &1["id"]))

    %{
      mastered_required: mastered,
      total_required: length(required),
      complete: Mastery.all_required_ever_mastered?(states, objectives)
    }
  end

  defp prereq_ids(objective) do
    case objective["prereq_ids"] do
      ids when is_list(ids) -> Enum.filter(ids, &is_binary/1)
      _ -> []
    end
  end
end
