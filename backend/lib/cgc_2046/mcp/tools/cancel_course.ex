defmodule Cgc2046.Mcp.Tools.CancelCourse do
  @moduledoc """
  取消课程：open → cancelled（role-agent-journeys-v2 S3，Owner/Admin 管理工具，
  确认流 two-tool 写，D-D3）。

  语义对齐 GraphQL cancelCourse（同 `Courses.Course :cancel` action）：同样发
  `course.ended`（D4：closed/cancelled 即 ended）——报名窗锁定 / 教研 run 回收。
  终态不可逆（D4 v1 语义）：cancelled 无恢复 action，恢复路径 = 新建课程。

  第一次调用：不落业务库，建 PendingOperation，返回 needs_confirmation。
  非 open 课程快速失败（不建 pending）；并发竞态由 domain 的 DB 级 CAS 在
  confirm 段兜底。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.Rbac
  alias Cgc2046.Courses.Course
  alias Cgc2046.Mcp.{Confirmation, Wrapper}

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:course_id, {:required, :string}, description: "待取消课程 ID（UUID，须为 open）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "cancel_course", fn actor, workspace_id, params ->
        course_id = params["course_id"] || params[:course_id]

        with :ok <- authorize(actor, workspace_id),
             {:ok, course} <- Course.fetch_scoped(workspace_id, course_id, actor: actor) do
          if course.status != :open do
            {:error, "cannot cancel from status=#{course.status}（仅 open 可取消）"}
          else
            summary =
              "取消课程「#{course.title}」（#{course.id}）：open → cancelled。" <>
                "取消后报名窗锁定、教研 run 回收（course.ended 信号）；终态不可逆，恢复 = 新建课程"

            Confirmation.request(
              frame.assigns[:current_user],
              "cancel_course",
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

    with {:ok, course} <- Course.fetch_scoped(workspace_id, course_id, actor: actor) do
      case course
           |> Ash.Changeset.for_update(:cancel, %{}, tenant: workspace_id)
           |> Ash.update(actor: actor, tenant: workspace_id) do
        {:ok, cancelled} ->
          {:ok,
           %{
             course_id: cancelled.id,
             title: cancelled.title,
             status: to_string(cancelled.status)
           }}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error,
           "forbidden: owner or admin required to cancel course in workspace #{workspace_id}"}

        {:error, %Ash.Error.Invalid{} = err} ->
          {:error, Exception.message(err)}

        {:error, _} ->
          {:error, "failed to cancel course"}
      end
    end
  end

  # Owner/Admin 专属（S3）：工具层管理角色判定，非管理角色成员快速拒绝
  defp authorize(actor, workspace_id) do
    if Rbac.manage?(actor, workspace_id) do
      :ok
    else
      {:error, "forbidden: owner or admin required to cancel courses"}
    end
  end
end
