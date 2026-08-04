defmodule Cgc2046.Accounts.JoinRequest do
  @moduledoc """
  工作台加入申请资源（#30）。

  领域模型（docs/01-定稿设计/领域模型定稿.md ER §INVITATION/JOIN_REQUEST）：
  JoinRequest 是租户资源（workspace_id），表示用户申请加入工作台的请求。
  审批流程：pending → approved（建 Membership + MembershipRole）/ rejected / expired。

  字段：
  - `status`：pending | approved | rejected | expired
  - `message`：申请留言（可选）
  - `approved_by`：审批人（全局用户）ID
  - `approved_at`：审批时间
  - `rejection_reason`：拒绝原因（可选）
  - `approval_deadline`：审批截止时间（默认 7 天，决策 3）
  - `expired_at`：过期时间

  决策 3：approval_timeout 本期硬编码 7 天常量（@default_approval_timeout_days），
  引擎接入后改读 WorkflowDefinition。
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.GlobalApi

  @default_approval_timeout_days 7

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台（租户）ID"
    )

    attribute(:user_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "申请人（全局用户）ID"
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :pending,
      public?: true,
      constraints: [one_of: [:pending, :approved, :rejected, :expired]],
      description: "申请状态"
    )

    attribute(:message, :string,
      allow_nil?: true,
      public?: true,
      description: "申请留言（可选）"
    )

    attribute(:approved_by, :uuid,
      allow_nil?: true,
      public?: true,
      description: "审批人（全局用户）ID"
    )

    attribute(:approved_at, :utc_datetime,
      allow_nil?: true,
      public?: true,
      description: "审批时间"
    )

    attribute(:rejection_reason, :string,
      allow_nil?: true,
      public?: true,
      description: "拒绝原因（可选）"
    )

    attribute(:approval_deadline, :utc_datetime,
      allow_nil?: true,
      public?: true,
      description: "审批截止时间（默认 created_at + 7 天）"
    )

    attribute(:expired_at, :utc_datetime,
      allow_nil?: true,
      public?: true,
      description: "过期时间"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)

    # 允许跨租户读取，隔离由 policy 保证
    global?(true)
  end

  relationships do
    belongs_to(:workspace, Cgc2046.Accounts.Workspace, define_attribute?: false)

    belongs_to(:user, Cgc2046.Accounts.User, define_attribute?: false)
  end

  identities do
    identity :unique_pending_join_request_per_ws_user, [:workspace_id, :user_id] do
      where(expr(status == :pending))
    end
  end

  postgres do
    table("join_requests")
    repo(Cgc2046.Repo)

    identity_wheres_to_sql(unique_pending_join_request_per_ws_user: "status = 'pending'")
  end

  # 惰性 expired 转换（决策 9）：读取时检查 approval_deadline < now() 的 pending 自动转 expired。
  # 零外部依赖，UI 倒计时从 approval_deadline 字段计算。
  # TODO: 引入 Quantum/Oban 定时器后改为主动转换，惰性检查作为兜底。
  preparations do
    prepare(fn query, _opts ->
      now = DateTime.utc_now()

      # 用 raw SQL 避免 Ash bulk_update 递归
      Cgc2046.Repo.query!(
        "UPDATE join_requests SET status = 'expired', expired_at = $1 WHERE status = 'pending' AND approval_deadline < $2",
        [now, now]
      )

      query
    end)
  end

  actions do
    default_accept([])
    defaults([:read])

    create :create do
      description("提交加入申请（申请人自助，需 workspace join_policy==:request）")
      accept([:message])

      argument(:workspace_id, :uuid,
        allow_nil?: false,
        description: "目标工作台 ID"
      )

      argument(:user_id, :uuid,
        allow_nil?: false,
        description: "申请人 ID"
      )

      change(set_attribute(:workspace_id, arg(:workspace_id)))
      change(set_attribute(:user_id, arg(:user_id)))
      change(set_attribute(:status, :pending))

      change(
        set_attribute(
          :approval_deadline,
          DateTime.add(DateTime.utc_now(), @default_approval_timeout_days, :day)
        )
      )

      change(Cgc2046.Changes.ValidateWorkspaceJoinPolicy)
    end

    update :approve do
      description("审批通过加入申请（Owner/Admin，自动建 Membership + MembershipRole）")
      require_atomic?(false)

      argument(:role_names, {:array, :atom},
        default: [:member],
        constraints: [items: [one_of: Cgc2046.Accounts.Role.role_names()]]
      )

      change(fn changeset, _context ->
        changeset
        |> Ash.Changeset.change_attribute(:status, :approved)
        |> Ash.Changeset.change_attribute(:approved_at, DateTime.utc_now())
      end)

      change(fn changeset, _context ->
        # before_action 在 commit 阶段运行，此时 actor 已在 changeset.context 中
        Ash.Changeset.before_action(changeset, fn cs ->
          actor = cs.context[:private][:actor]
          cs |> Ash.Changeset.change_attribute(:approved_by, actor && actor.id)
        end)
      end)

      change(
        after_action(fn changeset, join_request, _context ->
          actor = changeset.context[:private][:actor]
          tenant = join_request.workspace_id
          role_names = Ash.Changeset.get_argument(changeset, :role_names)

          # 建 Membership
          {:ok, membership} =
            Cgc2046.Accounts.WorkspaceMembership
            |> Ash.Changeset.for_create(:create, %{user_id: join_request.user_id})
            |> Ash.create(tenant: tenant, actor: actor, authorize?: false)

          # 建 MembershipRole（按角色名查找对应 role record）
          roles = Ash.read!(Cgc2046.Accounts.Role, tenant: tenant, authorize?: false)

          Enum.each(role_names, fn role_name ->
            role = Enum.find(roles, &(&1.name == role_name))

            if role do
              Ash.create!(
                Cgc2046.Accounts.MembershipRole,
                %{
                  membership_id: membership.id,
                  role_id: role.id
                },
                tenant: tenant,
                authorize?: false
              )
            end
          end)

          {:ok, join_request}
        end)
      )
    end

    update :reject do
      description("拒绝加入申请（Owner/Admin，可选拒绝原因）")

      argument(:rejection_reason, :string,
        allow_nil?: true,
        description: "拒绝原因"
      )

      change(set_attribute(:status, :rejected))
      change(set_attribute(:rejection_reason, arg(:rejection_reason)))
    end

    update :expire do
      description("将过期申请标记为 expired（内部使用）")

      change(set_attribute(:status, :expired))
      change(set_attribute(:expired_at, DateTime.utc_now()))
    end
  end

  policies do
    # :create 限申请人本人且 workspace join_policy==:request
    policy action(:create) do
      authorize_if(expr(user_id == ^actor(:id)))
    end

    # :approve / :reject 仅 Owner/Admin
    policy action([:approve, :reject]) do
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
    end

    # :read 申请人本人可读自己的申请；Owner/Admin 可读该工作台全部申请
    policy action_type(:read) do
      authorize_if(expr(user_id == ^actor(:id)))
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
    end
  end

  graphql do
    type(:join_request)

    queries do
      list(:join_requests, :read, description: "加入申请列表（申请人仅见自己；Owner/Admin 见全部）")
    end

    mutations do
      create(:create_join_request, :create, description: "提交加入申请")

      update(:approve_join_request, :approve,
        description: "审批通过加入申请（Owner/Admin，自动建 Membership + MembershipRole）"
      )

      update(:reject_join_request, :reject, description: "拒绝加入申请（Owner/Admin）")
    end
  end
end
