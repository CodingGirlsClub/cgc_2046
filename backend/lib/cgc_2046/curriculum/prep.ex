defmodule Cgc2046.Curriculum.Prep do
  @moduledoc """
  课程教研流程（role-agent-journeys-v2 S5，R22-R28）的唯一逻辑宿主：
  Course Preparation WorkflowRun 的读取、判定与状态迁移，供九个 MCP 教研
  工具与 `Courses.Course :launch` 教研门共用。

  ## 模型（协议而非 DAG，与 learning run 同款）

  - prep run = `type=:course_preparation` 的 WorkflowRun——实例化即 `:start`
    （pending → running），不经 Engine；run status 全程 `running`，发布时
    `:complete`（succeeded）。
  - `prep_state` 存 run `facts["prep_state"]`（string），状态机：
    `draft → authoring → quality_check → review → published`；
    `request_changes` / 低于阈值的质量报告回 `authoring`。缺省（facts 未写）
    视为 `draft`。
  - **策略快照**（R22）：实例化时固化于 `input_snapshot["prep_policy"]`
    （`review_required: true / quality_threshold: 80 / reviewer_user_id: nil`）。
    快照保持不可变；Owner/Admin 提交前的调整写 `facts["prep_policy_override"]`，
    `policy/1` 以 override-first 合并读出**生效策略**。生效策略在提交时固定——
    进入 quality_check 后 `update_prep_policy` 一律拒绝。
  - 实例 key：`course_prep_<course_id>`（每门课程恰一个非终态 prep run，
    `WorkflowRun.find_or_create_and_start/4` 非终态去重）。
  - **发布语义（S6，R29）**：发布步单事务 = 复跑门禁（提交后草稿可再改，
    不过整体回滚）→ 创建不可变 `CourseRevision`（number = max+1，撞唯一索引
    重读重试一次）→ 调 Courses 发布端口 `Course.bind_revision_for_publish/3`
    （绑定 current_revision_id + 课程 draft 时 launch `via_prep: true`，已
    open 只换绑）→ prep_state published + run `:complete`（succeeded）。发布后
    课程进入次 prep 周期：`ensure_active_run/2` 懒开新 run（沿用上任
    assignee）。

  ## 授权分工

  角色判定（assignee / tutor / reviewer-per-policy / owner-admin）在 MCP 工具层
  按迁移逐一完成；本模块提供 `manage?/2`、`tutor?/2`、`reviewer?/2` 判定助手与
  带前置断言的迁移函数（前置不满足返回 `{:error, message}`）。facts 写走
  `:update_prep_facts`（facts 整体替换 + version 乐观锁 + 终态拒绝，成员
  bypass 学员不放行）；**认领 = run version 乐观锁 CAS**（读 version → 校验
  assignee 空 → 带 version 更新，冲突方 StaleRecord 落败——并发双认领恰一成
  一败，零裸 SQL，plan §A 对旧实现条件 UPDATE 的改判）。发布步的
  launch/complete 是流程级系统效应（授权已在工具层完成），以
  `authorize?: false` 执行并注入 `context: %{via_prep: true}` 放行 launch
  教研门（§B#10：changeset context 而非参数，GraphQL/MCP 参数面无法伪造）。
  """

  require Ash.Query
  require Logger

  alias Cgc2046.Accounts.{MembershipContext, Role}
  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.{CourseRevision, Output, PrepGate, PrepInstantiator}
  alias Cgc2046.Repo
  alias Cgc2046.Workflows.WorkflowRun

  @non_terminal_statuses [:pending, :running, :waiting]

  @default_policy %{
    "review_required" => true,
    "quality_threshold" => 80,
    "reviewer_user_id" => nil
  }

  @prep_states ["draft", "authoring", "quality_check", "review", "published"]

  # --- 读取 ----------------------------------------------------------------

  @doc "实例 key 约定（`course_prep_<course_id>`）；instantiator 与读取面共用。"
  @spec instance_key(String.t()) :: String.t()
  def instance_key(course_id), do: "course_prep_#{course_id}"

  @doc "默认策略快照（R22）；instantiator 写入 input_snapshot 的唯一来源。"
  @spec default_policy() :: map()
  def default_policy, do: @default_policy

  @doc "prep_state 五态（facts string 值）。"
  @spec prep_states() :: [String.t()]
  def prep_states, do: @prep_states

  @doc """
  取课程的非终态 prep run（无 → nil）。DB 错误上抛（fail-closed：launch 教研门
  宁可发布失败不可误放行）。
  """
  @spec fetch_run(String.t(), String.t()) :: WorkflowRun.t() | nil
  def fetch_run(course_id, workspace_id) do
    WorkflowRun
    |> Ash.Query.filter(
      definition.type == :course_preparation and
        status in ^@non_terminal_statuses and
        input_snapshot["key"] == ^instance_key(course_id)
    )
    |> Ash.read_one!(authorize?: false, tenant: workspace_id)
  end

  @doc "prep_state（facts 未写 = draft）。"
  @spec prep_state(WorkflowRun.t()) :: String.t()
  def prep_state(%WorkflowRun{facts: facts}) do
    (facts || %{})["prep_state"] || "draft"
  end

  @doc "生效策略 = 默认 ← input_snapshot 快照 ← facts override（R22；提交后冻结由工具层与本模块前置断言双重保证）。"
  @spec policy(WorkflowRun.t()) :: map()
  def policy(%WorkflowRun{} = run) do
    snapshot = (run.input_snapshot || %{})["prep_policy"] || %{}
    override = (run.facts || %{})["prep_policy_override"] || %{}

    @default_policy
    |> Map.merge(snapshot)
    |> Map.merge(override)
  end

  @doc "被指派的 tutor（facts assignee_user_id；未指派 nil）。"
  @spec assignee(WorkflowRun.t()) :: String.t() | nil
  def assignee(%WorkflowRun{facts: facts}), do: (facts || %{})["assignee_user_id"]

  @doc """
  对课程跑结构门禁（R26，PrepGate 纯函数 + 实时读内容草稿）。
  返回 `%{passed, violations, draft_version}`（draft_version = 当前草稿
  Output version，无草稿为 0）。
  """
  @spec gate(Course.t()) :: %{
          passed: boolean(),
          violations: [String.t()],
          draft_version: integer()
        }
  def gate(%Course{} = course) do
    output = fetch_output(course.id, course.workspace_id)

    course
    |> PrepGate.check(output)
    |> Map.put(:draft_version, if(output, do: output.version, else: 0))
  end

  @doc "当前内容草稿行（kind=:issues, key=course_<id>；无 → nil）。"
  @spec fetch_output(String.t(), String.t()) :: Output.t() | nil
  def fetch_output(course_id, workspace_id) do
    Output
    |> Ash.Query.filter(key == ^Output.course_key(course_id) and kind == :issues)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false, tenant: workspace_id)
  end

  @doc """
  课程的活动 prep run 就位（S6 发布次周期，R29）：有非终态 run → 返回；
  缺失或已终态 → 懒开新 run（默认策略快照——新 run = 新快照机会；
  prep_state `draft`；沿用最近一个教研 run 的 assignee 保持连续性）并回写
  `course.workflow_run_id`。

  接线面 = `get_prep_status` 与 `submit_prep_for_check`（发布后编辑自动有
  活动 run 驱动下一版本）；`PrepInstantiator` 的 course.created 首周期
  实例化不变。无已 published 的 course_preparation 定义 → 返回错误（存量
  工作台同 get_prep_status 旧语义）。实例化/回写/assignee 沿用均为系统
  效应（authorize?: false；成员门槛在工具层）。
  """
  @spec ensure_active_run(Course.t(), keyword()) ::
          {:ok, WorkflowRun.t()} | {:error, String.t()}
  def ensure_active_run(%Course{} = course, opts \\ []) do
    case fetch_run(course.id, course.workspace_id) do
      %WorkflowRun{} = run -> {:ok, run}
      nil -> spawn_next_run(course, opts)
    end
  end

  # --- 角色判定助手（工具层授权用） -------------------------------------------

  @doc "actor 是否目标工作台 Owner/Admin。"
  @spec manage?(term(), String.t()) :: boolean()
  def manage?(actor, workspace_id) do
    actor
    |> MembershipContext.role_names(workspace_id)
    |> Enum.any?(&Role.manage_role?/1)
  end

  @doc "actor 是否持有目标工作台 tutor 角色。"
  @spec tutor?(term(), String.t()) :: boolean()
  def tutor?(actor, workspace_id) do
    :tutor in MembershipContext.role_names(actor, workspace_id)
  end

  @doc """
  reviewer-per-policy 判定（R28）：快照指定 reviewer_user_id → 仅本人；
  未指定 → 任何工作台成员（成员门槛由 Wrapper member-only 门保证，本函数
  不再重复判定），允许 tutor 自审。Owner/Admin 豁免由工具层并集完成。
  """
  @spec reviewer?(WorkflowRun.t(), term()) :: boolean()
  def reviewer?(%WorkflowRun{} = run, actor) do
    case policy(run)["reviewer_user_id"] do
      nil -> true
      reviewer_id when is_binary(reviewer_id) -> reviewer_id == actor.id
    end
  end

  # --- 迁移（前置断言 + facts 乐观锁写入；角色授权在工具层） -------------------

  @doc """
  Owner/Admin 指派 tutor（R24）：写 facts assignee；prep_state draft → authoring
  （非 draft 保持现态——审核中指派不打断流程）。可再指派（reassign）。
  """
  @spec assign_tutor(WorkflowRun.t(), String.t(), term()) ::
          {:ok, WorkflowRun.t()} | {:error, String.t()}
  def assign_tutor(%WorkflowRun{} = run, tutor_user_id, actor) do
    with :ok <- require_state(run, @prep_states -- ["published"]) do
      patch = %{"assignee_user_id" => tutor_user_id}

      patch =
        if prep_state(run) == "draft",
          do: Map.put(patch, "prep_state", "authoring"),
          else: patch

      put_facts(run, patch, actor)
    end
  end

  @doc """
  tutor 原子认领未指派的 authoring（R24）：**run version 乐观锁 CAS**——
  读 version → 校验 assignee 空且 prep_state ∈ (draft, authoring) → 带 version
  更新；并发双认领中后到者 StaleRecord 落败（恰一成一败，语义等价旧实现的
  DB 条件 UPDATE，零裸 SQL——plan §A 改判）。
  """
  @spec claim(WorkflowRun.t(), String.t(), term()) ::
          {:ok, WorkflowRun.t()} | {:error, String.t()}
  def claim(%WorkflowRun{} = run, user_id, actor) do
    with :ok <- require_state(run, ["draft", "authoring"]),
         :ok <- require_unassigned(run) do
      patch = %{"assignee_user_id" => user_id, "prep_state" => "authoring"}

      case put_facts(run, patch, actor) do
        {:ok, updated} ->
          {:ok, updated}

        {:error, msg} ->
          # 并发落败（version 乐观锁 StaleRecord 由 put_facts 映射为并发文案）
          # 归一为认领失败语义
          {:error, "prep authoring already claimed or not claimable (#{msg})"}
      end
    end
  end

  @doc """
  Owner/Admin 调整策略（R22）：合并进 `facts["prep_policy_override"]`（快照本体
  不可变）。仅 draft/authoring 可改——进入 quality_check 即提交，生效策略冻结。
  patch 键白名单：review_required / quality_threshold / reviewer_user_id。
  """
  @spec update_policy(WorkflowRun.t(), map(), term()) ::
          {:ok, WorkflowRun.t()} | {:error, String.t()}
  def update_policy(%WorkflowRun{} = run, patch, actor) do
    with :ok <- require_state(run, ["draft", "authoring"]) do
      override =
        ((run.facts || %{})["prep_policy_override"] || %{})
        |> Map.merge(patch)

      put_facts(run, %{"prep_policy_override" => override}, actor)
    end
  end

  @doc """
  提交质量检查（R26）：同步跑结构门禁。通过 → prep_state `quality_check` +
  记录 gate_passed_at / 检查的草稿版本（并清掉既往门禁违规与待覆盖报告——
  最近一次门禁通过是覆盖判定的基准）；未过 → 保持 `authoring` + 记录违规清单。
  返回 `{:ok, run, gate_result}`（两种结果都不抛错，违规清单由工具层回报）。
  """
  @spec submit_for_check(WorkflowRun.t(), term()) ::
          {:ok, WorkflowRun.t(), map()} | {:error, String.t()}
  def submit_for_check(%WorkflowRun{} = run, actor) do
    with :ok <- require_state(run, ["authoring"]),
         {:ok, course} <- fetch_course(run) do
      gate = gate(course)

      if gate.passed do
        patch = %{
          "prep_state" => "quality_check",
          "gate_passed_at" => now_iso(),
          "gate_checked_draft_version" => gate.draft_version
        }

        with {:ok, run} <-
               put_facts(run, patch, actor, ["gate_violations", "below_threshold_pending"]) do
          {:ok, run, gate}
        end
      else
        with {:ok, run} <- put_facts(run, %{"gate_violations" => gate.violations}, actor) do
          {:ok, run, gate}
        end
      end
    end
  end

  @doc """
  tutor 本地 agent 提交结构化质量报告（R27）：前置 quality_check。报告落
  `facts["latest_quality_report"]`（含当前草稿版本/提交人/时间/结论）。

  - score < 生效阈值 → 回 `authoring`，报告记入 `below_threshold_pending`
    （override_prep_gate 的前置锚）；
  - score ≥ 阈值 → review_required ? `review` : 发布（publish/4，S6 语义 =
    生成不可变 CourseRevision + 绑定课程当前版本 + launch）。
    返回 `{:ok, run, :below_threshold | :review | :published}`。
  """
  @spec submit_quality_report(WorkflowRun.t(), term(), map()) ::
          {:ok, WorkflowRun.t(), atom()} | {:error, String.t()}
  def submit_quality_report(%WorkflowRun{} = run, actor, report) do
    with :ok <- require_state(run, ["quality_check"]),
         {:ok, course} <- fetch_course(run) do
      policy = policy(run)
      output = fetch_output(course.id, run.workspace_id)

      stored =
        report
        |> Map.take(["score", "summary", "findings"])
        |> Map.merge(%{
          "draft_version" => if(output, do: output.version, else: 0),
          "submitted_by" => actor.id,
          "submitted_at" => now_iso()
        })

      if stored["score"] < policy["quality_threshold"] do
        patch = %{
          "prep_state" => "authoring",
          "latest_quality_report" => Map.put(stored, "outcome", "below_threshold"),
          "below_threshold_pending" => stored
        }

        with {:ok, run} <- put_facts(run, patch, actor) do
          {:ok, run, :below_threshold}
        end
      else
        patch = %{"latest_quality_report" => Map.put(stored, "outcome", "passed")}

        if policy["review_required"] do
          with {:ok, run} <- put_facts(run, Map.put(patch, "prep_state", "review"), actor) do
            {:ok, run, :review}
          end
        else
          with {:ok, run} <- publish(run, actor, patch) do
            {:ok, run, :published}
          end
        end
      end
    end
  end

  @doc """
  覆盖低于阈值的质量报告（R27/AE5，审计）：前置 = 存在待覆盖报告
  （`below_threshold_pending`，即最近门禁通过后有低于阈值的报告）。理由必填
  由工具层保证；facts 记 `gate_override`（overridden_by/reason/at）。按生效策略
  推进：review_required → `review`；否则发布。
  """
  @spec override_gate(WorkflowRun.t(), term(), String.t()) ::
          {:ok, WorkflowRun.t(), :review | :published} | {:error, String.t()}
  def override_gate(%WorkflowRun{} = run, actor, reason) do
    with :ok <- require_state(run, ["authoring"]),
         :ok <- require_below_threshold_pending(run) do
      record = %{
        "overridden_by" => actor.id,
        "reason" => reason,
        "at" => now_iso()
      }

      if policy(run)["review_required"] do
        patch = %{"prep_state" => "review", "gate_override" => record}

        with {:ok, run} <- put_facts(run, patch, actor, ["below_threshold_pending"]) do
          {:ok, run, :review}
        end
      else
        with {:ok, run} <-
               publish(run, actor, %{"gate_override" => record}, ["below_threshold_pending"]) do
          {:ok, run, :published}
        end
      end
    end
  end

  @doc "审核通过（R28）：前置 review → 发布。"
  @spec approve(WorkflowRun.t(), term()) :: {:ok, WorkflowRun.t()} | {:error, String.t()}
  def approve(%WorkflowRun{} = run, actor) do
    with :ok <- require_state(run, ["review"]),
         {:ok, run} <-
           publish(run, actor, %{"approved_by" => actor.id, "approved_at" => now_iso()}) do
      {:ok, run}
    end
  end

  @doc "请求修改（R28）：前置 review → 回 authoring，理由追加进 facts change_requests。"
  @spec request_changes(WorkflowRun.t(), term(), String.t()) ::
          {:ok, WorkflowRun.t()} | {:error, String.t()}
  def request_changes(%WorkflowRun{} = run, actor, reason) do
    with :ok <- require_state(run, ["review"]) do
      requests =
        ((run.facts || %{})["change_requests"] || []) ++
          [
            %{"requested_by" => actor.id, "reason" => reason, "at" => now_iso()}
          ]

      put_facts(run, %{"prep_state" => "authoring", "change_requests" => requests}, actor)
    end
  end

  @doc """
  发布步（S6，R29）：**单事务**内——

  1. 重读当前草稿（Output 活文档）并防御性复跑 PrepGate（必须过；提交后
     草稿可再改，不过 → 整体回滚，prep_state 不变）；
  2. 创建不可变 CourseRevision（number = 该课程 max(number)+1，内容 = 当前
     草稿快照，prep_run_id/published_by_id/published_at 溯源审计列）；
  3. 调 Courses 发布端口 `Course.bind_revision_for_publish/3`：绑定
     `course.current_revision_id` 并 launch（via_prep 语义不变；课程已
     open——次周期发布——跳过 launch 只换绑版本）；
  4. prep_state → `published`、run `:complete`（succeeded）、facts 记
     published_at / published_by / published_revision_id /
     published_revision_number（外加调用方 facts_patch，如 approved_by /
     gate_override / latest_quality_report）。

  撞 `(course_id, number)` 唯一索引（并发发布同门课程）→ 重读 max 重试一次
  （新事务）。launch/complete 是流程级系统效应（授权已在工具层完成），
  `authorize?: false` 执行并经端口注入 `context: %{via_prep: true}` 放行
  launch 教研门（§B#10）。
  """
  @spec publish(WorkflowRun.t(), term(), map(), [String.t()]) ::
          {:ok, WorkflowRun.t()} | {:error, String.t()}
  def publish(%WorkflowRun{} = run, actor, facts_patch \\ %{}, drop \\ []) do
    case publish_once(run, actor, facts_patch, drop) do
      {:error, reason} ->
        # 撞号识别在外壳（Ash 3 的 identity 冲突可能以 :revision_number_conflict
        # 哨兵或原始 changeset/Invalid 形态从事务里漏出——双态全接）→ 重读
        # max(number) 重试一次（新事务）；其余错误归一为字符串契约
        if reason == :revision_number_conflict or revision_number_conflict?(reason) do
          case publish_once(run, actor, facts_patch, drop) do
            {:error, retried} -> {:error, error_message(retried, "publish failed")}
            other -> other
          end
        else
          {:error, error_message(reason, "publish failed")}
        end

      other ->
        other
    end
  end

  # --- 私有实现 --------------------------------------------------------------

  defp publish_once(%WorkflowRun{} = run, actor, facts_patch, drop) do
    Repo.transaction(fn ->
      with {:ok, course} <- fetch_course(run),
           {:ok, output} <- guard_publishable(course),
           {:ok, revision} <- create_revision(course, output, run, actor),
           {:ok, _course} <- Course.bind_revision_for_publish(course, revision, actor),
           {:ok, completed} <- complete_run(run, actor, revision, facts_patch, drop) do
        completed
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # 发布前的防御性结构复核（R26 完整形态）：提交时门禁已过不保证发布时点草稿
  # 仍合规（提交后草稿可再改）；不过 → 回滚，prep_state 不变。门禁通过必有草稿行。
  defp guard_publishable(%Course{} = course) do
    output = fetch_output(course.id, course.workspace_id)
    gate = PrepGate.check(course, output)

    if gate.passed do
      {:ok, output}
    else
      {:error, "publish blocked by structure gate: " <> Enum.join(gate.violations, "；")}
    end
  end

  defp create_revision(%Course{} = course, %Output{} = output, run, actor) do
    attrs = %{
      course_id: course.id,
      number: next_revision_number(course.id, run.workspace_id),
      content: output.data,
      prep_run_id: run.id,
      published_by_id: actor.id,
      published_at: DateTime.utc_now()
    }

    case CourseRevision
         |> Ash.Changeset.for_create(:create, attrs, tenant: run.workspace_id)
         |> Ash.create(tenant: run.workspace_id, actor: actor, authorize?: false) do
      {:ok, revision} ->
        {:ok, revision}

      {:error, error} ->
        # Ash 3 失败返回 changeset 或 Invalid——统一归一后识别撞号
        if revision_number_conflict?(error) do
          {:error, :revision_number_conflict}
        else
          {:error, error_message(error, "failed to create course revision")}
        end
    end
  end

  # per-course 单调编号（R29）：max(number)+1；唯一索引兜底（撞号由 publish/4
  # 重试一次）。DB 错误上抛（fail-closed，事务回滚）。
  defp next_revision_number(course_id, workspace_id) do
    CourseRevision
    |> Ash.Query.filter(course_id == ^course_id)
    |> Ash.Query.sort(number: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false, tenant: workspace_id)
    |> case do
      {:ok, nil} -> 1
      {:ok, %{number: number}} -> number + 1
      {:error, reason} -> raise "failed to read latest course revision number: #{inspect(reason)}"
    end
  end

  # (course_id, number) 唯一索引冲突识别（identity 冲突映射为 InvalidAttribute
  # "has already been taken"；裸索引冲突兜底按索引名匹配）。Ash 3 失败返回
  # changeset 或 Invalid 两种形态，errors 位置不同——双态归一。
  defp revision_number_conflict?(%Ash.Error.Invalid{errors: errors}),
    do: conflict_in_errors?(errors)

  defp revision_number_conflict?(%Ash.Changeset{errors: errors}),
    do: conflict_in_errors?(errors)

  defp revision_number_conflict?(_), do: false

  defp conflict_in_errors?(errors) do
    Enum.any?(errors, fn
      # identity 冲突可挂在 identity 任一键上（实测挂首键 course_id）
      %Ash.Error.Changes.InvalidAttribute{field: field} when field in [:course_id, :number] ->
        true

      %{message: message} when is_binary(message) ->
        message =~ "curriculum_course_revisions_unique_course_number_index"

      _ ->
        false
    end)
  end

  # Ash 3 错误归一为字符串（changeset 的 errors 逐条 message 拼接；已是
  # 字符串的错误原样透传——内部环节的友好文案不被 fallback 吞掉）
  defp error_message(message, _fallback) when is_binary(message), do: message

  defp error_message(%Ash.Changeset{errors: errors}, fallback),
    do: errors_message(errors, fallback)

  defp error_message(%Ash.Error.Invalid{} = err, _fallback), do: Exception.message(err)
  defp error_message(_other, fallback), do: fallback

  defp errors_message([], fallback), do: fallback

  defp errors_message(errors, _fallback),
    do: Enum.map_join(errors, ", ", &Exception.message/1)

  # run → 课程（input_snapshot["course_id"]，租户收紧；内部读 authorize?: false）
  defp fetch_course(%WorkflowRun{} = run) do
    case (run.input_snapshot || %{})["course_id"] do
      course_id when is_binary(course_id) ->
        case Course
             |> Ash.Query.for_read(:get_by_id, %{id: course_id})
             |> Ash.read_one(authorize?: false, tenant: run.workspace_id) do
          {:ok, %Course{} = course} -> {:ok, course}
          _ -> {:error, "course not found for prep run #{run.id}"}
        end

      _ ->
        {:error, "course not found for prep run #{run.id}"}
    end
  end

  defp complete_run(%WorkflowRun{} = run, actor, revision, facts_patch, drop) do
    facts =
      (run.facts || %{})
      |> Map.drop(drop)
      |> Map.merge(facts_patch)
      |> Map.merge(%{
        "prep_state" => "published",
        "published_at" => now_iso(),
        "published_by" => actor.id,
        "published_revision_id" => revision.id,
        "published_revision_number" => revision.number
      })

    case run
         |> Ash.Changeset.for_update(:complete, %{facts: facts}, tenant: run.workspace_id)
         # 同 launch_course：complete 是发布步的系统效应（update policy 限
         # Owner/Admin），授权已在工具层完成。Transition 的 after_transaction
         # 钩子（终态 checkpoint 清理）为同事务 DB 写，随外层事务回滚——抑制警告。
         |> Ash.Changeset.set_context(%{warn_on_transaction_hooks?: false})
         |> Ash.update(tenant: run.workspace_id, actor: actor, authorize?: false) do
      {:ok, completed} ->
        {:ok, completed}

      {:error, error} ->
        {:error, error_message(error, "failed to complete prep run")}
    end
  end

  # facts 迁移写：调用方给增量 patch（整体替换 :update_prep_facts 在此合并），
  # drop 键先删后并。version 乐观锁——陈旧 run struct 写入 StaleRecord 上抛为
  # 友好并发文案（认领 CAS 的落败判定亦锚在此）。授权：成员 bypass（细粒度
  # 角色判定在工具层）。
  defp put_facts(%WorkflowRun{} = run, patch, actor, drop \\ []) do
    facts = (run.facts || %{}) |> Map.drop(drop) |> Map.merge(patch)

    case run
         |> Ash.Changeset.for_update(:update_prep_facts, %{facts: facts},
           tenant: run.workspace_id
         )
         |> Ash.update(tenant: run.workspace_id, actor: actor) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, %Ash.Error.Invalid{} = err} ->
        if Enum.any?(err.errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) do
          {:error, "prep run changed concurrently; re-read with get_prep_status and retry"}
        else
          {:error, Exception.message(err)}
        end

      {:error, %Ash.Error.Forbidden{}} ->
        {:error, "forbidden: not allowed to update prep run in workspace #{run.workspace_id}"}

      {:error, _} ->
        {:error, "failed to update prep run"}
    end
  end

  # --- 发布次周期懒实例化（ensure_active_run 私有实现） -------------------------

  defp spawn_next_run(%Course{} = course, opts) do
    with {:ok, definition} <- fetch_prep_definition(course.workspace_id),
         {:ok, run} <-
           PrepInstantiator.launch(course.workspace_id, definition.id, %{
             "course_id" => course.id,
             "title" => course.title
           }),
         :ok <- PrepInstantiator.link_prep_run(course, run),
         {:ok, run} <- carry_over_assignee(course, run, opts[:actor]) do
      {:ok, run}
    end
  end

  # 定义读取单源 = PrepInstantiator（最新 published course_preparation；
  # 无定义 = 存量工作台旧语义「无 prep run」）
  defp fetch_prep_definition(workspace_id) do
    case PrepInstantiator.fetch_prep_definition(workspace_id) do
      {:ok, nil} -> {:error, "no published course_preparation definition in workspace"}
      {:ok, definition} -> {:ok, definition}
      {:error, _} -> {:error, "failed to load course_preparation definition"}
    end
  end

  # 连续性（R29 次周期）：沿用最近一个教研 run（含终态）的 assignee；prep_state
  # 保持 draft（再进 authoring 走 assign/claim 既有迁移）。系统效应
  # authorize?: false；失败只记日志不阻塞（best-effort，同 link_prep_run 语义）。
  defp carry_over_assignee(course, run, actor) do
    case latest_prep_run(course, exclude_id: run.id) do
      %WorkflowRun{} = previous ->
        case assignee(previous) do
          nil ->
            {:ok, run}

          assignee_user_id ->
            case put_facts_system(run, %{"assignee_user_id" => assignee_user_id}, actor) do
              {:ok, run} ->
                {:ok, run}

              {:error, reason} ->
                Logger.warning(
                  "Curriculum.Prep carry_over_assignee failed for course #{course.id}: #{inspect(reason)}"
                )

                {:ok, run}
            end
        end

      nil ->
        {:ok, run}
    end
  end

  # 最近一次教研 run（含终态；assignee 沿用的来源）。exclude_id 排除刚创建的新
  # run 自身（同 key 下 inserted_at 最新即它）。无 → nil（首周期）。
  defp latest_prep_run(%Course{} = course, exclude_id: exclude_id) do
    WorkflowRun
    |> Ash.Query.filter(
      definition.type == :course_preparation and
        input_snapshot["key"] == ^instance_key(course.id) and
        id != ^exclude_id
    )
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false, tenant: course.workspace_id)
  end

  # put_facts 的系统效应变体（authorize?: false）：次周期 assignee 沿用不依赖
  # 调用方成员 bypass（PrepInstantiator 同款纪律）。
  defp put_facts_system(%WorkflowRun{} = run, patch, actor) do
    facts = (run.facts || %{}) |> Map.merge(patch)

    case run
         |> Ash.Changeset.for_update(:update_prep_facts, %{facts: facts},
           tenant: run.workspace_id
         )
         |> Ash.update(tenant: run.workspace_id, actor: actor, authorize?: false) do
      {:ok, updated} -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_state(run, allowed) do
    state = prep_state(run)

    if state in allowed do
      :ok
    else
      {:error,
       "invalid prep_state transition: current=#{state}, allowed=#{Enum.join(allowed, "|")}"}
    end
  end

  defp require_unassigned(run) do
    case assignee(run) do
      nil ->
        :ok

      _assignee ->
        {:error, "prep authoring already claimed or not claimable (state=#{prep_state(run)})"}
    end
  end

  defp require_below_threshold_pending(run) do
    case (run.facts || %{})["below_threshold_pending"] do
      nil -> {:error, "no below-threshold quality report pending override"}
      _report -> :ok
    end
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
