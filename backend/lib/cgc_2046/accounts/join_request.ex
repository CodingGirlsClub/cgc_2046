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

  require Ash.Query

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

  # 过期判定由前端 ApprovalChip 用 approval_deadline 读时计算（见 requests/page.tsx），
  # 不再在 read 时执行 UPDATE。落库过期留待主动调度。
  # TODO: 引入 Quantum/Oban 定时器后改为主动转换，惰性计算作为兜底。

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
        Ash.Changeset.before_action(changeset, &validate_pending_status/1)
      end)

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

          # 守卫：申请人已是该工作台成员时不重复建成员资格（DB 唯一索引兜底，
          # 此处转成带业务语义的错误，避免 generic unique-constraint 上抛）。
          existing =
            Cgc2046.Accounts.WorkspaceMembership
            |> Ash.Query.for_read(:read)
            |> Ash.Query.filter(workspace_id == ^tenant and user_id == ^join_request.user_id)
            |> Ash.read!(tenant: tenant, authorize?: false)

          if existing != [] do
            {:error,
             Ash.Error.Changes.InvalidAttribute.exception(
               field: :user_id,
               message: "该用户已是本工作台成员"
             )}
          else
            # 建 Membership。并发下两个 approve 可能同时越过上面的 existing 检查，
            # DB unique index (wm_unique_ws_user_idx) 会拒绝第二个；此处把 unique
            # 冲突转成与上面一致的业务错误，避免裸 MatchError 上抛 500。
            # 非 unique 的真实 DB 故障必须原样上抛，不能吞成「已是成员」。
            case Cgc2046.Accounts.WorkspaceMembership
                 |> Ash.Changeset.for_create(:create, %{user_id: join_request.user_id})
                 |> Ash.create(tenant: tenant, actor: actor, authorize?: false) do
              {:ok, membership} ->
                # 建 MembershipRole（按角色名查找对应 role record）。
                # reduce_while + Ash.create（非 bang）：失败短路返回 {:error, ...}，
                # 走 ash_graphql to_errors → 结构化 GraphQL error；父事务仍 rollback，
                # 已建的 Membership / :approved 标记一并回滚，数据完整性不变。
                roles = Ash.read!(Cgc2046.Accounts.Role, tenant: tenant, authorize?: false)

                Enum.reduce_while(role_names, :ok, fn role_name, _acc ->
                  role = Enum.find(roles, &(&1.name == role_name))

                  if role do
                    case Ash.create(
                           Cgc2046.Accounts.MembershipRole,
                           %{
                             membership_id: membership.id,
                             role_id: role.id
                           },
                           tenant: tenant,
                           authorize?: false
                         ) do
                      {:ok, _} -> {:cont, :ok}
                      {:error, error} -> {:halt, {:error, error}}
                    end
                  else
                    {:cont, :ok}
                  end
                end)
                |> case do
                  :ok -> {:ok, join_request}
                  {:error, _} = err -> err
                end

              {:error, error} ->
                if Cgc2046.Accounts.MembershipContext.unique_membership_conflict?(error) do
                  {:error,
                   Ash.Error.Changes.InvalidAttribute.exception(
                     field: :user_id,
                     message: "该用户已是本工作台成员"
                   )}
                else
                  {:error, error}
                end
            end
          end
        end)
      )
    end

    update :reject do
      description("拒绝加入申请（Owner/Admin，可选拒绝原因）")
      require_atomic?(false)

      argument(:rejection_reason, :string,
        allow_nil?: true,
        description: "拒绝原因"
      )

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &validate_pending_status/1)
      end)

      change(set_attribute(:status, :rejected))
      change(set_attribute(:rejection_reason, arg(:rejection_reason)))
    end

    update :expire do
      description("将过期申请标记为 expired（内部使用）")
      require_atomic?(false)

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &validate_pending_status/1)
      end)

      change(set_attribute(:status, :expired))
      change(set_attribute(:expired_at, DateTime.utc_now()))
    end
  end

  # 状态守卫：approve/reject/expire 仅允许从 :pending 转换（对齐 Invitation.accept 范式）。
  # before_action 直接读 changeset.data.status 快照（action 调用刚加载，足够新鲜），
  # 非法状态 add_error 阻止 commit，早于 P1#5 的 after_action 成员守卫，避免非法 approve
  # 走到"该用户已是本工作台成员"误导路径。并发双 approve 的竞态由 DB unique index 兜底，
  # 不在状态守卫职责内。
  defp validate_pending_status(cs) do
    case cs.data.status do
      :pending ->
        cs

      status ->
        cs
        |> Ash.Changeset.add_error(
          Ash.Error.Changes.InvalidAttribute.exception(
            field: :status,
            message: pending_status_message(status)
          )
        )
    end
  end

  defp pending_status_message(:approved), do: "申请已通过，无法重复处理"
  defp pending_status_message(:rejected), do: "申请已被拒绝，无法重复处理"
  defp pending_status_message(:expired), do: "申请已过期，无法重复处理"

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
