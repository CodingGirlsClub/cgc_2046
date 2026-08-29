defmodule Cgc2046.Mcp.Tools.AdminReassignWorkspaceOwner do
  @moduledoc """
  平台治理：重指派工作台 Owner（role-agent-journeys-v2 S2，确认流
  two-tool 写，D-D3；#114 pending-owner 语义的 MCP 面）。

  语义对齐 GraphQL `reassignWorkspaceOwner`（同 `Workspace :reassign_owner`
  action）：仅 pending-owner 期间可用（工作台尚无 Owner 入座）——原子地
  「撤销当前 active Owner 邀请 + 改指现有用户 / 发新邀请」，同一事务，
  治理留痕 owner_reassign。

  - `new_owner_user_id`：改指现有用户（已是成员则在既有 membership 上补
    Owner 角色，多角色并集）；
  - `new_owner_email`：发新 pending-owner 邀请（preauthorized [:owner]，
    7 天有效），明文 token 仅在 confirm 结果中一次性返回（不落库）。

  第一次调用：不落业务库，建 PendingOperation，返回 needs_confirmation。
  已有 Owner 的工作台第一段即快速失败（不建 pending）。

  授权 = Wrapper `:platform_admin` 门控族；confirm 段由 reassign_owner
  action 的 `forbid_unless(PlatformAdmin)` policy 兜底。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Accounts.{MembershipContext, Workspace}
  alias Cgc2046.Mcp.Confirmation
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")

    field(:new_owner_user_id, :string, description: "改指现有用户为 Owner（用户 ID；与 new_owner_email 二选一）")

    field(:new_owner_email, :string,
      description: "改发 pending-owner 邀请给新邮箱（与 new_owner_user_id 二选一）"
    )
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_reassign_workspace_owner", fn actor,
                                                                      _workspace_id,
                                                                      params ->
        workspace_id = params["workspace_id"] || params[:workspace_id]
        new_owner_user_id = params["new_owner_user_id"] || params[:new_owner_user_id]
        new_owner_email = params["new_owner_email"] || params[:new_owner_email]

        with :ok <- validate_designation(new_owner_user_id, new_owner_email),
             {:ok, workspace} <- fetch_workspace(actor, workspace_id),
             :ok <- check_pending_owner(workspace) do
          summary =
            "重指派工作台「#{workspace.name}」（#{workspace.id}）的 Owner：" <>
              "撤销当前 pending-owner 邀请，#{designation_summary(new_owner_user_id, new_owner_email)}"

          Confirmation.request(
            frame.assigns[:current_user],
            "admin_reassign_workspace_owner",
            params,
            summary
          )
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

    input =
      %{
        owner_user_id: params["new_owner_user_id"],
        owner_email: params["new_owner_email"]
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    with {:ok, workspace} <- fetch_workspace(actor, workspace_id) do
      case workspace
           |> Ash.Changeset.for_update(:reassign_owner, input)
           |> Ash.update(actor: actor) do
        {:ok, updated} ->
          {:ok,
           %{
             workspace_id: updated.id,
             slug: updated.slug,
             new_owner_user_id: params["new_owner_user_id"],
             new_owner_email: params["new_owner_email"],
             # 新 pending-owner 邀请明文 token 仅此处一次性返回（不落库）
             owner_invitation_token: updated.__metadata__[:owner_invitation_token]
           }}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error, "forbidden: platform admin required to reassign workspace owner"}

        {:error, %Ash.Error.Invalid{} = err} ->
          {:error, Exception.message(err)}

        {:error, _} ->
          {:error, "failed to reassign workspace owner"}
      end
    end
  end

  defp validate_designation(nil, nil),
    do: {:error, "invalid owner designation: new_owner_user_id 与 new_owner_email 必须提供其一"}

  defp validate_designation(user_id, email) when not is_nil(user_id) and not is_nil(email),
    do: {:error, "invalid owner designation: new_owner_user_id 与 new_owner_email 只能提供一个"}

  defp validate_designation(_user_id, _email), do: :ok

  # 工作台是全局资源（无 tenant）；read policy 放行 platform_admin 读全部
  defp fetch_workspace(actor, workspace_id) do
    case Ash.get(Workspace, workspace_id, actor: actor) do
      {:ok, nil} ->
        {:error, "workspace not found: #{workspace_id}"}

      {:ok, workspace} ->
        {:ok, workspace}

      {:error, %Ash.Error.Forbidden{}} ->
        {:error, "forbidden: not allowed to read workspace #{workspace_id}"}

      {:error, _} ->
        {:error, "failed to load workspace"}
    end
  end

  # pending-owner 快速失败：已有 Owner 的工作台不建 pending（与 domain 守卫同措辞）
  defp check_pending_owner(workspace) do
    if MembershipContext.has_owner?(workspace.id) do
      {:error, "工作台已有 Owner，重指派仅适用于 pending-owner 期间"}
    else
      :ok
    end
  end

  defp designation_summary(user_id, nil), do: "改指现有用户 #{user_id} 入座 Owner"
  defp designation_summary(nil, email), do: "发新 pending-owner 邀请至 #{email}（7 天有效）"
end
