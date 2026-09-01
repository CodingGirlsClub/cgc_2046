defmodule Cgc2046.Mcp.Tools.CreateInvitation do
  @moduledoc """
  创建邀请（D7 管理类高风险 → 确认流 two-tool，D-D3）。

  第一次调用：不落库，建 PendingOperation，返回 needs_confirmation。
  用户确认后 agent 调 `confirm_operation(pending_id)` → `execute_confirmed/2` 真正创建
  Invitation（复用 Accounts.Invitation :create，RBAC policy 兜底）。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Mcp.Confirmation
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:target_email, :string, description: "目标邮箱（空 = 公开链接）")
    field(:expires_in_hours, :integer, description: "有效期（小时，可选）")

    field(:preauthorized_role_names, {:list, :string},
      description:
        "预授权角色（可多个，仅 tutor|volunteer|learner；接受邀请时自动授予；缺省 [] = 无角色入座，Owner 可事后 assign_roles）"
    )
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "create_invitation", fn _actor, workspace_id, params ->
        target = params["target_email"] || params[:target_email]

        roles = params["preauthorized_role_names"] || params[:preauthorized_role_names] || []

        roles_str =
          if is_list(roles) and roles != [], do: "（预授权角色: #{Enum.join(roles, ", ")}）", else: ""

        summary =
          if target do
            "在 workspace #{workspace_id} 创建指向 #{target} 的邀请#{roles_str}"
          else
            "在 workspace #{workspace_id} 创建公开邀请链接#{roles_str}"
          end

        Confirmation.request(frame.assigns[:current_user], "create_invitation", params, summary)
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
    expires_at = expires_at_from(params["expires_in_hours"])

    preauthorized = parse_preauthorized_roles(params["preauthorized_role_names"])

    input =
      %{
        workspace_id: workspace_id,
        inviter_id: actor.id,
        target_email: params["target_email"],
        expires_at: expires_at,
        preauthorized_role_names: preauthorized
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Cgc2046.Accounts.Invitation
         |> Ash.Changeset.for_create(:create, input, actor: actor)
         |> Ash.create() do
      {:ok, invitation} ->
        {:ok,
         %{
           invitation_id: invitation.id,
           status: to_string(invitation.status),
           # 明文邀请 token 仅此处一次性返回（不落库）；客户端应展示给用户后丢弃
           invitation_token: invitation.__metadata__[:plain_token]
         }}

      {:error, %Ash.Error.Forbidden{}} ->
        {:error, "forbidden: not allowed to create invitation in workspace #{workspace_id}"}

      {:error, %Ash.Error.Invalid{} = err} ->
        {:error, Exception.message(err)}

      {:error, _} ->
        {:error, "failed to create invitation"}
    end
  end

  @valid_preauth_roles ~w(tutor volunteer learner)a

  defp parse_preauthorized_roles(nil), do: nil

  defp parse_preauthorized_roles(roles) when is_list(roles) do
    Enum.map(roles, fn role ->
      atom = String.to_existing_atom(to_string(role))

      if atom in @valid_preauth_roles,
        do: atom,
        else: raise(ArgumentError, "invalid role: #{role}")
    end)
  rescue
    ArgumentError -> {:error, "invalid preauthorized role: #{inspect(roles)}"}
  end

  defp parse_preauthorized_roles(_), do: nil

  defp expires_at_from(nil), do: nil

  defp expires_at_from(hours) when is_integer(hours) and hours > 0 do
    DateTime.add(DateTime.utc_now(), hours * 3600, :second)
  end

  defp expires_at_from(_), do: nil
end
