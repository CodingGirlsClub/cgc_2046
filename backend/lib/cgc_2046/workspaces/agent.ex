defmodule Cgc2046.Workspaces.Agent do
  @moduledoc """
  Agent(租户内实体,T05):两种形态 —— 个人(角色分身,仅本人可见可用)
  与公共(Workspace 级,按 AgentRole 独立使用授权)。

  权限矩阵(见 docs/领域模型定稿.md §3.3 / spec §4):
  - 创建个人 Agent = 任何成员;owner 自动为 actor 的 membership
  - 使用自己个人 Agent = 本人;使用他人个人 Agent = 一律拒绝
  - 创建/编辑公共 Agent = Owner/Admin/Tutor(`agent:public:create/edit`)
  - 删除公共 Agent = Owner/Admin(`agent:public:delete`)
  - 读:个人=仅 owner;公共=成员
  - 独立使用公共 Agent = 成员角色 ∩ AgentRole 角色 交集非空
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

    attribute :name, :string,
      allow_nil?: false,
      public?: true

    attribute :type, :atom,
      allow_nil?: false,
      constraints: [one_of: [:personal, :public]],
      public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :workspace, Cgc2046.Workspaces.Workspace,
      attribute_type: :uuid,
      allow_nil?: false,
      public?: true

    belongs_to :owner, Cgc2046.Workspaces.WorkspaceMembership,
      attribute_type: :uuid,
      allow_nil?: true,
      public?: true

    has_many :agent_roles, Cgc2046.Workspaces.AgentRole,
      destination_attribute: :agent_id

    many_to_many :roles, Cgc2046.Workspaces.Role,
      through: Cgc2046.Workspaces.AgentRole,
      source_attribute_on_join_resource: :agent_id,
      destination_attribute_on_join_resource: :role_id
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:name, :type]

      change before_action(fn changeset, context ->
               if context.authorize? != false do
                 changeset =
                   if Ash.Changeset.get_attribute(changeset, :type) == :public do
                     Cgc2046.Rbac.forbid_changeset(changeset, context.actor,
                       "agent:public:create",
                       tenant: context.tenant
                     )
                   else
                     Cgc2046.Rbac.forbid_changeset(changeset, context.actor,
                       "agent:personal:create",
                       tenant: context.tenant
                     )
                   end

                 # 个人 Agent:owner 强制为 actor 的 membership(不可冒名)
                 if Ash.Changeset.get_attribute(changeset, :type) == :personal do
                   case membership_of_actor(context.actor, context.tenant) do
                     {:ok, membership_id} ->
                       Ash.Changeset.force_change_attribute(changeset, :owner_id, membership_id)

                     :error ->
                       Ash.Changeset.add_error(changeset, "非成员不能创建个人 Agent")
                   end
                 else
                   changeset
                 end
               else
                 changeset
               end
             end)
    end

    update :update do
      primary? true
      accept [:name]
      require_atomic? false

      change before_action(fn changeset, context ->
               if context.authorize? != false do
                 agent = changeset.data

                 if agent.type == :public do
                   Cgc2046.Rbac.forbid_changeset(changeset, context.actor, "agent:public:edit",
                     tenant: context.tenant
                   )
                 else
                   forbid_unless_owner(changeset, context.actor, context.tenant)
                 end
               else
                 changeset
               end
             end)
    end

    destroy :destroy do
      primary? true
      require_atomic? false

      change before_action(fn changeset, context ->
               if context.authorize? != false do
                 agent = changeset.data

                 if agent.type == :public do
                   Cgc2046.Rbac.forbid_changeset(changeset, context.actor,
                     "agent:public:delete",
                     tenant: context.tenant
                   )
                 else
                   forbid_unless_owner(changeset, context.actor, context.tenant)
                 end
               else
                 changeset
               end
             end)
    end
  end

  policies do
    policy_group action_type(:read) do
      policy expr(type == :public) do
        authorize_if Cgc2046.Rbac.Checks.MemberOfWorkspace
        forbid_if always()
      end

      policy expr(type == :personal) do
        authorize_if expr(owner.user_id == ^actor(:id))
        forbid_if always()
      end
    end

    policy_group action_type(:create) do
      policy expr(type == :public) do
        authorize_if {Cgc2046.Rbac.Checks.HasPermission, permission: "agent:public:create"}
        forbid_if always()
      end

      policy expr(type == :personal) do
        authorize_if Cgc2046.Rbac.Checks.MemberOfWorkspace
        forbid_if always()
      end
    end

    policy_group action_type(:update) do
      policy expr(type == :public) do
        authorize_if {Cgc2046.Rbac.Checks.HasPermission, permission: "agent:public:edit"}
        forbid_if always()
      end

      policy expr(type == :personal) do
        authorize_if Cgc2046.Rbac.Checks.MemberOfWorkspace
        forbid_if always()
      end
    end

    policy_group action_type(:destroy) do
      policy expr(type == :public) do
        authorize_if {Cgc2046.Rbac.Checks.HasPermission, permission: "agent:public:delete"}
        forbid_if always()
      end

      policy expr(type == :personal) do
        authorize_if Cgc2046.Rbac.Checks.MemberOfWorkspace
        forbid_if always()
      end
    end
  end

  postgres do
    table "agents"
    repo Cgc2046.Repo
  end

  defp membership_of_actor(nil, _tenant), do: :error

  defp membership_of_actor(actor, tenant) do
    import Ash.Query, only: [filter: 2]

    Cgc2046.Workspaces.WorkspaceMembership
    |> filter(user_id == ^actor.id)
    |> Ash.read_one(tenant: tenant, authorize?: false)
    |> case do
      {:ok, membership} -> {:ok, membership.id}
      _ -> :error
    end
  end

  defp forbid_unless_owner(changeset, actor, tenant) do
    agent = changeset.data

    case membership_of_actor(actor, tenant) do
      {:ok, membership_id} when membership_id == agent.owner_id ->
        changeset

      _ ->
        Ash.Changeset.add_error(changeset, Ash.Error.Forbidden.exception([]))
    end
  end
end
