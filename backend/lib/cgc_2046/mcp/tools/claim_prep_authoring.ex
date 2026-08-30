defmodule Cgc2046.Mcp.Tools.ClaimPrepAuthoring do
  @moduledoc """
  认领课程教研 authoring（role-agent-journeys-v2 S5，R24，直接写）。

  未指派（draft/authoring 且 facts 无 assignee）的教研任务由工作台 tutor 原子
  认领（Owner/Admin 亦可认领）；认领 = `Curriculum.Prep.claim/3` 的 run version
  乐观锁 CAS，并发双认领恰一成一败，落败方收到 already claimed 业务错误。
  认领成功 prep_state draft → authoring。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.Prep
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:course_id, {:required, :string}, description: "课程 ID（UUID）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "claim_prep_authoring", fn actor, workspace_id, params ->
        course_id = params["course_id"] || params[:course_id]

        with :ok <- authorize(actor, workspace_id),
             {:ok, course} <- fetch_course(workspace_id, course_id),
             {:ok, run} <- fetch_run(course),
             {:ok, claimed} <- Prep.claim(run, actor.id, actor) do
          {:ok,
           %{
             course_id: course.id,
             prep_state: Prep.prep_state(claimed),
             assignee_user_id: Prep.assignee(claimed)
           }}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # tutor 角色或 Owner/Admin（R24）
  defp authorize(actor, workspace_id) do
    if Prep.tutor?(actor, workspace_id) or Prep.manage?(actor, workspace_id) do
      :ok
    else
      {:error, "forbidden: tutor, owner or admin required to claim prep authoring"}
    end
  end

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
