defmodule Cgc2046.Mcp.Tools.OverridePrepGate do
  @moduledoc """
  覆盖低于阈值的质量报告（role-agent-journeys-v2 S5，R27/AE5，
  reviewer-per-policy 或 Owner/Admin，确认流 two-tool 写，D-D3）。

  前置：存在待覆盖的低于阈值报告（最近一次门禁通过后提交，`below_threshold_pending`）。
  理由 `reason` 必填——覆盖决定连同理由落 facts `gate_override` 审计
  （overridden_by/reason/at）。按生效策略推进：review_required → `review`；
  否则直接发布（生成不可变新 CourseRevision：draft 课程 launch，已 open 换绑）。

  确认流依据：覆盖质量门槛是高风险治理决定（绕过阈值直达审核/发布）。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.Prep
  alias Cgc2046.Mcp.{Confirmation, Wrapper}

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    Override a below-threshold quality report with an audited reason. Available to workspace
    owners/admins or the designated reviewer; when none is designated, only the assigned tutor may
    review. A pending below-threshold report is required. If review is required, the course enters
    review; otherwise it is published. The first call returns needs_confirmation, pending_id and
    summary. Call confirm_operation only after the user confirms.
    """
  end

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:course_id, {:required, :string}, description: "课程 ID（UUID）")
    field(:reason, {:required, :string}, description: "覆盖理由（必填，落审计）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "override_prep_gate", fn actor, workspace_id, params ->
        course_id = params["course_id"]
        reason = params["reason"]

        with {:ok, reason} <- require_reason(reason),
             {:ok, course} <- Course.fetch_scoped(workspace_id, course_id),
             {:ok, run} <- fetch_run(course),
             :ok <- authorize(actor, workspace_id, run),
             :ok <- require_overridable(run) do
          summary =
            "覆盖课程「#{course.title}」（#{course.id}）的低于阈值质量报告：" <>
              "理由「#{reason}」；" <>
              if(Prep.policy(run)["review_required"],
                do: "覆盖后进入人工审核（review）",
                else: "覆盖后直接发布课程（draft → open）"
              )

          Confirmation.request(
            frame.assigns[:current_user],
            "override_prep_gate",
            params,
            summary
          )
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  @doc """
  确认后真正执行（由 `Confirmation.execute/3` 直接分派调用）。
  """
  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(actor, params) do
    workspace_id = params["workspace_id"]
    course_id = params["course_id"]

    with {:ok, reason} <- require_reason(params["reason"]),
         {:ok, course} <- Course.fetch_scoped(workspace_id, course_id),
         {:ok, run} <- fetch_run(course),
         :ok <- authorize(actor, workspace_id, run),
         {:ok, updated, outcome} <- Prep.override_gate(run, actor, reason) do
      {:ok,
       %{
         course_id: course.id,
         outcome: to_string(outcome),
         prep_state: Prep.prep_state(updated)
       }}
    end
  end

  # 两段共用成员资格与当前 reviewer 判定，确认窗口内撤权或改派立即生效。
  defp authorize(actor, workspace_id, run) do
    if Cgc2046.Accounts.MembershipContext.membership_of(actor, workspace_id) &&
         (Prep.reviewer?(run, actor) or Prep.manage?(actor, workspace_id)) do
      :ok
    else
      {:error, "forbidden: reviewer-per-policy, owner or admin required to override prep gate"}
    end
  end

  # 第一段快速失败省 pending；confirm 段由 authorize 重查 + Prep.override_gate 前置断言兜底
  defp require_overridable(run) do
    if (run.facts || %{})["below_threshold_pending"] do
      :ok
    else
      {:error, "no below-threshold quality report pending override"}
    end
  end

  defp require_reason(reason) when is_binary(reason) do
    if String.trim(reason) == "" do
      {:error, "reason is required (override is audited)"}
    else
      {:ok, reason}
    end
  end

  defp require_reason(_reason), do: {:error, "reason is required (override is audited)"}

  defp fetch_run(course) do
    case Prep.fetch_run(course.id, course.workspace_id) do
      nil -> {:error, "no preparation run found for course #{course.id}"}
      run -> {:ok, run}
    end
  end
end
