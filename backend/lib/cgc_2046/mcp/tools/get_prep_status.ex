defmodule Cgc2046.Mcp.Tools.GetPrepStatus do
  @moduledoc """
  读取课程教研流程状态（role-agent-journeys-v2 S5，R22-R28，读面）。

  任何工作台成员可读（默认 fail-closed member 门）。返回 prep_state /
  生效策略（override-first 合并后）/ 被指派的 tutor 摘要 / 最新质量报告 /
  实时计算的结构门禁违规清单 / run version（乐观锁版本，供并发对话）。

  S6 起 run 读取经 `Prep.ensure_active_run/2` 懒开新 run——发布后编辑自动有
  活动 run 驱动下一版本（次周期 assignee 沿用）。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.User
  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.Prep
  alias Cgc2046.Mcp.Wrapper

  require Ash.Query

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:course_id, {:required, :string}, description: "课程 ID（UUID）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "get_prep_status", fn actor, workspace_id, params ->
        course_id = params["course_id"] || params[:course_id]

        with {:ok, course} <- fetch_course(workspace_id, course_id),
             {:ok, run} <- fetch_run(course, actor) do
          gate = Prep.gate(course)
          assignee_id = Prep.assignee(run)

          {:ok,
           %{
             course_id: course.id,
             prep_state: Prep.prep_state(run),
             policy: Prep.policy(run),
             assignee_user_id: assignee_id,
             tutor: tutor_summary(assignee_id),
             latest_quality_report: (run.facts || %{})["latest_quality_report"],
             gate_violations: gate.violations,
             version: run.version
           }}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # tenant 收紧课程归属（他租户 course_id 与不存在同一「not found」）；
  # authorize?: false——成员门槛已由 Wrapper member-only 门保证
  defp fetch_course(workspace_id, course_id) do
    case Course
         |> Ash.Query.for_read(:get_by_id, %{id: course_id})
         |> Ash.read_one(authorize?: false, tenant: workspace_id) do
      {:ok, nil} -> {:error, "course not found: #{course_id}"}
      {:ok, course} -> {:ok, course}
      {:error, _} -> {:error, "failed to load course"}
    end
  end

  # S6：惰性 ensure_active_run——run 已终态（发布后次周期）时懒开新 run
  # （默认策略快照 + assignee 沿用，系统效应 authorize?: false）。
  defp fetch_run(course, actor) do
    Prep.ensure_active_run(course, actor: actor)
  end

  # tutor 摘要（内部读 authorize?: false——行可见性已由 member 门保证，
  # 摘要只是同权限范围内的展示字段，PendingApprovals enrich 同款纪律）
  defp tutor_summary(nil), do: nil

  defp tutor_summary(user_id) do
    case User |> Ash.Query.filter(id == ^user_id) |> Ash.read_one(authorize?: false) do
      {:ok, %User{} = user} -> %{user_id: user.id, display_name: user.display_name}
      _ -> %{user_id: user_id, display_name: nil}
    end
  end
end
