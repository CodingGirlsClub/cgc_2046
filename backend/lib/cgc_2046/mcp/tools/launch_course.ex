defmodule Cgc2046.Mcp.Tools.LaunchCourse do
  @moduledoc """
  发布课程：draft → open（role-agent-journeys-v2 S3，Owner/Admin 管理工具，
  确认流 two-tool 写，D-D3）。

  语义对齐 GraphQL launchCourse（同 `Courses.Course :launch` action）。发布即发
  `course.launched` 信号（SignalEmitter 事务内 outbox）。命名门（R21/AE1）：
  临时占位标题（provisional_title）课程不得发布——先经 update_course 设置正式
  标题；门在域 action 层（GraphQL/MCP 同语义），本工具第一段同款快速失败。

  第一次调用：不落业务库，建 PendingOperation，返回 needs_confirmation。
  非 draft / 未命名课程快速失败（不建 pending，approve_join_request 同款纪律）；
  并发竞态由 domain 的 DB 级 CAS 在 confirm 段兜底。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.{MembershipContext, Role}
  alias Cgc2046.Courses.Course
  alias Cgc2046.Mcp.{Confirmation, Wrapper}

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:course_id, {:required, :string}, description: "待发布课程 ID（UUID，须为 draft 且已命名）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "launch_course", fn actor, workspace_id, params ->
        course_id = params["course_id"] || params[:course_id]

        with :ok <- authorize(actor, workspace_id),
             {:ok, course} <- fetch_course(actor, workspace_id, course_id) do
          cond do
            course.status != :draft ->
              {:error, "cannot launch from status=#{course.status}（仅 draft 可发布）"}

            course.provisional_title ->
              {:error, "课程尚未命名，不能发布：请先经 update_course 设置正式课程标题（当前为系统生成的临时标题）"}

            true ->
              summary =
                "发布课程「#{course.title}」（#{course.id}）：draft → open。" <>
                  "发布后课程公开报名开启"

              Confirmation.request(
                frame.assigns[:current_user],
                "launch_course",
                params,
                summary
              )
          end
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  @doc """
  确认后真正执行（由 `Confirmation.execute/3` 直接分派调用）。
  params 为 pending 落库的 redact 后参数（本工具参数无敏感键，直接可用）。
  """
  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(actor, params) do
    workspace_id = params["workspace_id"]
    course_id = params["course_id"]

    with {:ok, course} <- fetch_course(actor, workspace_id, course_id) do
      case course
           |> Ash.Changeset.for_update(:launch, %{}, tenant: workspace_id)
           |> Ash.update(actor: actor, tenant: workspace_id) do
        {:ok, launched} ->
          {:ok,
           %{
             course_id: launched.id,
             title: launched.title,
             status: to_string(launched.status)
           }}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error,
           "forbidden: owner or admin required to launch course in workspace #{workspace_id}"}

        {:error, %Ash.Error.Invalid{} = err} ->
          {:error, Exception.message(err)}

        {:error, _} ->
          {:error, "failed to launch course"}
      end
    end
  end

  # Owner/Admin 专属（S3）：工具层管理角色判定，非管理角色成员快速拒绝
  defp authorize(actor, workspace_id) do
    if actor |> MembershipContext.role_names(workspace_id) |> Enum.any?(&Role.manage_role?/1) do
      :ok
    else
      {:error, "forbidden: owner or admin required to launch courses"}
    end
  end

  # tenant 收紧课程归属：他租户 course_id 与不存在同一「not found」，不泄露存在性
  defp fetch_course(actor, workspace_id, course_id) do
    case Course
         |> Ash.Query.for_read(:get_by_id, %{id: course_id})
         |> Ash.read_one(actor: actor, tenant: workspace_id) do
      {:ok, nil} ->
        {:error, "course not found: #{course_id}"}

      {:ok, course} ->
        {:ok, course}

      {:error, %Ash.Error.Forbidden{}} ->
        {:error, "forbidden: not allowed to read course #{course_id}"}

      {:error, _} ->
        {:error, "failed to load course"}
    end
  end
end
