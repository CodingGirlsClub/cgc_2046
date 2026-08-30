defmodule Cgc2046.Accounts.JoinRequest do
  @moduledoc """
  工作台加入申请资源（#30）。

  领域模型（docs/01-定稿设计/领域模型定稿.md ER §INVITATION/JOIN_REQUEST）：
  JoinRequest 是租户资源（workspace_id），表示用户申请加入工作台的请求。
  审批流程：pending → approved（建 Membership（默认无标签角色））/ rejected / expired。

  字段：
  - `status`：pending | approved | rejected | expired
  - `message`：申请留言（可选）
  - `approved_by`：审批人（全局用户）ID
  - `approved_at`：审批时间
  - `rejection_reason`：拒绝原因（可选）
  - `approval_deadline`：审批截止时间（默认 7 天，决策 3）
  - `expired_at`：过期时间

  决策 3：approval_timeout 默认 7 天由 ApprovalDeadline.default_timeout_days() 单点
  提供（不再各资源自带常量），引擎接入后改读 WorkflowDefinition。
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Accounts

  alias Cgc2046.ApprovalClaim

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

      # 捕获形态（0-arity fn，Ash 每次执行时求值）——传求值结果会被 DSL 宏
      # 冻结成编译期常量（构建时刻+7天），构建 7 天后新申请生来即过期
      change(
        set_attribute(
          :approval_deadline,
          &Cgc2046.ApprovalDeadline.default_deadline_from_now/0
        )
      )

      change(Cgc2046.Accounts.Changes.ValidateWorkspaceJoinPolicy)

      # #115 ownerless 门控：join_policy 校验通过后，阻断向 pending-owner 工作台提交申请
      change(Cgc2046.Accounts.Changes.ValidateWorkspaceHasOwner)
    end

    update :approve do
      description("审批通过加入申请（Owner/Admin，自动建 Membership（默认无标签角色））")
      require_atomic?(false)

      argument(:role_names, {:array, :atom},
        default: [],
        constraints: [items: [one_of: Cgc2046.Accounts.Role.role_names()]]
      )

      # 原子 claim：条件 UPDATE 把'读到 pending 且未过期才置 approved'下推成 DB 原子动作
      # （root-cause fix for approve TOCTOU，对齐 Invitation.accept 的 Option A 范式）。
      # WHERE 同时检查 status='pending' 与 approval_deadline 未过期——approval_deadline
      # 的 lazy 过期只在 read 时计算，approve 用 changeset 快照不重读，必须在此原子守卫，
      # 否则过期申请仍能被审批。0 行命中=已终态/已过期/被并发 approve，统一报'该申请已被处理'。
      # 事务内执行：after_action 建 membership 失败时 status=approved 一并回滚，不留半态。
      # 替换原 validate_pending_status 快照守卫——条件 UPDATE 的 WHERE 已覆盖其'非 pending
      # 拒绝'职责，且是原子版本。
      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn cs ->
          actor = cs.context[:private][:actor]
          now = DateTime.utc_now()

          # 原子抢占收编 Cgc2046.ApprovalClaim（plan 2026-08-17-001 D4）：条件 UPDATE
          # 把'读到 pending 且未过期才置 approved'下推成 DB 原子动作（TOCTOU 根因修复，
          # 对齐 Invitation.accept 范式）。WHERE 同时检查 status='pending' 与
          # approval_deadline 未过期（deadline 守卫 = ApprovalDeadline.not_expired?/2
          # 的 SQL 端口）——approval_deadline 的 lazy 过期只在 read 时计算，approve 用
          # changeset 快照不重读，必须在此原子守卫。0 行命中=已终态/已过期/被并发
          # approve，统一报'该申请已被处理'；DB 错误经 {:error, {:database, _}} 崩溃
          # （保持原裸 SQL MatchError 同级的失败语义，错误映射留资源层 D3）。
          # 事务内执行：after_action 建 membership 失败时 status=approved 一并回滚。
          # force_change_attribute 触发的二次 UPDATE 幂等（同事务行锁已持有）。
          case ApprovalClaim.claim(cs.data,
                 table: :join_requests,
                 from: [:pending],
                 set: [
                   status: "approved",
                   approved_at: {:arg, :now},
                   approved_by: {:arg, :actor_id}
                 ],
                 deadline: {:approval_deadline, :future},
                 now: now,
                 actor_id: Cgc2046.Repo.uuid!(actor.id)
               ) do
            {:ok, _returned} ->
              cs
              |> Ash.Changeset.force_change_attribute(:status, :approved)
              |> Ash.Changeset.force_change_attribute(:approved_at, now)
              |> Ash.Changeset.force_change_attribute(:approved_by, actor.id)

            {:error, :not_claimed} ->
              cs
              |> Ash.Changeset.add_error(
                Ash.Error.Changes.InvalidAttribute.exception(
                  field: :status,
                  message: "该申请已被处理"
                )
              )
          end
        end)
      end)

      change(
        after_action(fn changeset, join_request, _context ->
          role_names = Ash.Changeset.get_argument(changeset, :role_names)

          # 入座委托 MembershipContext.admit_member/3（入座不变量唯一实现）。
          # 入座 user = 申请人（join_request.user_id，非 actor），角色 = 审批方指定 role_names，
          # 冲突语义 = 业务错误（「该用户」视角文案）。actor 仅用于父事务上下文，不传入 admit_member。
          case Cgc2046.Accounts.MembershipContext.admit_member(
                 join_request.user_id,
                 join_request.workspace_id,
                 role_names,
                 on_conflict: :business_error,
                 error_message: "该用户已是本工作台成员"
               ) do
            {:ok, _membership} -> {:ok, join_request}
            {:error, _} = err -> err
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
      change(set_attribute(:expired_at, &DateTime.utc_now/0))
    end
  end

  # 状态守卫：reject/expire 仅允许从 :pending 转换（对齐 Invitation.revoke 范式）。
  # before_action 直接读 changeset.data.status 快照（action 调用刚加载，足够新鲜），
  # 非法状态 add_error 阻止 commit。reject/expire 无 side effect（不建 membership），
  # 并发双操作的 net effect 只是两次同值终态 UPDATE，无数据完整性风险，故无需条件 UPDATE
  # 原子 claim（与 approve 不同——approve 建 membership，并发会撞 unique index 产生 confusing
  # 错误，已改条件 UPDATE）。approve 已不用此守卫，其并发与终态拦截由条件 UPDATE 承担。
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
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
    end

    # :read 申请人本人可读自己的申请；Owner/Admin 可读该工作台全部申请
    policy action_type(:read) do
      authorize_if(expr(user_id == ^actor(:id)))
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
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
        description: "审批通过加入申请（Owner/Admin，自动建 Membership（默认无标签角色））"
      )

      update(:reject_join_request, :reject, description: "拒绝加入申请（Owner/Admin）")
    end
  end

  admin do
    # #113 ops 面优化：导航分组 + 列表列裁剪（默认全列横向爆炸；敏感/超大字段不列出）
    resource_group(:access)
    table_columns([:id, :workspace_id, :user_id, :status, :approval_deadline, :inserted_at])
  end
end
