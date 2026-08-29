defmodule Cgc2046.Mcp.Tools.RequestChangesPrep do
  @moduledoc """
  审核请求修改（role-agent-journeys-v2 S5，R23/R28，reviewer-per-policy
  或 Owner/Admin，直接写）。

  前置 prep_state == review；理由 `reason` 必填。流转 review → authoring，
  理由追加进 facts `change_requests`（requested_by/reason/at，逐次累积）。

  直接写依据：退回修改是流程内可逆迁移、无公开面副作用（状态回退由 tutor
  继续生产内容推进）。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.Prep
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:course_id, {:required, :string}, description: "课程 ID（UUID）")
    field(:reason, {:required, :string}, description: "修改要求（必填，落 facts 记录）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "request_changes_prep", fn actor, workspace_id, params ->
        course_id = params["course_id"] || params[:course_id]
        reason = params["reason"] || params[:reason]

        with {:ok, reason} <- require_reason(reason),
             {:ok, course} <- fetch_course(workspace_id, course_id),
             {:ok, run} <- fetch_run(course),
             :ok <- authorize(actor, workspace_id, run),
             {:ok, updated} <- Prep.request_changes(run, actor, reason) do
          {:ok,
           %{
             course_id: course.id,
             prep_state: Prep.prep_state(updated)
           }}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # 与 approve_prep 同一授权面（reviewer-per-policy 或 Owner/Admin，R28）
  defp authorize(actor, workspace_id, run) do
    if Prep.reviewer?(run, actor) or Prep.manage?(actor, workspace_id) do
      :ok
    else
      {:error, "forbidden: reviewer-per-policy, owner or admin required to request prep changes"}
    end
  end

  defp require_reason(reason) when is_binary(reason) do
    if String.trim(reason) == "" do
      {:error, "reason is required"}
    else
      {:ok, reason}
    end
  end

  defp require_reason(_reason), do: {:error, "reason is required"}

  defp fetch_course(workspace_id, course_id) do
    case Course
         |> Ash.Query.for_read(:get_by_id, %{id: course_id})
         |> Ash.read_one(authorize?: false, tenant: workspace_id) do
      {:ok, nil} -> {:error, "course not found: #{course_id}"}
      {:ok, course} -> {:ok, course}
      {:error, _} -> {:error, "failed to load course"}
    end
  end

  defp fetch_run(course) do
    case Prep.fetch_run(course.id, course.workspace_id) do
      nil -> {:error, "no preparation run found for course #{course.id}"}
      run -> {:ok, run}
    end
  end
end
