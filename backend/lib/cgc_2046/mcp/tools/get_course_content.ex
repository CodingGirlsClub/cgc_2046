defmodule Cgc2046.Mcp.Tools.GetCourseContent do
  @moduledoc """
  读取课程内容 issue 卡集(切片 H U3, #180;R4 读)。

  数据源 = ResearchOutput(kind=:issues, key=course_<id>);无内容返回
  course 无教研产出的明确错误(agent 侧可提示等待教研)。

  授权(KTD2):workspace 成员(tutor/教研编辑)∪ 本人 confirmed enrollment
  ∪ 本人已有记忆(记忆持有者)。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Mcp.Tools.LearnerAuthorization
  alias Cgc2046.Mcp.Wrapper
  alias Cgc2046.Workflows.ResearchOutput
  require Ash.Query

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID(UUID)")
    field(:course_id, {:required, :string}, description: "课程 ID(UUID)")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "get_course_content", fn actor, workspace_id, params ->
        course_id = params["course_id"] || params[:course_id]

        with :ok <- LearnerAuthorization.authorize(actor, workspace_id, course_id),
             {:ok, content} <- fetch_content(workspace_id, course_id) do
          {:ok,
           %{
             course_id: course_id,
             goals: content["goals"] || [],
             issues: content["issues"] || []
           }}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # 读取带 actor:资源层 read policy(成员/平台管理员)放行成员;学员(非成员)
  # 由工具层授权后经 authorize?: false 读取——读门禁在工具层已真实发生
  # (save_step_output fetch_run 同款纪律)。
  defp fetch_content(workspace_id, course_id) do
    ResearchOutput
    |> Ash.Query.filter(key == ^ResearchOutput.course_key(course_id) and kind == :issues)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false, tenant: workspace_id)
    |> case do
      {:ok, nil} ->
        {:error, "no course content saved for course #{course_id} (research pending)"}

      {:ok, output} ->
        {:ok, output.data || %{}}

      {:error, _} ->
        {:error, "failed to load course content"}
    end
  end
end
