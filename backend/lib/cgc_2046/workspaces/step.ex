defmodule Cgc2046.Workspaces.Step do
  @moduledoc """
  Step(租户内实体,T05):Workflow 的步骤,是授权最小单元(见
  docs/领域模型定稿.md §3.2)。

  每个 Step 声明哪些角色可执行(`roles` 多对多,经 StepRole 关联)。
  **执行授权 = 成员角色集 ∩ Step 允许角色集 交集非空**
  (`Rbac.role_intersection?/3`)。

  T08(issue #9)落地状态机与顺序解锁(spec §7):
  - `status`: 待执行 → 进行中 → 完成(pending/in_progress/completed),默认 pending。
  - `execute`: 校验 ①Workflow 未归档 ②前序 Steps(position 更小)全部 completed
    (顺序解锁:N+1 在 N 完成前不可执行)③角色交集 → 返回 step(executed: true)。
  - `complete`: 执行者(角色交集非空)把 step 标记为 completed。

  读 = 成员;创建 = 需 `workflow:create`(部署者建 Step)。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Api

  require Ash.Query

  multitenancy do
    strategy :attribute
    attribute :workspace_id
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string,
      allow_nil?: false,
      public?: true

    attribute :position, :integer,
      allow_nil?: false,
      public?: true

    attribute :type, :string,
      allow_nil?: true,
      public?: true

    attribute :agent_hint, :string,
      allow_nil?: true,
      public?: true

    attribute :status, :string,
      allow_nil?: false,
      default: "pending",
      public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :workspace, Cgc2046.Workspaces.Workspace,
      attribute_type: :uuid,
      allow_nil?: false,
      public?: true

    belongs_to :workflow, Cgc2046.Workspaces.Workflow,
      attribute_type: :uuid,
      allow_nil?: false,
      public?: true

    has_many :step_roles, Cgc2046.Workspaces.StepRole,
      destination_attribute: :step_id

    many_to_many :roles, Cgc2046.Workspaces.Role,
      through: Cgc2046.Workspaces.StepRole,
      source_attribute_on_join_resource: :step_id,
      destination_attribute_on_join_resource: :role_id
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:title, :position, :type, :agent_hint, :workflow_id]

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

    read :execute do
      primary? false
      argument :step_id, :uuid, allow_nil?: false

      manual fn query, _data_layer_query, context ->
        step_id = Ash.Query.get_argument(query, :step_id)

        step =
          Ash.get!(__MODULE__, step_id,
            tenant: context.tenant,
            actor: context.actor,
            load: [:roles, :workflow, :step_roles],
            authorize?: true
          )

        with :ok <- check_workflow_archived(step),
             :ok <- check_order_unlocked(step, context.tenant),
             :ok <- check_role_intersection(step, context.actor, context.tenant) do
          {:ok, [step]}
        else
          {:error, error} -> {:error, error}
        end
      end
    end

    update :complete do
      primary? false
      require_atomic? false

      change before_action(fn changeset, context ->
        if context.authorize? != false do
          step = changeset.data
          allowed_role_ids = Enum.map(step.roles, & &1.id)

          if Cgc2046.Rbac.role_intersection?(context.actor, context.tenant, allowed_role_ids) do
            changeset
          else
            Ash.Changeset.add_error(changeset, Ash.Error.Forbidden.exception([]))
          end
        else
          changeset
        end
      end)

      change fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :status) do
          s when s in ["pending", "in_progress", "completed"] ->
            Ash.Changeset.force_change_attribute(changeset, :status, "completed")

          _ ->
            Ash.Changeset.add_error(changeset, "非法 Step 状态")
        end
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if Cgc2046.Rbac.Checks.MemberOfWorkspace
      forbid_if always()
    end

    policy action(:execute) do
      authorize_if Cgc2046.Rbac.Checks.MemberOfWorkspace
      forbid_if always()
    end

    policy action_type(:create) do
      authorize_if {Cgc2046.Rbac.Checks.HasPermission, permission: "workflow:create"}
      forbid_if always()
    end

    policy action(:complete) do
      authorize_if Cgc2046.Rbac.Checks.MemberOfWorkspace
      forbid_if always()
    end
  end

  postgres do
    table "steps"
    repo Cgc2046.Repo
  end

  # ---------- execute 内部校验 ----------

  defp check_workflow_archived(step) do
    if step.workflow.status == "archived" do
      {:error, Ash.Error.Forbidden.exception([])}
    else
      :ok
    end
  end

  defp check_order_unlocked(step, tenant) do
    preceding =
      __MODULE__
      |> Ash.Query.filter(workflow_id == ^step.workflow_id)
      |> Ash.Query.filter(position < ^step.position)
      |> Ash.read!(tenant: tenant, authorize?: false)

    if Enum.all?(preceding, &(&1.status == "completed")) do
      :ok
    else
      {:error, Ash.Error.Forbidden.exception([])}
    end
  end

  defp check_role_intersection(step, actor, tenant) do
    allowed_role_ids = Enum.map(step.roles, & &1.id)

    if Cgc2046.Rbac.role_intersection?(actor, tenant, allowed_role_ids) do
      :ok
    else
      {:error, Ash.Error.Forbidden.exception([])}
    end
  end
end
