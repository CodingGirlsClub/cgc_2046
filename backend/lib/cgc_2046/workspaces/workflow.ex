defmodule Cgc2046.Workspaces.Workflow do
  @moduledoc """
  Workflow(租户内实体,T05):教研流程(Workflow 构建/部署)。

  T05 聚焦授权:部署(创建)= 需 `workflow:create`(Owner/Admin/Tutor,见
  spec §4 权限矩阵);读 = 成员。

  T08(issue #9)落地 DSL 部署与状态机(spec §6/§7):
  - `status`: 草稿 → 发布 → 归档(draft/published/archived),默认 published
    (DSL 部署即发布);归档后 Step 不可执行(顺序解锁见 Step.execute)。
  - `publish` / `archive` 为状态流转 action,写 action 首行 `Rbac.ensure!`
    校验 `workflow:create`(与部署同权限,Owner/Admin/Tutor)。

  写 action 统一首行 `Rbac.ensure!`(spec §4 约定),policy 双保险。
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

    attribute :description, :string,
      allow_nil?: true,
      public?: true

    attribute :dsl_version, :integer,
      allow_nil?: false,
      default: 1,
      public?: true

    attribute :status, :string,
      allow_nil?: false,
      default: "published",
      public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :workspace, Cgc2046.Workspaces.Workspace,
      attribute_type: :uuid,
      allow_nil?: false,
      public?: true

    has_many :steps, Cgc2046.Workspaces.Step,
      destination_attribute: :workflow_id
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:name, :description, :dsl_version, :status]

      change before_action(fn changeset, context ->
               if context.authorize? != false do
                 Cgc2046.Rbac.forbid_changeset(changeset, context.actor, "workflow:create",
                   tenant: context.tenant
                 )
               else
                 changeset
               end
             end)
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:name, :description, :dsl_version, :status]

      change before_action(fn changeset, context ->
               if context.authorize? != false do
                 Cgc2046.Rbac.forbid_changeset(changeset, context.actor, "workflow:create",
                   tenant: context.tenant
                 )
               else
                 changeset
               end
             end)
    end

    update :publish do
      primary? false
      require_atomic? false

      change before_action(fn changeset, context ->
        if context.authorize? != false do
          Cgc2046.Rbac.forbid_changeset(changeset, context.actor, "workflow:create",
            tenant: context.tenant
          )
        else
          changeset
        end
      end)

      change fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :status) do
          "draft" -> Ash.Changeset.force_change_attribute(changeset, :status, "published")
          _ -> Ash.Changeset.add_error(changeset, "只有草稿状态可发布")
        end
      end
    end

    update :archive do
      primary? false
      require_atomic? false

      change before_action(fn changeset, context ->
        if context.authorize? != false do
          Cgc2046.Rbac.forbid_changeset(changeset, context.actor, "workflow:create",
            tenant: context.tenant
          )
        else
          changeset
        end
      end)

      change fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :status) do
          s when s in ["draft", "published"] ->
            Ash.Changeset.force_change_attribute(changeset, :status, "archived")

          _ ->
            Ash.Changeset.add_error(changeset, "已归档的 Workflow 不能重复归档")
        end
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if Cgc2046.Rbac.Checks.MemberOfWorkspace
      forbid_if always()
    end

    policy action_type(:create) do
      authorize_if {Cgc2046.Rbac.Checks.HasPermission, permission: "workflow:create"}
      forbid_if always()
    end

    policy action_type(:update) do
      authorize_if {Cgc2046.Rbac.Checks.HasPermission, permission: "workflow:create"}
      forbid_if always()
    end
  end

  postgres do
    table "workflows"
    repo Cgc2046.Repo
  end
end
