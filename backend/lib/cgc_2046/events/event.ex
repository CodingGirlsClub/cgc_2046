defmodule Cgc2046.Events.Event do
  @moduledoc """
  活动资源（Slice C #39，阶段 6 教研实例化最小子集）。

  领域模型（docs/01-定稿设计/领域模型定稿.md §5.2 ER）：Event 是活动实体，
  教研字段之外，Phase 2 加入报名策略、容量与报名截止时间。`confirmed_count`
  是数据库原子占位计数，Enrollment 创建/确认通过条件 UPDATE 维护，防并发超卖。

  ## 教研实例化（#39）

  `launch` action：draft → open，发 `event.launched` 信号（SignalEmitter 事务内
  outbox 入队，SignalPublishWorker 经 JidoAdapter 总线异步投递），
  `Cgc2046.Workflows.ResearchInstantiator` 订阅该信号创建教研 WorkflowRun。

  ## 多租户

  multitenancy attribute :workspace_id，与 WorkflowRun 一致；workspace_id 由 tenant
  强制，不接受调用方传入。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Api

  alias Cgc2046.Repo

  @status_values [:draft, :open, :closed, :cancelled]
  @enrollment_policy_values [:open, :request, :invite_only]
  @visibility_values [:public, :workspace]

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台（租户）ID"
    )

    attribute(:title, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "活动标题"
    )

    attribute(:slug, :string,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "公开 URL 段（/events/[slug] 或 /courses/[slug]，全局唯一）"
    )

    attribute(:description, :string,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "公开展示文案（可空；null 由展示层按空串呈现）"
    )

    attribute(:research_enabled, :boolean,
      allow_nil?: false,
      default: true,
      public?: true,
      writable?: true,
      description: "是否启用教研 workflow"
    )

    attribute(:research_requirements, :map,
      default: %{},
      public?: true,
      writable?: true,
      description: "教研材料需求（audience/duration/sections 等），作为 run input 注入"
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :draft,
      public?: true,
      writable?: false,
      constraints: [one_of: @status_values],
      description: "活动状态：draft 草稿 / open 已发布 / closed 已结束 / cancelled 已取消"
    )

    attribute(:workflow_run_id, :uuid,
      public?: true,
      writable?: true,
      description: "教研 workflow 产物引用（领域模型 §5.2 ER）"
    )

    attribute(:enrollment_policy, :atom,
      allow_nil?: false,
      default: :open,
      public?: true,
      writable?: true,
      constraints: [one_of: @enrollment_policy_values],
      description: "报名策略：open / request / invite_only"
    )

    attribute(:visibility, :atom,
      allow_nil?: false,
      default: :public,
      public?: true,
      writable?: true,
      constraints: [one_of: @visibility_values],
      description: "可见性：public 公开可见 / workspace 仅工作台可见（可随时双向切换，D9）"
    )

    attribute(:capacity, :integer,
      allow_nil?: true,
      public?: true,
      writable?: true,
      constraints: [min: 1],
      description: "报名名额上限；nil 表示不限"
    )

    attribute(:confirmed_count, :integer,
      allow_nil?: false,
      default: 0,
      public?: true,
      writable?: false,
      constraints: [min: 0],
      description: "已确认名额数（仅由 Enrollment 原子维护）"
    )

    attribute(:registration_deadline, :utc_datetime,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "报名截止时间；nil 表示不设截止"
    )

    attribute(:sponsorship_enabled, :boolean,
      allow_nil?: false,
      default: true,
      public?: true,
      writable?: true,
      description: "是否开放赞助入口（默认开；tiers 未配置时入口隐藏，E-5 readiness ②）"
    )

    attribute(:sponsorship_tiers, {:array, :map},
      allow_nil?: false,
      default: [],
      public?: true,
      writable?: true,
      description: "赞助档位配置（SponsorshipTier 形状，见 sponsorship_tier.ex）"
    )

    attribute(:sponsorship_deadline, :utc_datetime,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "赞助意向截止；nil 表示长期开放"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  validations do
    validate({Cgc2046.Events.SponsorshipTiersValidation, []})
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)
    global?(true)
  end

  relationships do
    belongs_to(:workspace, Cgc2046.Accounts.Workspace,
      source_attribute: :workspace_id,
      destination_attribute: :id,
      allow_nil?: false
    )

    belongs_to(:workflow_run, Cgc2046.Workflows.WorkflowRun,
      source_attribute: :workflow_run_id,
      destination_attribute: :id,
      allow_nil?: true
    )
  end

  actions do
    default_accept([
      :title,
      :research_enabled,
      :research_requirements,
      :enrollment_policy,
      :capacity,
      :registration_deadline,
      :visibility,
      :slug,
      :description,
      :sponsorship_enabled,
      :sponsorship_tiers,
      :sponsorship_deadline
    ])

    create :create do
      description("创建活动（默认 status=draft）")

      accept([
        :title,
        :research_enabled,
        :research_requirements,
        :enrollment_policy,
        :capacity,
        :registration_deadline,
        :visibility,
        :slug,
        :description,
        :sponsorship_enabled,
        :sponsorship_tiers,
        :sponsorship_deadline
      ])

      # GraphQL 入口不注入 tenant（#104 同款），workspace_id 由入参提供；
      # 内部调用方（fixtures/测试）直接传 tenant 亦可。policy 经
      # MembershipContext 的 argument 回退解析工作台（invitation.ex 同款先例）。
      argument(:workspace_id, :uuid,
        allow_nil?: true,
        description: "目标工作台 ID（GraphQL 入口必传；tenant 已注入时省略）"
      )

      change(set_attribute(:status, :draft))

      # slug 未提供时兜底生成（公开 URL 段；唯一索引防碰撞）
      change(fn changeset, _context ->
        changeset =
          case Ash.Changeset.get_attribute(changeset, :slug) do
            value when is_binary(value) and value != "" ->
              changeset

            _ ->
              suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
              Ash.Changeset.force_change_attribute(changeset, :slug, "e-" <> suffix)
          end

        changeset
      end)

      # slug 单段 URL 约束（公开路由 /events/[slug]；非法字符拒绝）
      change(fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :slug) do
          value when is_binary(value) and value != "" ->
            if Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, value) do
              changeset
            else
              Ash.Changeset.add_error(
                changeset,
                "slug must be a single lowercase URL segment ([a-z0-9-])"
              )
            end

          _ ->
            changeset
        end
      end)

      # workspace_id 由 argument 或 tenant 强制，不接受属性直传
      change(fn changeset, _context ->
        workspace_id = Ash.Changeset.get_argument(changeset, :workspace_id) || changeset.tenant

        if workspace_id do
          changeset
          |> Ash.Changeset.set_tenant(workspace_id)
          |> Ash.Changeset.force_change_attribute(:workspace_id, workspace_id)
        else
          Ash.Changeset.add_error(changeset, "create requires a tenant (workspace_id)")
        end
      end)
    end

    # 编辑活动元数据（E-11 #127）：visibility 可随时双向切换（含 open 后，D9）。
    # status/workflow_run_id/confirmed_count 不在此 accept（状态走专用 action）。
    update :update do
      description("编辑活动元数据（Owner/Admin）")
      require_atomic?(false)

      accept([
        :title,
        :research_enabled,
        :research_requirements,
        :enrollment_policy,
        :capacity,
        :registration_deadline,
        :visibility,
        :slug,
        :description,
        :sponsorship_enabled,
        :sponsorship_tiers,
        :sponsorship_deadline
      ])

      # 强制非原子执行：GraphQL update 走 bulk_update（原子路径）时 policy 的
      # changeset.data 读取会 raise（AtomicChangeset 无原数据）。本函数 change
      # 使 action 原子能力判定失败，回落到带原数据的常规 update 路径。
      change(fn changeset, _context ->
        _ = Ash.Changeset.get_data(changeset, :status)
        changeset
      end)

      # slug 单段 URL 约束（create/update 同规则；非法拒绝）
      change(fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :slug) do
          value when is_binary(value) and value != "" ->
            if Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, value) do
              changeset
            else
              Ash.Changeset.add_error(
                changeset,
                "slug must be a single lowercase URL segment ([a-z0-9-])"
              )
            end

          _ ->
            changeset
        end
      end)
    end

    # ensure_launched 守卫会静默丢弃实例化。提交后发布，订阅方读到 open。
    update :launch do
      description("发布活动：draft → open，发 event.launched 信号")
      require_atomic?(false)
      accept([])

      # DB 级 compare-and-set（复审：并发双 launch 会双信号）——before_action
      # 内条件 UPDATE 抢占 draft→open，后到者 num_rows=0 拒绝。
      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn cs ->
          case Ash.Changeset.get_data(cs, :status) do
            :draft ->
              case status_transition(cs, :open) do
                :ok ->
                  Ash.Changeset.force_change_attribute(cs, :status, :open)

                {:error, :status_race} ->
                  Ash.Changeset.add_error(
                    cs,
                    "launch failed: status changed concurrently, retry on fresh read"
                  )

                {:error, {:database, _} = reason} ->
                  Ash.Changeset.add_error(cs, reason)
              end

            status ->
              Ash.Changeset.add_error(cs, "cannot launch from status=#{status}")
          end
        end)
      end)

      # event.launched 经 SignalEmitter 事务内 outbox 入队（plan 2026-08-14-003
      # Q6）：job 与 open 终态同事务提交，SignalPublishWorker 提交后异步投递——
      # 订阅方读到的必是已提交 open 状态（#1 TOCTOU 由 outbox 结构性解决）。
      change(
        {Cgc2046.Changes.SignalEmitter,
         type: "event.launched", payload: &__MODULE__.launched_payload/2}
      )

      # GO/NO-GO（D3 警告放行）：清单非 ready 记 warning 不阻塞发布，
      # 明细经 GraphQL readiness 查询暴露后台（course.launch 同款，Readiness 统一）。
      change(after_transaction(&Cgc2046.Events.Readiness.warn_unless_ready/3))
    end

    # open → closed：结束活动（手动，或 registration_deadline 到点由
    # EventLifecycleWorker 自动执行）。发 event.ended 信号——E-9 #124 级联：
    # 订阅方 = 教研 run 回收 / 赞助 Event 级自动 ended / 报名窗锁定。
    # 终态不可逆（D4 v1 语义）：closed/cancelled 无恢复 action，恢复路径 =
    # 新建活动。DB 级 compare-and-set 防陈旧/并发双成功（cron 与手动竞态，
    # codex 评审 BLOCKING 4）。
    update :close do
      description("结束活动：open → closed，发 event.ended 信号")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn cs ->
          case Ash.Changeset.get_data(cs, :status) do
            :open ->
              case status_transition(cs, :closed) do
                :ok ->
                  Ash.Changeset.force_change_attribute(cs, :status, :closed)

                {:error, :status_race} ->
                  Ash.Changeset.add_error(
                    cs,
                    "close failed: status changed concurrently, retry on fresh read"
                  )

                {:error, {:database, _} = reason} ->
                  Ash.Changeset.add_error(cs, reason)
              end

            status ->
              Ash.Changeset.add_error(cs, "cannot close from status=#{status}")
          end
        end)
      end)

      # event.ended 经 SignalEmitter 事务内 outbox 入队：job 与事件终态同事务提交，
      # 入队失败回滚可安全重试；CAS 失败路径不到 after_action，不产生孤儿 job。
      change(
        {Cgc2046.Changes.SignalEmitter, type: "event.ended", payload: &__MODULE__.ended_payload/2}
      )
    end

    # open → cancelled：取消活动。同样发 event.ended（D4：closed/cancelled 即 ended）。
    update :cancel do
      description("取消活动：open → cancelled，发 event.ended 信号")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn cs ->
          case Ash.Changeset.get_data(cs, :status) do
            :open ->
              case status_transition(cs, :cancelled) do
                :ok ->
                  Ash.Changeset.force_change_attribute(cs, :status, :cancelled)

                {:error, :status_race} ->
                  Ash.Changeset.add_error(
                    cs,
                    "cancel failed: status changed concurrently, retry on fresh read"
                  )

                {:error, {:database, _} = reason} ->
                  Ash.Changeset.add_error(cs, reason)
              end

            status ->
              Ash.Changeset.add_error(cs, "cannot cancel from status=#{status}")
          end
        end)
      end)

      # event.ended 经 SignalEmitter 事务内 outbox 入队：job 与事件终态同事务提交，
      # 入队失败回滚可安全重试；CAS 失败路径不到 after_action，不产生孤儿 job。
      change(
        {Cgc2046.Changes.SignalEmitter, type: "event.ended", payload: &__MODULE__.ended_payload/2}
      )
    end

    defaults([:read])

    # #14：教研 run 创建后回写产物引用（ResearchInstantiator 内部调用，authorize?: false）。
    # workflow_run_id 是 writable 属性但不在任何公开 action 的 accept——只有本 action 可写。
    update :link_research_run do
      description("回写教研 workflow 产物引用（#39 实例化后）")
      require_atomic?(false)
      accept([:workflow_run_id])
    end

    # #40 展示页：按 id 取活动详情（GraphQL read_one）
    read :get_by_id do
      get_by([:id])
    end

    # E-5 #50 公开宿主页：按 slug 取详情（全局唯一，公开路由无 workspace 前缀）
    read :get_by_slug do
      get_by([:slug])
    end
  end

  # ── 信号 payload（SignalEmitter 契约：fn changeset, record -> map，只组装业务键；
  # idempotency_key / workspace_id 由 emitter 统一注入，plan 2026-08-14-003 Q12）──

  def launched_payload(_changeset, event) do
    %{
      "event_id" => event.id,
      "title" => event.title,
      "research_requirements" => event.research_requirements || %{}
    }
  end

  def ended_payload(_changeset, event), do: %{"event_id" => event.id, "title" => event.title}

  # DB 级 compare-and-set：条件 UPDATE 原子抢占状态迁移（enrollment.expire 同款
  # 纪律）。num_rows=0 → 并发竞态（cron 与手动双拍），拒绝而非双成功双发布。
  # 成功后由调用方 force_change（Ash 后续写同值幂等，返回 record 状态正确）。
  defp status_transition(changeset, to_status) do
    sql = "UPDATE events SET status = $1, updated_at = NOW() WHERE id = $2 AND status = $3"
    id = Ash.Changeset.get_data(changeset, :id)
    from_status = Ash.Changeset.get_data(changeset, :status)

    case Repo.query(sql, [to_string(to_status), Repo.uuid!(id), to_string(from_status)]) do
      {:ok, %{num_rows: 1}} ->
        :ok

      {:ok, %{num_rows: 0}} ->
        {:error, :status_race}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
  end

  postgres do
    table("events")
    repo(Cgc2046.Repo)
  end

  policies do
    # 读取（D9 修订）：成员/平台管理员可读全部；匿名（无 actor）仅可读
    # open + visibility=public（公开发现面，D2 白名单由 field_policies 收窄）。
    policy action_type(:read) do
      authorize_if({Cgc2046.Policies.ActorIsWorkspaceMemberVia, path: [:workspace]})
      authorize_if(Cgc2046.Policies.PlatformAdmin)
      authorize_if(expr(status == :open and visibility == :public))
    end

    # 写操作：Owner/Admin（多角色并集）或平台管理员
    policy action_type([:create, :update]) do
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end
  end

  # D2 公开字段白名单（denylist 式，Ash field_policy 为 AND 语义：:* 恒放行，
  # 敏感字段另立 member-or-admin policy 收窄）。非白名单 = workspace_id /
  # research_enabled / research_requirements / workflow_run_id / capacity /
  # confirmed_count，匿名被筛除。
  field_policies do
    field_policy :* do
      authorize_if(always())
    end

    field_policy [
      :workspace_id,
      :research_enabled,
      :research_requirements,
      :workflow_run_id,
      :capacity,
      :confirmed_count
    ] do
      authorize_if({Cgc2046.Policies.ActorIsWorkspaceMemberVia, path: [:workspace]})
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end
  end

  graphql do
    type(:event)

    queries do
      list(:list_events, :read, description: "工作台的活动列表（#40 展示页）")
      read_one(:get_event, :get_by_id, description: "按 id 获取活动（#40）")
      read_one(:get_event_by_slug, :get_by_slug, description: "按 slug 获取（E-5 公开宿主页）")
    end

    mutations do
      create(:create_event, :create)
      update(:update_event, :update)
      update(:launch_event, :launch)
      update(:close_event, :close)
      update(:cancel_event, :cancel)
    end
  end

  admin do
    # #113 ops 面优化：导航分组 + 列表列裁剪（默认全列横向爆炸；敏感/超大字段不列出）
    resource_group(:events)
    label_field(:title)

    table_columns([
      :id,
      :workspace_id,
      :title,
      :status,
      :capacity,
      :confirmed_count,
      :registration_deadline,
      :inserted_at
    ])
  end
end
