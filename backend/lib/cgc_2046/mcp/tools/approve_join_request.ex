defmodule Cgc2046.Mcp.Tools.ApproveJoinRequest do
  @moduledoc """
  审批通过加入申请（#240 成员管理确认流 two-tool 写，D-D3）。

  第一次调用：不落业务库，建 PendingOperation，返回 needs_confirmation。
  用户确认后 agent 调 `confirm_operation(pending_id)` → `execute_confirmed/2`
  真正执行 `JoinRequest.approve`（审批方指定 role_names，与 web 审批面语义
  一致：批准时仅可授予非管理角色，owner 走 assign_roles 专门指派）。

  Owner/Admin 专属：默认 fail-closed member 门 + 工具层管理角色判定
  （第一段快速拒绝省 pending）；confirm 段由业务 action 的
  `WorkspaceActorIsOwnerOrAdmin` policy 兜底（审批人角色可能在确认窗口内被撤）。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.{JoinRequest, MembershipContext, Role}
  alias Cgc2046.Mcp.Confirmation
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:join_request_id, {:required, :string}, description: "待批准的加入申请 ID（UUID）")

    field(:role_names, {:array, :string},
      description: "批准时授予的角色（可多个，仅 tutor|volunteer|learner；缺省 [] = 无标签入座，Owner 可事后 assign_roles）"
    )
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "approve_join_request", fn actor, workspace_id, params ->
        join_request_id = params["join_request_id"] || params[:join_request_id]
        role_names = params["role_names"] || params[:role_names] || []

        with :ok <- authorize(actor, workspace_id),
             {:ok, role_names} <- parse_grantable_roles(role_names),
             {:ok, join_request} <- fetch_join_request(actor, workspace_id, join_request_id) do
          # 非终态快速失败：已处理申请不值得建 pending（终态/过期的并发拦截仍由
          # approve 的原子 claim 在 confirm 段兜底）
          if join_request.status != :pending do
            {:error, "该申请已被处理（当前状态：#{join_request.status}），无需再批准"}
          else
            summary =
              "批准 workspace #{workspace_id} 的加入申请 #{join_request.id}" <>
                "（申请人 #{join_request.user_id}），入座角色：#{role_summary(role_names)}"

            Confirmation.request(
              frame.assigns[:current_user],
              "approve_join_request",
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
    join_request_id = params["join_request_id"]

    with {:ok, role_names} <- parse_grantable_roles(params["role_names"] || []),
         {:ok, join_request} <- fetch_join_request(actor, workspace_id, join_request_id) do
      case join_request
           |> Ash.Changeset.for_update(:approve, %{role_names: role_names})
           |> Ash.update(actor: actor, tenant: workspace_id) do
        {:ok, approved} ->
          {:ok,
           %{
             join_request_id: approved.id,
             status: to_string(approved.status),
             approved_user_id: approved.user_id,
             granted_roles: Enum.map(role_names, &to_string/1)
           }}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error,
           "forbidden: owner or admin required to approve join requests in workspace #{workspace_id}"}

        {:error, %Ash.Error.Invalid{} = err} ->
          {:error, Exception.message(err)}

        {:error, _} ->
          {:error, "failed to approve join request"}
      end
    end
  end

  # Owner/Admin 专属（#240）：工具层管理角色判定，非管理角色成员快速拒绝
  defp authorize(actor, workspace_id) do
    if actor |> MembershipContext.role_names(workspace_id) |> Enum.any?(&Role.manage_role?/1) do
      :ok
    else
      {:error, "forbidden: owner or admin required to approve join requests"}
    end
  end

  # 批准时可授予的角色 = Role.role_names() − 管理角色（web 审批面 GRANTABLE 语义：
  # owner/admin 不可经审批授予，Owner 走 assign_roles 专门指派）。白名单校验后才
  # String.to_existing_atom（不污染 atom 表）
  defp parse_grantable_roles(role_names) do
    grantable = grantable_role_names()
    invalid = Enum.reject(role_names, &(&1 in grantable))

    if invalid == [] do
      {:ok, Enum.map(role_names, &String.to_existing_atom/1)}
    else
      {:error,
       "invalid roles #{inspect(invalid)}; grantable at approval: #{Enum.join(grantable, "|")}"}
    end
  end

  defp grantable_role_names,
    do: Role.role_names() |> Enum.reject(&Role.manage_role?/1) |> Enum.map(&to_string/1)

  defp fetch_join_request(actor, workspace_id, join_request_id) do
    case Ash.get(JoinRequest, join_request_id, actor: actor, tenant: workspace_id) do
      {:ok, nil} ->
        {:error, "join request not found"}

      {:ok, join_request} ->
        {:ok, join_request}

      {:error, %Ash.Error.Forbidden{}} ->
        {:error, "forbidden: not allowed to read join requests of workspace #{workspace_id}"}

      {:error, _} ->
        {:error, "failed to load join request"}
    end
  end

  defp role_summary([]), do: "无（默认入座，Owner 可事后 assign_roles）"
  defp role_summary(role_names), do: Enum.join(role_names, "|")
end
