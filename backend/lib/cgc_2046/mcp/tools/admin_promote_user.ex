defmodule Cgc2046.Mcp.Tools.AdminPromoteUser do
  @moduledoc """
  平台治理：提升用户为平台管理员（role-agent-journeys-v2 S2，确认流
  two-tool 写，D-D3；R12–R16 promote 的 MCP 面）。

  第一次调用：不落业务库，建 PendingOperation，返回 needs_confirmation。
  用户确认后 agent 调 `confirm_operation(pending_id)` → `execute_confirmed/2`
  真正执行 `User :set_platform_admin`（platform_admin 专属 action；
  治理留痕 admin_promote 同事务落库）。

  授权 = Wrapper `:platform_admin` 门控族（第一段快速拒绝省 pending）；
  confirm 段由 action 的 `Policies.PlatformAdmin` policy 兜底。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Accounts.User
  alias Cgc2046.Mcp.Confirmation
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:user_id, {:required, :string}, description: "待提升的用户 ID（UUID，可从 admin_list_users 获取）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_promote_user", fn actor, _workspace_id, params ->
        user_id = params["user_id"] || params[:user_id]

        with {:ok, user} <- fetch_user(actor, user_id) do
          # 幂等快速失败：已是管理员的用户不值得建 pending
          if user.is_platform_admin do
            {:error, "该用户已是平台管理员，无需提升"}
          else
            summary =
              "将用户 #{user.email && to_string(user.email)}（#{user.id}）提升为平台管理员" <>
                "（全局跨租户治理权限，含工作台创建/申请审批/管理员任免/审计读取）"

            Confirmation.request(
              frame.assigns[:current_user],
              "admin_promote_user",
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
    with {:ok, user} <- fetch_user(actor, params["user_id"]) do
      case user
           |> Ash.Changeset.for_update(:set_platform_admin, %{is_platform_admin: true})
           |> Ash.update(actor: actor) do
        {:ok, promoted} ->
          {:ok,
           %{
             user_id: promoted.id,
             email: promoted.email && to_string(promoted.email),
             is_platform_admin: promoted.is_platform_admin
           }}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error, "forbidden: platform admin required to promote users"}

        {:error, %Ash.Error.Invalid{} = err} ->
          {:error, Exception.message(err)}

        {:error, _} ->
          {:error, "failed to promote user"}
      end
    end
  end

  defp fetch_user(actor, user_id) do
    case Ash.get(User, user_id, actor: actor) do
      {:ok, nil} ->
        {:error, "user not found: #{user_id}"}

      {:ok, user} ->
        {:ok, user}

      {:error, %Ash.Error.Forbidden{}} ->
        {:error, "forbidden: not allowed to read user #{user_id}"}

      {:error, _} ->
        {:error, "failed to load user"}
    end
  end
end
