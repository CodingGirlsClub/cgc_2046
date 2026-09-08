defmodule Cgc2046.Mcp.Tools.CancelEvent do
  @moduledoc """
  取消活动：open → cancelled（role-agent-journeys-v2 S3，Owner/Admin 管理工具，
  确认流 two-tool 写，D-D3）。

  语义对齐 GraphQL cancelEvent（同 `Events.Event :cancel` action）：同样发
  `event.ended`（D4：closed/cancelled 即 ended）——报名窗锁定 / 教研 run
  回收 / 赞助 Event 级自动 ended。终态不可逆（D4 v1 语义）：cancelled 无
  恢复 action，恢复路径 = 新建活动。

  第一次调用：不落业务库，建 PendingOperation，返回 needs_confirmation。
  非 open 活动快速失败（不建 pending）；并发竞态由 domain 的 DB 级 CAS 在
  confirm 段兜底。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.{MembershipContext, Role}
  alias Cgc2046.Events.Event
  alias Cgc2046.Mcp.{Confirmation, Wrapper}

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:event_id, {:required, :string}, description: "待取消活动 ID（UUID，须为 open）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "cancel_event", fn actor, workspace_id, params ->
        event_id = params["event_id"] || params[:event_id]

        with :ok <- authorize(actor, workspace_id),
             {:ok, event} <- fetch_event(actor, workspace_id, event_id) do
          if event.status != :open do
            {:error, "cannot cancel from status=#{event.status}（仅 open 可取消）"}
          else
            summary =
              "取消活动「#{event.title}」（#{event.id}）：open → cancelled。" <>
                "取消后报名窗锁定、赞助入口关闭（event.ended 信号）；终态不可逆，恢复 = 新建活动"

            Confirmation.request(
              frame.assigns[:current_user],
              "cancel_event",
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
    event_id = params["event_id"]

    with {:ok, event} <- fetch_event(actor, workspace_id, event_id) do
      case event
           |> Ash.Changeset.for_update(:cancel, %{}, tenant: workspace_id)
           |> Ash.update(actor: actor, tenant: workspace_id) do
        {:ok, cancelled} ->
          {:ok,
           %{
             event_id: cancelled.id,
             title: cancelled.title,
             status: to_string(cancelled.status)
           }}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error,
           "forbidden: owner or admin required to cancel event in workspace #{workspace_id}"}

        {:error, %Ash.Error.Invalid{} = err} ->
          {:error, Exception.message(err)}

        {:error, _} ->
          {:error, "failed to cancel event"}
      end
    end
  end

  # Owner/Admin 专属（S3）：工具层管理角色判定，非管理角色成员快速拒绝
  defp authorize(actor, workspace_id) do
    if actor |> MembershipContext.role_names(workspace_id) |> Enum.any?(&Role.manage_role?/1) do
      :ok
    else
      {:error, "forbidden: owner or admin required to cancel events"}
    end
  end

  # tenant 收紧活动归属：他租户 event_id 与不存在同一「not found」，不泄露存在性
  defp fetch_event(actor, workspace_id, event_id) do
    case Event
         |> Ash.Query.for_read(:get_by_id, %{id: event_id})
         |> Ash.read_one(actor: actor, tenant: workspace_id) do
      {:ok, nil} ->
        {:error, "event not found: #{event_id}"}

      {:ok, event} ->
        {:ok, event}

      {:error, %Ash.Error.Forbidden{}} ->
        {:error, "forbidden: not allowed to read event #{event_id}"}

      {:error, _} ->
        {:error, "failed to load event"}
    end
  end
end
