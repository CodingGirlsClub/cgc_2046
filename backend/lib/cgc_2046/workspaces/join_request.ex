defmodule Cgc2046.Workspaces.JoinRequest do
  @moduledoc """
  JoinRequest(租户内实体,T06):加入申请。

  `request` 策略 workspace 的加入流程载体:
  - 申请人提交申请(可附带 `requested_role_ids` 请求意向角色,审批方决定最终角色)
  - 审批方(Owner/Admin,`join_request:manage`)approve 时指定 `role_ids` 创建
    membership + MembershipRole;或 reject
  - 状态机:pending → approved / rejected

  授权:
  - 提交 = 任何已认证用户(`actor_present`),但仅对 `request` 策略 workspace 有效
    (before_action 校验 join_policy)
  - 读 = 成员(MemberOfWorkspace)
  - 审批(approve/reject)= `join_request:manage`(Owner/Admin)
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

    attribute :user_id, :uuid,
      allow_nil?: false,
      public?: true

    attribute :status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :approved, :rejected]],
      public?: true

    attribute :requested_role_ids, {:array, :uuid},
      allow_nil?: true,
      default: [],
      public?: true

    attribute :decided_by, :uuid,
      allow_nil?: true,
      public?: true

    attribute :decided_at, :utc_datetime_usec,
      allow_nil?: true,
      public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :workspace, Cgc2046.Workspaces.Workspace,
      attribute_type: :uuid,
      allow_nil?: false,
      public?: true

    belongs_to :user, Cgc2046.Accounts.User,
      attribute_type: :uuid,
      allow_nil?: false,
      public?: true
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:requested_role_ids]

      change before_action(fn changeset, context ->
        if context.authorize? != false do
          changeset =
            changeset
            |> Ash.Changeset.change_attribute(:user_id, context.actor.id)
            |> ensure_request_policy(context.tenant)

          changeset
        else
          changeset
        end
      end)
    end

    update :approve do
      require_atomic? false
      argument :role_ids, {:array, :uuid}, allow_nil?: false

      change before_action(fn changeset, context ->
        if context.authorize? != false do
          changeset =
            changeset
            |> Cgc2046.Rbac.forbid_changeset(context.actor, "join_request:manage",
              tenant: context.tenant
            )
            |> Ash.Changeset.change_attribute(:decided_by, context.actor.id)
            |> Ash.Changeset.change_attribute(:decided_at, DateTime.utc_now())
            |> Ash.Changeset.change_attribute(:status, :approved)

          changeset
        else
          changeset
        end
      end)

      change after_action(fn changeset, join_request, _context ->
        role_ids = Ash.Changeset.get_argument(changeset, :role_ids)
        tenant = join_request.workspace_id

        with :ok <- grant_roles!(join_request, role_ids, tenant) do
          {:ok, join_request}
        end
      end)
    end

    update :reject do
      require_atomic? false

      change before_action(fn changeset, context ->
        if context.authorize? != false do
          changeset =
            changeset
            |> Cgc2046.Rbac.forbid_changeset(context.actor, "join_request:manage",
              tenant: context.tenant
            )
            |> Ash.Changeset.change_attribute(:decided_by, context.actor.id)
            |> Ash.Changeset.change_attribute(:decided_at, DateTime.utc_now())
            |> Ash.Changeset.change_attribute(:status, :rejected)

          changeset
        else
          changeset
        end
      end)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if Cgc2046.Rbac.Checks.MemberOfWorkspace
      forbid_if always()
    end

    policy action_type(:create) do
      authorize_if actor_present()
      forbid_if always()
    end

    policy action([:approve, :reject]) do
      authorize_if {Cgc2046.Rbac.Checks.HasPermission, permission: "join_request:manage"}
      forbid_if always()
    end
  end

  postgres do
    table "join_requests"
    repo Cgc2046.Repo
  end

  # 仅 request 策略 workspace 可提交申请(open 直接加入;invite_only 仅链接)
  defp ensure_request_policy(changeset, tenant) do
    import Ash.Query, only: [filter: 2]

    case Cgc2046.Workspaces.Workspace
         |> filter(id == ^tenant)
         |> Ash.read_one(tenant: nil, authorize?: false) do
      {:ok, %{join_policy: :request}} ->
        changeset

      _ ->
        Ash.Changeset.add_error(changeset, Ash.Error.Forbidden.exception([]))
    end
  end

  # 审批通过:创建 membership + 角色(已加入则复用 membership,幂等)。
  # 角色分配走 authorize?: false —— 审批本身已由 join_request:manage 把关。
  defp grant_roles!(join_request, role_ids, tenant) do
    import Ash.Query, only: [filter: 2]

    membership =
      case Cgc2046.Workspaces.WorkspaceMembership
           |> Ash.Query.filter(user_id == ^join_request.user_id)
           |> Ash.read_one(tenant: tenant, authorize?: false) do
        {:ok, nil} ->
          {:ok, m} =
            Ash.create(Cgc2046.Workspaces.WorkspaceMembership, %{user_id: join_request.user_id},
              tenant: tenant,
              authorize?: false
            )

          m

        {:ok, m} ->
          m
      end

    for role_id <- role_ids do
      import Ash.Query, only: [filter: 2]

      exists? =
        case Cgc2046.Workspaces.MembershipRole
             |> filter(membership_id == ^membership.id)
             |> filter(role_id == ^role_id)
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

    :ok
  rescue
    error -> {:error, error}
  end
end
