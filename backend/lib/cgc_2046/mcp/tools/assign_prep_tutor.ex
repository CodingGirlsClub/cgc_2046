defmodule Cgc2046.Mcp.Tools.AssignPrepTutor do
  @moduledoc """
  指派课程教研 tutor（role-agent-journeys-v2 S5，R24，Owner/Admin 专属，
  直接写）。

  写 facts assignee；prep_state draft → authoring（非 draft 保持现态——审核中
  指派/再指派不打断流程）。目标用户必须在目标工作台持有 tutor 角色。
  可再指派（reassign，R24 Owner/Admin 审计与再指派权）。

  直接写依据：指派可逆、无资金/公开面副作用（create_course 同款 R12 纪律）。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.Prep
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:course_id, {:required, :string}, description: "课程 ID（UUID）")

    field(:tutor_user_id, {:required, :string},
      description: "被指派的 tutor 用户 ID（须在本工作台持有 tutor 角色）"
    )
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "assign_prep_tutor", fn actor, workspace_id, params ->
        course_id = params["course_id"] || params[:course_id]
        tutor_user_id = params["tutor_user_id"] || params[:tutor_user_id]

        with :ok <- authorize(actor, workspace_id),
             {:ok, course} <- fetch_course(workspace_id, course_id),
             {:ok, run} <- fetch_run(course),
             :ok <- require_tutor_role(tutor_user_id, workspace_id),
             {:ok, updated} <- Prep.assign_tutor(run, tutor_user_id, actor) do
          {:ok,
           %{
             course_id: course.id,
             prep_state: Prep.prep_state(updated),
             assignee_user_id: Prep.assignee(updated)
           }}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  defp authorize(actor, workspace_id) do
    if Prep.manage?(actor, workspace_id) do
      :ok
    else
      {:error, "forbidden: owner or admin required to assign prep tutor"}
    end
  end

  defp require_tutor_role(tutor_user_id, workspace_id) do
    if :tutor in MembershipContext.role_names(%{id: tutor_user_id}, workspace_id) do
      :ok
    else
      {:error,
       "tutor_user_id #{tutor_user_id} does not hold tutor role in workspace #{workspace_id}"}
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
