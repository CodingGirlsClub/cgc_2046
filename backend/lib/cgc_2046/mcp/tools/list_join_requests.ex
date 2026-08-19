defmodule Cgc2046.Mcp.Tools.ListJoinRequests do
  @moduledoc """
  列出本工作台的加入申请（#240 成员管理读工具，Owner/Admin 专属）。

  数据面同 GraphQL fetchJoinRequests：默认 pending，可按 status 过滤
  （pending|approved|rejected|expired）。授权锚 = workspace：默认 fail-closed
  member 门之外，本工具层再做 Owner/Admin 判定（`Role.manage_role?/1`），
  非管理角色成员快速拒绝并落 ToolCallLog 审计。

  返回摘要：申请人（user_id）/申请时间（submitted_at）/状态/审批截止
  （approval_deadline）+ 顶层 `grantable_roles`（批准时可在 approve_join_request
  指定的预授角色提议 = Role.role_names() − 管理角色，对齐 web 审批面
  GRANTABLE_ROLE_NAMES 语义）。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.{JoinRequest, MembershipContext, Role}
  alias Cgc2046.Mcp.Wrapper

  @statuses ~w(pending approved rejected expired)

  require Ash.Query

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")

    field(:status, :string, description: "按状态过滤（pending|approved|rejected|expired，默认 pending）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "list_join_requests", fn actor, workspace_id, params ->
        status = params["status"] || params[:status] || "pending"

        with :ok <- authorize(actor, workspace_id),
             {:ok, status} <- parse_status(status) do
          # 白名单校验后才 to_existing_atom（不污染 atom 表）；
          # read（非 bang）+ 错误分类：Forbidden 等错误也落 ToolCallLog 审计
          status_atom = String.to_existing_atom(status)

          case JoinRequest
               |> Ash.Query.filter(status == ^status_atom)
               |> Ash.Query.sort(inserted_at: :desc)
               |> Ash.read(actor: actor, tenant: workspace_id) do
            {:ok, requests} ->
              {:ok,
               %{
                 workspace_id: workspace_id,
                 status: status,
                 count: length(requests),
                 grantable_roles: grantable_role_names(),
                 join_requests:
                   Enum.map(requests, fn jr ->
                     %{
                       join_request_id: jr.id,
                       applicant_user_id: jr.user_id,
                       status: to_string(jr.status),
                       message: jr.message,
                       submitted_at: jr.inserted_at,
                       approval_deadline: jr.approval_deadline
                     }
                   end)
               }}

            {:error, %Ash.Error.Forbidden{}} ->
              {:error,
               "forbidden: not allowed to list join requests of workspace #{workspace_id}"}

            {:error, _} ->
              {:error, "failed to list join requests"}
          end
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # Owner/Admin 专属（#240）：工具层管理角色判定，非管理角色成员快速拒绝
  defp authorize(actor, workspace_id) do
    if actor |> MembershipContext.role_names(workspace_id) |> Enum.any?(&Role.manage_role?/1) do
      :ok
    else
      {:error, "forbidden: owner or admin required to list join requests"}
    end
  end

  defp parse_status(status) when status in @statuses, do: {:ok, status}

  defp parse_status(_status),
    do: {:error, "invalid status (expected one of #{Enum.join(@statuses, "|")})"}

  # 预授角色提议（对齐 web 审批面 GRANTABLE_ROLE_NAMES = ROLE_NAMES − 管理角色）
  defp grantable_role_names,
    do: Role.role_names() |> Enum.reject(&Role.manage_role?/1) |> Enum.map(&to_string/1)
end
