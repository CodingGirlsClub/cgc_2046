defmodule Cgc2046.Workspaces.Invitation do
  @moduledoc """
  Invitation(租户内实体,T05+T06):邀请链接。

  ## T05(生成与权限)
  - 生成(创建)= 需 `invitation:create`(Owner/Admin/Volunteer,spec §4)
  - **Volunteer 生成的邀请不可预授权 Admin 级角色**(生成时校验,超权 403;
    spec §12):预授权角色含 Owner/Admin 且 actor 无 `role:manage`(仅 Owner)
    → Forbidden
  - token 自生成随机串,库中只落 SHA-256 hash(`token_hash`,不落明文;
    与 ApiToken 同思路)
  - 读 = 成员(链接校验/预览归 JoinRequest 票)

  ## T06(消费/撤销/过期)
  - `consume`(通用 action):凭 plain_token 消费邀请 —— 校验
    active/未过期/target_email(空=公开链接,非空须匹配当前用户邮箱)/
    预授权角色消费侧校验(含 Admin 级但 inviter 无 `role:manage` → 403);
    通过后创建 membership + 分配预授权角色(幂等:已加入则复用),置 used
  - `revoke`(update action):撤销链接,置 revoked;撤销后立即失效
  - 状态机:active → used / revoked(expired 由 expires_at 判定,不改状态)
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Api

  multitenancy do
    strategy :attribute
    attribute :workspace_id
  end

  attributes do
    uuid_primary_key :id

    attribute :token_hash, :string,
      allow_nil?: false,
      public?: false

    attribute :expires_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true

    attribute :target_email, :string,
      allow_nil?: true,
      public?: true

    attribute :preauthorized_role_ids, {:array, :uuid},
      allow_nil?: false,
      default: [],
      public?: true

    attribute :status, :atom,
      allow_nil?: false,
      default: :active,
      constraints: [one_of: [:active, :used, :revoked]],
      public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :workspace, Cgc2046.Workspaces.Workspace,
      attribute_type: :uuid,
      allow_nil?: false,
      public?: true

    belongs_to :inviter, Cgc2046.Accounts.User,
      attribute_type: :uuid,
      allow_nil?: false,
      public?: true
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:expires_at, :target_email, :preauthorized_role_ids]
      argument :plain_token, :string, allow_nil?: false

      change before_action(fn changeset, context ->
        changeset =
          if context.authorize? != false do
            changeset
            |> Cgc2046.Rbac.forbid_changeset(context.actor, "invitation:create",
              tenant: context.tenant
            )
            |> forbid_admin_preauthorization(context.actor, context.tenant)
          else
            changeset
          end

        plain = Ash.Changeset.get_argument(changeset, :plain_token)

        changeset
        |> Ash.Changeset.change_attribute(:token_hash, hash_token(plain))
        |> Ash.Changeset.change_attribute(:inviter_id, context.actor.id)
      end)
    end

    # T06 消费邀请链接(通用 action,不依赖既有 record):
    # 凭 plain_token 校验并完成加入流程。policy 见下(action_type(:action))。
    action :consume do
      argument :plain_token, :string, allow_nil?: false
      returns :map

      run fn input, context ->
        tenant = context.tenant
        token_hash = hash_token(input.arguments.plain_token)

        with {:ok, invitation} <- find_by_token(token_hash, tenant),
             :ok <- check_active(invitation),
             :ok <- check_expiry(invitation),
             :ok <- check_target_email(invitation, context.actor),
             :ok <- check_preauthorized_roles(invitation, tenant),
             {:ok, membership} <- grant_membership(invitation, context.actor, tenant),
             {:ok, used} <- mark_used(invitation, tenant) do
          {:ok, %{invitation: used, membership: membership}}
        end
      end
    end

    # T06 撤销邀请链接:置 revoked,撤销后立即失效(consume 校验 active)。
    update :revoke do
      change set_attribute(:status, :revoked)
    end

    # T06 内部:consume 成功后置 used(不对外暴露,仅 authorize?: false 调用)。
    update :mark_used_internal do
      accept [:status]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if Cgc2046.Rbac.Checks.MemberOfWorkspace
      forbid_if always()
    end

    policy action_type(:create) do
      authorize_if {Cgc2046.Rbac.Checks.HasPermission, permission: "invitation:create"}
      forbid_if always()
    end

    policy action(:consume) do
      # 任何已认证用户可尝试消费;校验在 run 内(active/过期/email/预授权)
      authorize_if actor_present()
      forbid_if always()
    end

    policy action(:revoke) do
      authorize_if {Cgc2046.Rbac.Checks.HasPermission, permission: "invitation:create"}
      forbid_if always()
    end
  end

  postgres do
    table "invitations"
    repo Cgc2046.Repo
  end

  @doc "生成 token hash(SHA-256,不落明文)。"
  def hash_token(plain) do
    :crypto.hash(:sha256, plain) |> Base.encode16(case: :lower)
  end

  defp forbid_admin_preauthorization(changeset, actor, tenant) do
    role_ids = Ash.Changeset.get_attribute(changeset, :preauthorized_role_ids) || []

    if role_ids != [] and
         not Cgc2046.Rbac.can?(actor, "role:manage", tenant: tenant) and
         Enum.any?(role_ids, &admin_level_role?(&1, tenant)) do
      Ash.Changeset.add_error(changeset, Ash.Error.Forbidden.exception([]))
    else
      changeset
    end
  end

  defp admin_level_role?(role_id, tenant) do
    import Ash.Query, only: [filter: 2]

    case Cgc2046.Workspaces.Role
         |> filter(id == ^role_id)
         |> Ash.read_one(tenant: tenant, authorize?: false) do
      {:ok, %{name: name}} -> name in ["Owner", "Admin"]
      _ -> false
    end
  end

  # ---- T06 消费流程内部实现(均 authorize?: false,校验在 run 内显式完成) ----

  defp find_by_token(token_hash, tenant) do
    import Ash.Query, only: [filter: 2]

    case Cgc2046.Workspaces.Invitation
         |> filter(token_hash == ^token_hash)
         |> Ash.read_one(tenant: tenant, authorize?: false) do
      {:ok, nil} ->
        {:error,
         Ash.Error.Invalid.exception(errors: [
           Ash.Error.Changes.InvalidChanges.exception(fields: [:plain_token],
             message: "invalid invitation")
         ])}

      {:ok, invitation} ->
        {:ok, invitation}

      {:error, error} ->
        {:error, error}
    end
  end

  defp check_active(%{status: :active}), do: :ok

  defp check_active(_) do
    {:error,
     Ash.Error.Invalid.exception(errors: [
       Ash.Error.Changes.InvalidChanges.exception(fields: [:status],
         message: "invitation not active")
     ])}
  end

  defp check_expiry(%{expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :lt do
      {:error,
       Ash.Error.Invalid.exception(errors: [
         Ash.Error.Changes.InvalidChanges.exception(fields: [:expires_at],
           message: "invitation expired")
       ])}
    else
      :ok
    end
  end

  defp check_target_email(%{target_email: nil}, _actor), do: :ok
  defp check_target_email(%{target_email: email}, actor) when is_binary(email) do
    if email == actor.email do
      :ok
    else
      {:error,
       Ash.Error.Invalid.exception(errors: [
         Ash.Error.Changes.InvalidChanges.exception(fields: [:target_email],
           message: "invitation email mismatch")
       ])}
    end
  end

  # 消费侧校验:预授权角色含 Admin 级(Owner/Admin)时,邀请人(inviter)
  # 必须持有 role:manage,否则 403 —— 兜底 T05 生成侧校验(数据异常/越权链路)。
  defp check_preauthorized_roles(%{preauthorized_role_ids: []}, _tenant), do: :ok

  defp check_preauthorized_roles(%{preauthorized_role_ids: role_ids, inviter_id: inviter_id}, tenant) do
    if Enum.any?(role_ids, &admin_level_role?(&1, tenant)) and
         not Cgc2046.Rbac.can?(%{id: inviter_id}, "role:manage", tenant: tenant) do
      {:error, Ash.Error.Forbidden.exception([])}
    else
      :ok
    end
  end

  # 创建 membership(幂等:已加入则复用)+ 分配预授权角色
  defp grant_membership(%{preauthorized_role_ids: role_ids}, actor, tenant) do
    import Ash.Query, only: [filter: 2]

    membership =
      case Cgc2046.Workspaces.WorkspaceMembership
           |> filter(user_id == ^actor.id)
           |> Ash.read_one(tenant: tenant, authorize?: false) do
        {:ok, nil} ->
          {:ok, m} =
            Ash.create(Cgc2046.Workspaces.WorkspaceMembership, %{user_id: actor.id},
              tenant: tenant,
              authorize?: false
            )

          m

        {:ok, m} ->
          m
      end

    for role_id <- role_ids do
      exists? =
        case Cgc2046.Workspaces.MembershipRole
             |> Ash.Query.filter(membership_id == ^membership.id)
             |> Ash.Query.filter(role_id == ^role_id)
             |> Ash.read_one(tenant: tenant, authorize?: false) do
          {:ok, nil} -> false
          _ -> true
        end

      unless exists? do
        Ash.create!(Cgc2046.Workspaces.MembershipRole, %{
          membership_id: membership.id,
          role_id: role_id
        }, tenant: tenant, authorize?: false)
      end
    end

    {:ok, membership}
  rescue
    error -> {:error, error}
  end

  defp mark_used(invitation, tenant) do
    invitation
    |> Ash.Changeset.for_update(:mark_used_internal, %{status: :used},
      tenant: tenant,
      authorize?: false
    )
    |> Ash.update()
  end
end
