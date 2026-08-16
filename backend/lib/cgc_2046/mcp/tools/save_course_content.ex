defmodule Cgc2046.Mcp.Tools.SaveCourseContent do
  @moduledoc """
  保存课程内容 issue 卡集(切片 H U3, #180;R1 写,教研侧唯一写入口)。

  - 写 ResearchOutput(kind=:issues, key=course_<id>)活文档(U1
    upsert_content;run 终态后仍可更新,Q8);
  - run 非终态时向教研 run `facts["issues"]` 浅合并镜像(KTD1)。

  授权(R6/KTD2):tutor ∪ owner/admin(membership roles 并集;owner/admin
    豁免语义同 StepAuthorization,成员角色 tutor 放行,learner/volunteer 拒)。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Accounts.Role
  alias Cgc2046.Mcp.Wrapper
  alias Cgc2046.Workflows.ResearchOutput

  @non_terminal_statuses [:pending, :running, :waiting]

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID(UUID)")
    field(:course_id, {:required, :string}, description: "课程 ID(UUID)")

    field(:content, {:required, :map},
      description: "course content:%{goals: [string], issues: [issue 卡]}(形状校验在资源层)"
    )
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "save_course_content", fn actor, workspace_id, params ->
        course_id = params["course_id"] || params[:course_id]
        content = params["content"] || params[:content]

        with :ok <- authorize(actor, workspace_id),
             {:ok, course} <- fetch_course(course_id),
             {:ok, output} <- save_output(actor, workspace_id, course, content) do
          mirror_to_run(course, content)
          {:ok, %{course_id: course_id, key: output.key, status: "saved"}}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # tutor ∪ owner/admin(R6):管理角色豁免 + tutor 显式放行;
  # learner/volunteer/无差异标签成员拒。
  defp authorize(actor, workspace_id) do
    roles = MembershipContext.role_names(actor, workspace_id)

    if Enum.any?(roles, &Role.manage_role?/1) or :tutor in roles do
      :ok
    else
      {:error, "forbidden: tutor, owner or admin required"}
    end
  end

  # 读取 authorize?: false(授权在工具层;ensure 只读 workflow_run_id/status)
  defp fetch_course(course_id) do
    case Cgc2046.Events.Course
         |> Ash.Query.for_read(:get_by_id, %{id: course_id})
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, "course not found: #{course_id}"}
      {:ok, course} -> {:ok, course}
      {:error, _} -> {:error, "failed to load course"}
    end
  end

  defp save_output(actor, workspace_id, course, content) do
    changeset =
      ResearchOutput
      |> Ash.Changeset.for_create(
        :upsert_content,
        %{
          key: ResearchOutput.course_key(course.id),
          kind: :issues,
          data: content,
          submitted_by: actor.id,
          workflow_run_id: course.workflow_run_id
        },
        tenant: workspace_id,
        actor: actor
      )

    case Ash.create(changeset, tenant: workspace_id, actor: actor) do
      {:ok, output} ->
        {:ok, output}

      {:error, %Ash.Error.Forbidden{}} ->
        {:error, "forbidden: not authorized to save course content"}

      {:error, %Ash.Error.Invalid{} = err} ->
        {:error, Exception.message(err)}

      {:error, _} ->
        {:error, "failed to save course content"}
    end
  end

  # KTD1:run 非终态时向 facts["issues"] 浅合并镜像(save_step_output 的浅合并
  # 语义);终态 run 不动(Q8:活文档经 ResearchOutput 本体更新,镜像只是教研
  # run 视角的方便投影)。镜像失败不阻塞写结果(审计可见性优于响应语义)。
  defp mirror_to_run(course, content) do
    case course.workflow_run_id do
      run_id when is_binary(run_id) ->
        mirror(run_id, course.workspace_id, content)

      nil ->
        :ok
    end
  end

  defp mirror(run_id, workspace_id, content) do
    case Cgc2046.Workflows.WorkflowRun
         |> Ash.Query.for_read(:get_by_id, %{id: run_id})
         |> Ash.read_one(authorize?: false, tenant: workspace_id) do
      {:ok, %Cgc2046.Workflows.WorkflowRun{status: status, facts: facts} = run}
      when status in @non_terminal_statuses ->
        new_facts = Map.merge(facts || %{}, %{"issues" => content})

        case run
             |> Ash.Changeset.for_update(:update_facts_for_mcp, %{facts: new_facts},
               tenant: workspace_id,
               authorize?: false
             )
             |> Ash.update(tenant: workspace_id, authorize?: false) do
          {:ok, _} -> :ok
          {:error, _} -> :ok
        end

      _ ->
        :ok
    end
  end
end
