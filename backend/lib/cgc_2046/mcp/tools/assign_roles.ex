defmodule Cgc2046.Mcp.Tools.AssignRoles do
  @moduledoc """
  替换某成员的整组角色（#240 成员管理确认流 two-tool 写，D-D3）。

  语义对齐 GraphQL assign_roles mutation：多角色并集、整体替换
  （role_names 为替换后的完整集合，空数组 = 清空全部差异标签）。

  第一次调用：不落库，建 PendingOperation，返回 needs_confirmation；
  confirm 后 `execute_confirmed/2` 执行 `WorkspaceMembership.assign_roles`
  （owner 移除/授予守卫 `Rbac.validate_owner_removal!` 在业务 change 的
  before_action 生效：仅 Owner 可授予/撤销 owner + 最后 Owner 保护）。

  Owner/Admin 专属：默认 fail-closed member 门 + 工具层管理角色判定
  （第一段快速拒绝省 pending）；confirm 段由业务 update policy 兜底
  （调用者角色可能在确认窗口内被撤）。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.{MembershipContext, Role, WorkspaceMembership}
  alias Cgc2046.Mcp.Confirmation
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")

    field(:membership_id, {:required, :string},
      description: "目标成员的 WorkspaceMembership ID（UUID，可从 list_members 获取）"
    )

    field(:role_names, {:required, {:list, :string}},
      description:
        "替换后的完整角色集（owner|admin|tutor|volunteer|learner；空数组 = 清空全部角色；仅 Owner 可授予/撤销 owner）"
    )
  end

  require Ash.Query

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "assign_roles", fn actor, workspace_id, params ->
        membership_id = params["membership_id"] || params[:membership_id]
        role_names = params["role_names"] || params[:role_names] || []

        with :ok <- authorize(actor, workspace_id),
             {:ok, role_names} <- parse_role_names(role_names),
             {:ok, membership} <- fetch_membership(actor, workspace_id, membership_id) do
          current =
            membership.roles |> Enum.map(&to_string(&1.name)) |> Enum.sort()

          summary =
            "将 workspace #{workspace_id} 成员 #{membership.user_id}（membership #{membership.id}）" <>
              "的整组角色替换：#{inspect(current)} → #{inspect(Enum.sort(role_names))}"

          Confirmation.request(frame.assigns[:current_user], "assign_roles", params, summary)
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
    membership_id = params["membership_id"]

    with {:ok, role_names} <- parse_role_names(params["role_names"] || []),
         {:ok, membership} <- fetch_membership(actor, workspace_id, membership_id) do
      case membership
           |> Ash.Changeset.for_update(:assign_roles, %{role_names: role_names})
           |> Ash.update(actor: actor, tenant: workspace_id) do
        # after_action 已按 role_names 整组替换 MembershipRole，成功即终态，
        # 回显请求集合（避免二次 load 的失败分支）
        {:ok, updated} ->
          {:ok,
           %{
             membership_id: updated.id,
             user_id: updated.user_id,
             roles: role_names |> Enum.map(&to_string/1) |> Enum.sort()
           }}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error,
           "forbidden: owner or admin required to assign roles in workspace #{workspace_id}"}

        {:error, %Ash.Error.Invalid{} = err} ->
          {:error, Exception.message(err)}

        {:error, _} ->
          {:error, "failed to assign roles"}
      end
    end
  end

  # Owner/Admin 专属（#240）：工具层管理角色判定，非管理角色成员快速拒绝
  defp authorize(actor, workspace_id) do
    if actor |> MembershipContext.role_names(workspace_id) |> Enum.any?(&Role.manage_role?/1) do
      :ok
    else
      {:error, "forbidden: owner or admin required to assign roles"}
    end
  end

  # assign_roles 是全角色面（含 owner/admin——Owner 专门指派路径）；白名单校验后
  # 才 String.to_existing_atom（不污染 atom 表）。grant-scope 守卫（仅 Owner 可碰
  # owner + 最后 Owner 保护）由业务 change 承担
  defp parse_role_names(role_names) do
    valid = Role.role_names() |> Enum.map(&to_string/1)
    invalid = Enum.reject(role_names, &(&1 in valid))

    if invalid == [] do
      {:ok, Enum.map(role_names, &String.to_existing_atom/1)}
    else
      {:error, "invalid roles #{inspect(invalid)}; valid: #{Enum.join(valid, "|")}"}
    end
  end

  defp fetch_membership(actor, workspace_id, membership_id) do
    case WorkspaceMembership
         |> Ash.Query.load(:roles)
         |> Ash.Query.filter(id == ^membership_id)
         |> Ash.read(actor: actor, tenant: workspace_id) do
      {:ok, [membership | _]} ->
        {:ok, membership}

      {:ok, []} ->
        {:error, "membership not found"}

      {:error, %Ash.Error.Forbidden{}} ->
        {:error, "forbidden: not allowed to read members of workspace #{workspace_id}"}

      {:error, _} ->
        {:error, "failed to load membership"}
    end
  end
end
