defmodule Cgc2046.Mcp.Tools.GetCourseLearningAnalytics do
  @moduledoc """
  课程学习分析读工具(role-agent-journeys-v2 S10,R49/R50;AE14)。

  返回 `Cgc2046.Learning.Analytics.for_course/2` 聚合:run 级完成统计 +
  当前 published revision 逐 objective 掌握分布/重试与低置信度计数/
  avg_attempts_to_first_mastery/last_activity_at + orphan_objectives
  汇总 + drop_off.stale_run_count(Runs 停滞口径同源)。

  授权:tutor ∪ owner/admin——member-only 门(无豁免 meta,workspace_id
  必填)之外,工具层按 membership roles 并集判定(同 save_course_content
  R6 口径),plain member/learner 快速拒绝;每次调用(含拒绝)落
  ToolCallLog 审计。课程经 tenant 收紧归属——他租户 course_id 与不存在
  同一「not found」。

  **红线(R49):响应为纯聚合计数,永不含 evidence / rubric_results /
  rationale 正文**——分析面不读聊天/证据内容(服务端本无聊天;证据归
  LearningAttempt 账本,Owner 结果面 = list_course_enrollments +
  list_workspace_orders + 本工具 run_stats,不另建)。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.{MembershipContext, Role}
  alias Cgc2046.Courses.Course
  alias Cgc2046.Learning.Analytics
  alias Cgc2046.Mcp.Tools.Response
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID(UUID)")
    field(:course_id, {:required, :string}, description: "课程 ID(UUID)")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "get_course_learning_analytics", fn actor,
                                                                     workspace_id,
                                                                     params ->
        course_id = params["course_id"] || params[:course_id]

        with :ok <- authorize(actor, workspace_id),
             {:ok, course} <- fetch_course(workspace_id, course_id) do
          {:ok, Analytics.for_course(course)}
        end
      end)

    Response.to_response(result, frame)
  end

  # tutor ∪ owner/admin(R49):管理角色豁免 + tutor 显式放行;
  # learner/volunteer/无差异标签成员拒(同 save_course_content 口径)
  defp authorize(actor, workspace_id) do
    roles = MembershipContext.role_names(actor, workspace_id)

    if Enum.any?(roles, &Role.manage_role?/1) or :tutor in roles do
      :ok
    else
      {:error, "forbidden: tutor, owner or admin required to read course learning analytics"}
    end
  end

  # tenant 收紧课程归属:他租户 course_id 与不存在同一「not found」,不泄露存在性
  defp fetch_course(workspace_id, course_id) do
    case Course
         |> Ash.Query.for_read(:get_by_id, %{id: course_id})
         |> Ash.read_one(authorize?: false, tenant: workspace_id) do
      {:ok, nil} -> {:error, "course not found: #{course_id}"}
      {:ok, course} -> {:ok, course}
      {:error, _} -> {:error, "failed to load course"}
    end
  end
end
