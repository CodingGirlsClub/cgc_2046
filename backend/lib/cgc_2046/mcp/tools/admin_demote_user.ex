defmodule Cgc2046.Mcp.Tools.AdminDemoteUser do
  @moduledoc """
  平台治理：降级平台管理员（role-agent-journeys-v2 S2，确认流
  two-tool 写，D-D3；R12–R16 demote 的 MCP 面）。

  第一次调用：不落业务库，建 PendingOperation，返回 needs_confirmation。
  用户确认后 agent 调 `confirm_operation(pending_id)` → `execute_confirmed/2`
  真正执行 `User :demote_platform_admin`（≥1 admin 不变量唯一入口：原子
  条件 UPDATE 判定，降级最后一名管理员被拒绝——`last_admin_denied` 错误
  原文透传；治理留痕 admin_demote 同事务落库）。

  授权 = Wrapper `:platform_admin` 门控族（第一段快速拒绝省 pending）；
  confirm 段由 action 的 `Policies.PlatformAdmin` policy 兜底（管理员标记
  可能在确认窗口内被撤）。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Accounts.User
  alias Cgc2046.Mcp.Confirmation
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:user_id, {:required, :string},
      description: "待降级的平台管理员用户 ID（UUID，可从 admin_list_users 获取）"
    )
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_demote_user", fn actor, _workspace_id, params ->
        user_id = params["user_id"] || params[:user_id]

        with {:ok, user} <- fetch_user(actor, user_id) do
          # 非管理员快速失败（domain 的 not_platform_admin 在 confirm 段兜底）
          if user.is_platform_admin do
            summary =
              "将用户 #{user.email && to_string(user.email)}（#{user.id}）从平台管理员降级" <>
                "（回收全局跨租户治理权限；系统必须维持 ≥1 名平台管理员，最后一名不可降级）"

            Confirmation.request(
              frame.assigns[:current_user],
              "admin_demote_user",
              params,
              summary
            )
          else
            {:error, "该用户不是平台管理员，无需降级"}
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
           |> Ash.Changeset.for_update(:demote_platform_admin, %{})
           |> Ash.update(actor: actor) do
        {:ok, demoted} ->
          {:ok,
           %{
             user_id: demoted.id,
             email: demoted.email && to_string(demoted.email),
             is_platform_admin: demoted.is_platform_admin
           }}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error, "forbidden: platform admin required to demote users"}

        # ≥1 admin 不变量 / 目标非 admin 的领域错误（PlatformAdminError）原文透传
        {:error, %Ash.Error.Invalid{} = err} ->
          {:error, Exception.message(err)}

        {:error, _} ->
          {:error, "failed to demote user"}
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
