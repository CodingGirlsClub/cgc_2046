defmodule Cgc2046.Mcp.Tools.CloseCourse do
  @moduledoc """
  结束课程：open → closed（role-agent-journeys-v2 S3，Owner/Admin 管理工具，
  确认流 two-tool 写，D-D3）。

  语义对齐 GraphQL closeCourse（同 `Courses.Course :close` action）：发
  `course.ended` 信号——E-9 #124 级联：订阅方 = 教研 run 回收 / 报名窗锁定。
  终态不可逆（D4 v1 语义）：closed 无恢复 action，恢复路径 = 新建课程。

  第一次调用：不落业务库，建 PendingOperation，返回 needs_confirmation。
  非 open 课程快速失败（不建 pending）；并发竞态由 domain 的 DB 级 CAS 在
  confirm 段兜底（cron 与手动竞态同款纪律）。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.{MembershipContext, Role}
  alias Cgc2046.Courses.Course
  alias Cgc2046.Mcp.{Confirmation, Wrapper}

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:course_id, {:required, :string}, description: "待结束课程 ID（UUID，须为 open）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "close_course", fn actor, workspace_id, params ->
        course_id = params["course_id"] || params[:course_id]

        with :ok <- authorize(actor, workspace_id),
             {:ok, course} <- fetch_course(actor, workspace_id, course_id) do
          if course.status != :open do
            {:error, "cannot close from status=#{course.status}（仅 open 可结束）"}
          else
            summary =
              "结束课程「#{course.title}」（#{course.id}）：open → closed。" <>
                "结束后报名窗锁定、教研 run 回收（course.ended 信号）；终态不可逆，恢复 = 新建课程"

            Confirmation.request(
              frame.assigns[:current_user],
              "close_course",
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
           |> Ash.Changeset.for_update(:close, %{}, tenant: workspace_id)
           |> Ash.update(actor: actor, tenant: workspace_id) do
        {:ok, closed} ->
          {:ok,
           %{
             course_id: closed.id,
             title: closed.title,
             status: to_string(closed.status)
           }}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error,
           "forbidden: owner or admin required to close course in workspace #{workspace_id}"}

        {:error, %Ash.Error.Invalid{} = err} ->
          {:error, Exception.message(err)}

        {:error, _} ->
          {:error, "failed to close course"}
      end
    end
  end

  # Owner/Admin 专属（S3）：工具层管理角色判定，非管理角色成员快速拒绝
  defp authorize(actor, workspace_id) do
    if actor |> MembershipContext.role_names(workspace_id) |> Enum.any?(&Role.manage_role?/1) do
      :ok
    else
      {:error, "forbidden: owner or admin required to close courses"}
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
