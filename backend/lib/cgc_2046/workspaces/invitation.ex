defmodule Cgc2046.Workspaces.Invitation do
  @moduledoc """
  Invitation(租户内实体,T05):邀请链接。

  - 生成(创建)= 需 `invitation:create`(Owner/Admin/Volunteer,spec §4)
  - **Volunteer 生成的邀请不可预授权 Admin 级角色**(生成时校验,超权 403;
    spec §12):预授权角色含 Owner/Admin 且 actor 无 `role:manage`(仅 Owner)
    → Forbidden
  - token 自生成随机串,库中只落 SHA-256 hash(`token_hash`,不落明文;
    与 ApiToken 同思路)
  - 读 = 成员(链接校验/预览归 JoinRequest 票)

  链接消费/撤销/过期流程随加入流程票落地,本票只负责生成与权限。
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
end
