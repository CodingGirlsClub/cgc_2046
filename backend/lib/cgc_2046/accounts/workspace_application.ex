defmodule Cgc2046.Accounts.WorkspaceApplication do
  @moduledoc """
  工作台创建申请资源（Platform Admin Dashboard R6/R7）。

  全局资源（无 workspace_id——目标 workspace 尚不存在），表示用户申请创建工作台的请求。
  审批流程：pending → approved（platform_admin 审批通过，自动创建 workspace + applicant
  为 Owner）/ rejected（记录拒绝原因）/ expired（approval_deadline 过期）。

  字段：
  - `status`：pending | approved | rejected | expired
  - `name` / `slug` / `purpose`：申请创建的工作台元数据
  - `approved_by`：审批人（platform_admin）ID
  - `approved_at`：审批时间
  - `rejection_reason`：拒绝原因（可选）
  - `approval_deadline`：审批截止时间（默认 7 天，与 JoinRequest 决策 3 一致）
  - `expired_at`：过期时间

  审批模式复用 JoinRequest：approve 用原子条件 UPDATE（TOCTOU 守卫 + 过期守卫），
  Oban ApprovalExpiryWorker 主动扫描过期。
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.GlobalApi

  alias Cgc2046.ApprovalClaim

  attributes do
    uuid_primary_key(:id)

    attribute(:applicant_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "申请人（全局用户）ID"
    )

    attribute(:name, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "申请创建的工作台名称"
    )

    attribute(:slug, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "申请创建的工作台 slug（创建时校验全局唯一）"
    )

    attribute(:purpose, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "申请目的"
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :pending,
      public?: true,
      constraints: [one_of: [:pending, :approved, :rejected, :expired]],
      description: "申请状态"
    )

    attribute(:rejection_reason, :string,
      allow_nil?: true,
      public?: true,
      description: "拒绝原因（可选）"
    )

    attribute(:approved_by, :uuid,
      allow_nil?: true,
      public?: true,
      description: "审批人（platform_admin）ID"
    )

    attribute(:approved_at, :utc_datetime,
      allow_nil?: true,
      public?: true,
      description: "审批时间"
    )

    # #116 R10a：与 approved_by/approved_at 对称，reject 落处理人/时间
    # （展示用；留痕 single source of truth 是 AdminActionLog）
    attribute(:rejected_by, :uuid,
      allow_nil?: true,
      public?: true,
      description: "拒绝人（platform_admin）ID"
    )

    attribute(:rejected_at, :utc_datetime,
      allow_nil?: true,
      public?: true,
      description: "拒绝时间"
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

  relationships do
    belongs_to(:applicant, Cgc2046.Accounts.User, define_attribute?: false)
  end

  validations do
    validate(match(:slug, ~r/^[a-z0-9-]+$/),
      message: "slug must only contain lowercase letters, numbers and hyphens"
    )
  end

  postgres do
    table("workspace_applications")
    repo(Cgc2046.Repo)
  end

  # #116 R10a：reject 留痕的 metadata 纯函数（供 LogAdminAction change 声明以远程
  # 捕获引用；DSL 实体 opts 需可转义：匿名 fn 与私有函数捕获都不可，须为 public
  # 且定义在 actions 之前）。
  @doc false
  def application_log_metadata(_changeset, application) do
    %{
      slug: application.slug,
      name: application.name,
      applicant_id: application.applicant_id,
      rejection_reason: application.rejection_reason
    }
  end

  actions do
    default_accept([])
    defaults([:read])

    create :create do
      description("提交创建工作台申请（申请人自助，设 pending + approval_deadline）")
      accept([:name, :slug, :purpose])

      argument(:applicant_id, :uuid,
        allow_nil?: false,
        description: "申请人 ID"
      )

      change(set_attribute(:applicant_id, arg(:applicant_id)))
      change(set_attribute(:status, :pending))

      change(
        set_attribute(
          :approval_deadline,
          DateTime.add(DateTime.utc_now(), Cgc2046.ApprovalDeadline.default_timeout_days(), :day)
        )
      )
    end

    update :approve do
      description("审批通过创建工作台申请（platform_admin，自动创建 workspace + applicant 为 Owner）")
      require_atomic?(false)

      # 原子 claim：条件 UPDATE 把'读到 pending 且未过期才置 approved'下推成 DB 原子动作
      # （对齐 JoinRequest.approve 的 TOCTOU 根因修复范式）。WHERE 同时检查
      # status='pending' 与 approval_deadline 未过期——approval_deadline 的过期只由
      # Oban 扫描主动落库，approve 用 changeset 快照不重读，必须在此原子守卫，
      # 否则过期申请仍能被审批。0 行命中 = 已终态/已过期/被并发 approve，统一报
      # '该申请已被处理'。事务内执行：after_action 创建 workspace + applicant Owner
      # membership 失败时 status=approved 一并回滚，不留半态。
      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn cs ->
          actor = cs.context[:private][:actor]
          now = DateTime.utc_now()

          # 原子抢占收编 Cgc2046.ApprovalClaim（plan 2026-08-17-001 D4）：条件 UPDATE
          # 把'读到 pending 且未过期才置 approved'下推成 DB 原子动作（对齐
          # JoinRequest.approve 的 TOCTOU 根因修复范式）。WHERE 同时检查
          # status='pending' 与 approval_deadline 未过期（deadline 守卫 =
          # ApprovalDeadline.not_expired?/2 的 SQL 端口）——approval_deadline 的过期
          # 只由 Oban 扫描主动落库，approve 用 changeset 快照不重读，必须在此原子守卫。
          # 0 行命中 = 已终态/已过期/被并发 approve，统一报'该申请已被处理'；DB 错误经
          # {:error, {:database, _}} 崩溃（保持原裸 SQL MatchError 同级的失败语义，
          # 错误映射留资源层 D3）。事务内执行：after_action 创建 workspace + applicant
          # Owner membership 失败时 status=approved 一并回滚，不留半态。
          # force_change_attribute 触发的二次 UPDATE 幂等（同事务行锁已持有）。
          case ApprovalClaim.claim(cs.data,
                 table: :workspace_applications,
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
        after_action(fn changeset, application, _context ->
          # 创建 workspace：authorize?: false + 无 actor → Workspace.create after_action
          # 仅 seed 五角色差异标签、不建 Owner membership（actor nil 分支），Owner 由下方
          # admit_member 指定给申请人——applicant 为唯一 Owner（验收标准）。
          # slug 冲突 / 角色 seed 失败 → 返回 {:error, _}，父事务回滚（approve 原子
          # UPDATE 一并回滚，application 保持 pending，不留孤儿 workspace）。
          # #116：无 actor 调 create 同时保证治理留痕不双记——workspace_create 行只在
          # actor 非 nil 的直接创建路径落（workspace.ex on_missing_actor: :skip）。

          with {:ok, workspace} <-
                 Cgc2046.Accounts.Workspace
                 |> Ash.Changeset.for_create(:create, %{
                   slug: application.slug,
                   name: application.name,
                   join_policy: :request,
                   sponsorship_enabled: true
                 })
                 |> Ash.create(authorize?: false),
               {:ok, _membership} <-
                 Cgc2046.Accounts.MembershipContext.admit_member(
                   application.applicant_id,
                   workspace.id,
                   [:owner],
                   on_conflict: :business_error,
                   error_message: "该用户已是本工作台成员"
                 ),
               {:ok, _log} <-
                 Cgc2046.Changes.LogAdminAction.log(changeset, application, %{
                   action: :application_approve,
                   target_type: :workspace_application,
                   target_id: application.id,
                   metadata: %{
                     slug: application.slug,
                     name: application.name,
                     applicant_id: application.applicant_id,
                     workspace_id: workspace.id
                   }
                 }) do
            {:ok, application}
          else
            {:error, _} = err -> err
          end
        end)
      )
    end

    update :reject do
      description("拒绝创建工作台申请（platform_admin，可选拒绝原因）")
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

      # #116 R10a：落处理人/时间（与 approve 的 approved_by/at 对称，展示用；
      # default_accept([]) 不接受外部输入，force_change_attribute 显式落）。
      # 必须在 before_action 读 actor：for_update 阶段 actor 尚未注入 changeset
      # context（actor 经 Ash.update(actor:) 执行期才合并，approve 同款约束）。
      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn cs ->
          actor = cs.context[:private][:actor]

          cs
          |> Ash.Changeset.force_change_attribute(:rejected_by, actor && actor.id)
          |> Ash.Changeset.force_change_attribute(:rejected_at, DateTime.utc_now())
        end)
      end)

      # #116 R10a：治理留痕 application_reject（失败上抛回滚，fail-closed）
      change(
        {Cgc2046.Changes.LogAdminAction,
         action: :application_reject,
         target_type: :workspace_application,
         metadata: &__MODULE__.application_log_metadata/2}
      )
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

  # 状态守卫：reject/expire 仅允许从 :pending 转换（对齐 JoinRequest/Invitation 范式）。
  # before_action 直接读 changeset.data.status 快照（action 调用刚加载，足够新鲜），
  # 非法状态 add_error 阻止 commit。reject/expire 无 side effect（不建 workspace），
  # 并发双操作的 net effect 只是两次同值终态 UPDATE，无数据完整性风险，故无需条件
  # UPDATE 原子 claim（与 approve 不同——approve 建 workspace，并发/过期拦截由条件
  # UPDATE 承担）。approve 已不用此守卫。
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
    # :create 限申请人本人（applicant_id == actor.id，对齐 JoinRequest）
    policy action(:create) do
      authorize_if(expr(applicant_id == ^actor(:id)))
    end

    # :approve / :reject 仅 platform_admin
    policy action([:approve, :reject]) do
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end

    # :read 申请人本人可读自己的申请；platform_admin 可读全部
    policy action_type(:read) do
      authorize_if(expr(applicant_id == ^actor(:id)))
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end
  end

  graphql do
    type(:workspace_application)

    queries do
      list(:workspace_applications, :read, description: "工作台创建申请列表（申请人仅见自己；platform_admin 见全部）")
    end

    mutations do
      create(:create_workspace_application, :create, description: "提交创建工作台申请")

      update(:approve_workspace_application, :approve,
        description: "审批通过创建工作台申请（platform_admin，自动创建 workspace + applicant 为 Owner）"
      )

      update(:reject_workspace_application, :reject, description: "拒绝创建工作台申请（platform_admin）")
    end
  end

  admin do
    # #113 ops 面优化：导航分组 + 列表列裁剪（默认全列横向爆炸；敏感/超大字段不列出）
    resource_group(:access)
    table_columns([:id, :name, :slug, :status, :applicant_id, :approval_deadline, :inserted_at])
  end
end
