defmodule Cgc2046.Payments.Order do
  @moduledoc """
  支付订单：座位保留型限时订单（默认 2 小时），微信/支付宝收款，在线全额
  退款（退款 = 取消报名，ADR-0007）。

  状态机（全部迁移经 DB 级 CAS：before_action 内条件 UPDATE + num_rows 守卫，
  非法迁移 → :already_processed 域错误，报名 claim_pending 同款纪律）：

      pending ──mark_paid──▶ paid ──start_refund──▶ refunding ──refund_succeeded──▶ refunded
        │                      │                        │  ▲
        ├──cancel──▶ cancelled │                        │  └──refund_failed──▶ refund_failed
        └──expire──▶ expired ──┘                        │         ▲（refunding → refund_failed）
                               ├──start_refund（迟到支付自动退款）└──retry_refund──▶ refunding
                               └──forfeit──▶ forfeited（no-show 结算终态，不退，R9/KTD7）

  并发不变量由数据库承担（报名/赞助同款纪律）：
  - R11「同一 enrollment 至多一笔非终态订单」：payments_orders 上的部分唯一索引
    （enrollment_id WHERE status IN ('pending','paid','refunding','refund_failed')）。
    索引同时守卫 CAS 迁移路径：expired 单进入 refunding 时若已存在新非终态单，
    条件 UPDATE 触发唯一冲突 → 迁移失败回滚；
  - 状态迁移原子性：每条迁移一条 `UPDATE ... WHERE id = $ AND status IN (源状态)`
    条件 UPDATE，num_rows=0 即非法迁移。

  U2 金额源（KTD1，#749 收紧）：下单与换渠道按 `order_kind` 分派——押金单跳过
  定价档位解析，押金金额以**活动现值**（`events.deposit_amount_cents`）为权威
  合成 `%{"name" => "押金", "amount_cents" => …}` 形状 tier；`submission_payload`
  不参与金额（历史预埋/毒化键天然免疫）。换渠道沿被替换订单的 `order_kind` 与
  `tier_snapshot`（不重新读 Event，改价不追溯在途单）。定价单维持现状
  （`resolve_tier/2` 取当前档位）。现值金额非正 fail-closed 报
  `order_deposit_amount_missing`，绝不以 nil/零金额调渠道。

  押金同意门（#727）：`create_for_enrollment` 对押金单要求显式同意
  （`deposit_consent: true`），缺失/非 true 一律拒（`order_deposit_consent_required`），
  且校验在作废旧 pending 单与调渠道之前——拒单零副作用。判据是后端
  `order_kind/2`，不认客户端的押金识别（#686/#696 的前端三面披露门是引导，
  本闸才是权威）。非押金单忽略该参数。

  同意留痕（#750，#510 同形）：门通过即落 `deposit_consent_at` +
  `deposit_terms_version`（不可逆没收动作的事后举证依据）。换渠道沿旧单承诺
  不重复要同意，但要求旧单有留痕——存量部署前押金单无留痕时
  `replace_provider` 拒（`order_deposit_consent_missing`，fail-safe；窗口有界：
  expire_at 封顶），重新创单走同意门补留痕；留痕齐全时新单继承旧单的同意
  时点与条款版本（同一承诺沿单延续）。

  U1 骨架：全部动作均为内部路径（worker/域服务 authorize?: false 调用），
  GraphQL/管理面尚未暴露；policy 占位为 actor 在场（拒匿名），面向用户的正式
  授权（学员本人 / Owner/Admin / 平台管理员）随 U5/U9 暴露时细化。
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Payments

  # 押金条款版本（#750，#510 terms_version 同形）：随同意时点落列，改版披露
  # 文案时递进新值，审计可回答「同意的是哪一版」。须先于 prepare_* 使用点定义。
  @deposit_terms_version "2026-09-deposit"

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false
    )

    attribute(:enrollment_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: true
    )

    attribute(:order_kind, :atom,
      allow_nil?: false,
      default: :enrollment,
      public?: true,
      writable?: true,
      constraints: [one_of: [:enrollment, :deposit]]
    )

    attribute(:provider, :atom,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [
        one_of: [:wechat_jsapi, :wechat_native, :alipay_page, :alipay_wap, :alipay_qr]
      ]
    )

    attribute(:out_trade_no, :string,
      allow_nil?: false,
      public?: true,
      writable?: true
    )

    attribute(:transaction_id, :string, public?: true, writable?: false)

    attribute(:amount_cents, :integer,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [min: 1]
    )

    attribute(:tier_snapshot, :map,
      allow_nil?: false,
      default: %{},
      public?: true,
      writable?: true
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :pending,
      public?: true,
      writable?: false,
      constraints: [
        one_of: [
          :pending,
          :paid,
          :refunding,
          :refunded,
          :refund_failed,
          :cancelled,
          :expired,
          :forfeited
        ]
      ]
    )

    # 押金同意留痕（#750，#510 同形）：押金单创建时落同意时点与条款版本；
    # 非押金单/存量部署前押金单为 NULL（后者 replace_provider 拒换渠道）。
    # writable?: false——只由 prepare 内部 force_change 写入，不开放任何入参面。
    attribute(:deposit_consent_at, :utc_datetime,
      public?: true,
      writable?: false
    )

    attribute(:deposit_terms_version, :string,
      public?: true,
      writable?: false
    )

    attribute(:expire_at, :utc_datetime, allow_nil?: false, public?: true, writable?: true)
    attribute(:refunded_at, :utc_datetime, public?: true, writable?: false)
    attribute(:cancel_reason, :string, public?: true, writable?: false)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)
    global?(true)
  end

  relationships do
    belongs_to(:workspace, Cgc2046.Accounts.Workspace, define_attribute?: false)
    belongs_to(:enrollment, Cgc2046.Admission.Enrollment, define_attribute?: false)
  end

  identities do
    identity(:unique_out_trade_no, [:out_trade_no])

    identity :unique_active_order, [:enrollment_id] do
      where(expr(status in [:pending, :paid, :refunding, :refund_failed]))
    end
  end

  # 管理列表信息面（R24/U10）：tier 快照名 + 报名人/报名态（enrollment 信息
  # 以计算字段下钻——Enrollment 无 GraphQL 类型（generate_object? false），
  # 不能走关系字段暴露）。
  calculations do
    calculate :tier_name, :string do
      public?(true)
      description("下单时档位快照名（R3 改价不追溯）")
      calculation(expr(tier_snapshot["name"]))
    end

    calculate :enrollment_status, :atom do
      public?(true)
      description("关联报名当前状态")

      constraints(
        one_of: [:pending, :payment_pending, :confirmed, :rejected, :expired, :cancelled]
      )

      calculation(expr(enrollment.status))
    end

    calculate :learner_email, :string do
      public?(true)
      description("报名人邮箱（管理面识别付款人）")
      calculation(expr(enrollment.user.email))
    end

    # U4 活动维度（KTD2）：enrollment 无 GraphQL 对象类型（generate_object?
    # false），关系路径筛选不可用——计算字段进 OrderFilterInput 是本仓库的
    # 惯用替代（同 tierName/enrollmentStatus 先例）。
    calculate :event_id, :uuid do
      public?(true)
      description("关联报名所属 Event（KTD2：订单按活动筛选）")
      calculation(expr(enrollment.event_id))
    end

    calculate :course_id, :uuid do
      public?(true)
      description("关联报名所属 Course（KTD2：订单按课程筛选）")
      calculation(expr(enrollment.course_id))
    end

    # U8（R10）：已售档判定——编辑面比较订单 tier 快照 id 与档位草稿（删除/
    # 改价已售档时警告；快照语义保证已付订单金额不受影响）。string 而非 uuid：
    # PriceTier.id 是前端 crypto.randomUUID() 或任意非空串，uuid cast 会拒。
    calculate :tier_id, :string do
      public?(true)
      description("下单时档位快照 id（U8 已售档守卫）")
      calculation(expr(tier_snapshot["id"]))
    end
  end

  actions do
    defaults([:read])

    read :my_orders do
      description("当前用户（报名者本人）的订单列表（R14 支付面）")
      filter(expr(enrollment.user_id == ^actor(:id)))
      pagination(keyset?: true, default_limit: 50)
    end

    read :get_by_id do
      description("按 id 取订单（轮询轻量面，仅本人可见）")
      get_by([:id])
    end

    # R24 管理列表：workspace 订单全量（Owner/Admin 本租户 + PlatformAdmin 跨租户
    # 只读）。workspace_id 走显式 argument + action filter（for_read 时即并入
    # query.filter，OwnerOrAdmin policy 经 resolve_workspace_id 从 filter 提取）。
    read :workspace_orders do
      description("工作台订单列表（R24 管理面；金额/状态/档位/报名人信息）")
      argument(:workspace_id, :uuid, allow_nil?: false, public?: true)
      filter(expr(workspace_id == ^arg(:workspace_id)))
      prepare(build(sort: [inserted_at: :desc]))
      pagination(keyset?: true, default_limit: 50)
    end

    create :create do
      description("创建 pending 订单；U1 骨架从 enrollment 派生租户，定价/占位随 U2/U3 落地")

      accept([
        :enrollment_id,
        :order_kind,
        :provider,
        :out_trade_no,
        :amount_cents,
        :tier_snapshot,
        :expire_at
      ])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_create/1)
      end)
    end

    # ── U5 下单链路（KTD9 GraphQL 契约）────────────────────────────────────

    create :create_for_enrollment do
      description("报名者下单：payment_pending 报名 → pending 订单 + 渠道凭据（R5/R6/R13）")

      accept([])

      argument(:enrollment_id, :uuid,
        allow_nil?: false,
        description: "目标报名（须为本人 payment_pending 报名）"
      )

      argument(:provider, :atom,
        allow_nil?: false,
        constraints: [
          one_of: [:wechat_jsapi, :wechat_native, :alipay_page, :alipay_wap, :alipay_qr]
        ],
        description: "支付渠道"
      )

      # 押金同意门下沉（#727，路线 B）：押金单（order_kind=deposit，判据是
      # **后端**的 order_kind/2，不认客户端识别）必须显式同意，否则拒单。
      # 非押金单忽略本参数——定价/免费单零改动。可选布尔而非 Boolean!：
      # 老客户端/非押金调用方拿到的是可翻译的业务错误码
      # （order_deposit_consent_required），不是 GraphQL 校验错（同 #510
      # ageConfirmed 的形状）。
      argument(:deposit_consent, :boolean,
        allow_nil?: true,
        description: "确认已阅读并同意押金条款（仅押金单需要；非押金单忽略）"
      )

      # unique_active_order 部分索引冲突兜底转业务错误（幂等设计见
      # prepare_create_for_enrollment：锁内先废旧单，正常路径不再撞索引）
      error_handler({__MODULE__, :handle_create_error, []})

      metadata :credential, :map do
        description("渠道支付凭据（jsapi 调起参数 / 二维码链接 / 跳转 URL）")
      end

      change(fn changeset, _context ->
        changeset
        |> Ash.Changeset.before_action(&prepare_create_for_enrollment/1)
        |> attach_credential()
      end)
    end

    create :replace_provider do
      description("换渠道：旧 pending 单 cancelled + 新单（新 out_trade_no），R11")

      accept([])

      argument(:order_id, :uuid, allow_nil?: false, description: "待替换的旧订单（本人 pending 单）")

      argument(:provider, :atom,
        allow_nil?: false,
        constraints: [
          one_of: [:wechat_jsapi, :wechat_native, :alipay_page, :alipay_wap, :alipay_qr]
        ]
      )

      # 同 create_for_enrollment：换渠道新单撞 unique_active_order（并发双换）
      # 转 order_duplicate_active（F1）
      error_handler({__MODULE__, :handle_create_error, []})

      metadata :credential, :map do
        description("新渠道支付凭据")
      end

      change(fn changeset, _context ->
        changeset
        |> Ash.Changeset.before_action(&prepare_replace_provider/1)
        |> attach_credential()
      end)
    end

    update :cancel_pending do
      description("报名者取消自己的 pending 订单（报名保持 payment_pending 可再下单，R12）")

      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_cancel_pending/1)
      end)
    end

    update :mark_paid do
      description("支付成功：pending → paid（回写渠道交易号）")
      require_atomic?(false)
      accept([])
      argument(:transaction_id, :string, allow_nil?: false)

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_mark_paid/1)
      end)

      # R7：支付成功信号（落账 worker 驱动，CAS 成功才入队）
      change(
        {Cgc2046.Workflows.SignalEmitter,
         type: "order.paid", payload: &__MODULE__.paid_signal_payload/2}
      )
    end

    update :cancel do
      description("未支付取消：pending → cancelled（用户取消/换渠道/批量作废共用）")
      require_atomic?(false)
      accept([])
      argument(:cancel_reason, :string, allow_nil?: true)

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_cancel/1)
      end)
    end

    update :expire do
      description("内部扫描把过期 pending 单转 expired（expire_at 过点由调用方判定），同事务联动报名过期 + 名额释放（R8/F2）")

      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_expire/1)
      end)
    end

    update :start_refund do
      description(
        "发起退款：paid/expired/cancelled → refunding（expired/cancelled 为迟到支付自动退款路径，本地作废不关渠道单）"
      )

      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_start_refund/1)
      end)

      # #845 D1：入队归 Order，同事务恰好一次；CAS 失败无 after_action 不产生孤儿 job
      change(fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn cs, refunding ->
          enqueue_refund_job(cs, refunding)
        end)
      end)
    end

    # no-show 结算（R9/KTD7）：paid → forfeited，终态且不退（押金留作平台收入）。
    # 内部专用：仅 DepositForfeitWorker 以 authorize?: false 调用，不加 actor
    # 授权 policy（start_refund 同款先例）；num_rows=0 → :already_processed
    # 幂等 no-op（他路退款已接管）。
    update :forfeit do
      description("no-show 结算：paid → forfeited（终态不退；内部专用，worker authorize?: false）")

      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_forfeit/1)
      end)
    end

    update :refund_succeeded do
      description("退款成功：refunding → refunded，落 refunded_at")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_refund_succeeded/1)
      end)
    end

    update :mark_refund_failed do
      description("退款失败：refunding → refund_failed（可经 retry_refund 重试）")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_mark_refund_failed/1)
      end)
    end

    update :retry_refund do
      description("管理员重试退款：refund_failed → refunding 重入退款链（R17）")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_retry_refund/1)
      end)

      change(fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn cs, refunding ->
          enqueue_refund_job(cs, refunding)
        end)
      end)

      change(
        {Cgc2046.Accounts.Changes.LogAdminAction,
         action: :order_refund_retry,
         target_type: :order,
         metadata: &__MODULE__.refund_log_metadata/2}
      )
    end

    # 管理员单笔退款（R15）：paid → refunding + 入队渠道退款。closed 后单笔仍可
    # （不校验 Event status，plan U9-4）；expired 迟到退款走内部 start_refund
    # （U7 自动退款链），不经本 action。
    # #545 错没收人工救济：forfeited → refunding 重入退款链。仅 PlatformAdmin
    # （与 refund/retry_refund 的 OwnerOrAdmin + PlatformAdmin 区分——没收是
    # 平台裁决，救济同权）；迟到场（DepositForfeitWorker 已结算后参与者到场
    # 有正当理由）、ends_at 误改修复后的人工核实等场景。退款金额 = 押金全额
    # 原路退回（PaymentRefundWorker 与 refund 同链，查单幂等不重复退）。
    update :unforfeit do
      description("平台管理员补救：forfeited → refunding 重入退款链（错没收人工救济，#545）")
      require_atomic?(false)
      accept([])

      # 救济理由必填（审计可回答「为什么退」；空理由的补救不可审计）
      argument(:reason, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500],
        description: "补救理由（必填，进审计）"
      )

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_unforfeit/1)
      end)

      change(fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn cs, refunding ->
          enqueue_refund_job(cs, refunding)
        end)
      end)

      change(
        {Cgc2046.Accounts.Changes.LogAdminAction,
         action: :order_unforfeit,
         target_type: :order,
         metadata: &__MODULE__.unforfeit_log_metadata/2}
      )
    end

    # 管理员单笔退款（R15）：paid → refunding + 入队渠道退款。closed 后单笔仍可
    # （不校验 Event status，plan U9-4）；expired 迟到退款走内部 start_refund
    # （U7 自动退款链），不经本 action。
    update :refund do
      description("管理员单笔全额退款：paid → refunding 并入队渠道退款（退款即取消，ADR-0007）")

      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_refund/1)
      end)

      change(fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn cs, refunding ->
          enqueue_refund_job(cs, refunding)
        end)
      end)

      change(
        {Cgc2046.Accounts.Changes.LogAdminAction,
         action: :order_refund, target_type: :order, metadata: &__MODULE__.refund_log_metadata/2}
      )
    end

    # R24 收款统计（generic action）：已收 = paid 总额；待收 = pending 且未过
    # expire_at（过期单由 U8 扫描释放，不计待收）；已退 = refunded 总额；
    # 退款失败待处理 = refund_failed 总额（U1-R1 可观测，提示管理员重试）；
    # no-show 没收 = forfeited 总额（R9/KD4：未到场不退、对账可导出口径）。
    # 金额分。授权经 policy（OwnerOrAdmin 从 ActionInput 提取 workspace_id，
    # MembershipContext 场景5），SQL 只算数不涉权。
    action :workspace_payment_stats, :map do
      description("工作台收款统计（R24/U4）：已收/待收/已退；可选 eventId/courseId 收敛到单活动口径")
      argument(:workspace_id, :uuid, allow_nil?: false, public?: true)
      argument(:event_id, :uuid, allow_nil?: true, public?: true)
      argument(:course_id, :uuid, allow_nil?: true, public?: true)

      constraints(
        fields: [
          collected_cents: [type: :integer, allow_nil?: false],
          pending_cents: [type: :integer, allow_nil?: false],
          refunded_cents: [type: :integer, allow_nil?: false],
          refund_failed_cents: [type: :integer, allow_nil?: false],
          forfeited_cents: [type: :integer, allow_nil?: false]
        ]
      )

      run(fn input, _ctx ->
        # U4（KTD3）+ U5（R19）：可选 offering 维度收敛为单 JOIN enrollments——
        # 按入参 kind 选择谓词（event_id 只匹配 event 侧，course_id 只匹配
        # course 侧），杜绝把合法 course UUID 传入 eventId 时的跨类误归并
        # （PR⑤ cross-model review peer #2）；四数形状与工作区口径同源（同一
        # 状态集分桶）；授权仍由 workspace_id 参数解析。可选参数经 Map.get
        # （GraphQL 未传时无该键）；双参同传时 event_id 优先（与原 cond 分叉序一致）。
        {offering_join, extra_params} =
          cond do
            event_id = Map.get(input.arguments, :event_id) ->
              {"JOIN enrollments e ON e.id = o.enrollment_id AND e.event_id = $2",
               [Cgc2046.Repo.uuid!(event_id)]}

            course_id = Map.get(input.arguments, :course_id) ->
              {"JOIN enrollments e ON e.id = o.enrollment_id AND e.course_id = $2",
               [Cgc2046.Repo.uuid!(course_id)]}

            true ->
              {"", []}
          end

        sql = """
        SELECT
          COALESCE(SUM(o.amount_cents) FILTER (WHERE o.status = 'paid'), 0)::bigint,
          COALESCE(SUM(o.amount_cents) FILTER (WHERE o.status = 'pending' AND o.expire_at > NOW()), 0)::bigint,
          COALESCE(SUM(o.amount_cents) FILTER (WHERE o.status = 'refunded'), 0)::bigint,
          COALESCE(SUM(o.amount_cents) FILTER (WHERE o.status = 'refund_failed'), 0)::bigint,
          COALESCE(SUM(o.amount_cents) FILTER (WHERE o.status = 'forfeited'), 0)::bigint
        FROM payments_orders o
        #{offering_join}
        WHERE o.workspace_id = $1
        """

        case Cgc2046.Repo.query(
               sql,
               [Cgc2046.Repo.uuid!(input.arguments.workspace_id)] ++ extra_params
             ) do
          {:ok, %{rows: [[collected, pending, refunded, refund_failed, forfeited]]}} ->
            {:ok,
             %{
               collected_cents: collected || 0,
               pending_cents: pending || 0,
               refunded_cents: refunded || 0,
               refund_failed_cents: refund_failed || 0,
               forfeited_cents: forfeited || 0
             }}

          {:error, reason} ->
            {:error, {:database, reason}}
        end
      end)
    end
  end

  postgres do
    table("payments_orders")
    repo(Cgc2046.Repo)

    # #724：FK 的 ON DELETE 契约显式化——对齐 baseline delete_all（DB 实测
    # 两列 confdeltype=c）；无 DDL，仅 snapshot 追平。
    references do
      reference(:workspace, on_delete: :delete)
      reference(:enrollment, on_delete: :delete)
    end

    identity_wheres_to_sql(
      unique_active_order: "status IN ('pending', 'paid', 'refunding', 'refund_failed')"
    )
  end

  policies do
    # 学员读面（my_orders / orderStatus 轮询）：仅报名者本人（关系下推过滤）。
    # 管理读面（workspace_orders / stats）另立 policy——学员 action 不给管理面
    # 走 expr 过滤的空列表语义，成员调用管理查询是真 403。
    policy action([:my_orders, :get_by_id]) do
      authorize_if(expr(enrollment.user_id == ^actor(:id)))
    end

    # 默认 :read(refundOrder 等 update mutation 的 ash_graphql 预读走此 action):
    # 学员本人（expr 下推）+ Owner/Admin / PlatformAdmin 管理可见（R19/R24）。
    # 学员专用面仍是 my_orders / get_by_id 专用 action，互不影响。
    policy action(:read) do
      authorize_if(expr(enrollment.user_id == ^actor(:id)))
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    # 管理列表（R24）：Owner/Admin 本租户；PlatformAdmin 跨租户只读（R19）。
    # workspace_id 经 action filter 并入 query.filter，OwnerOrAdmin 从 filter
    # 提取（MembershipContext query 场景）。
    policy action(:workspace_orders) do
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    # 收款统计（R24）：Owner/Admin 本租户；PlatformAdmin 跨租户只读（R19）。
    policy action(:workspace_payment_stats) do
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    # 管理员单笔退款/重试（R15/R19）：Workspace Owner/Admin；PlatformAdmin
    # 持退款兜底权（资金主体）。
    policy action([:refund, :retry_refund]) do
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    # #545 错没收救济：仅 PlatformAdmin（issue 拍板）。不并入上一组——工作台
    # Owner/Admin 不持「推翻平台没收裁决」的权力。
    policy action(:unforfeit) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    # 下单/换渠道/取消：actor 在场（匿名拒绝），本人校验经 prepare 内
    # enrollment.user_id 比对完成（跨资源归属，policy expr 无法在 create 上表达）。
    policy action([:create_for_enrollment, :replace_provider, :cancel_pending]) do
      authorize_if(actor_present())
    end
  end

  graphql do
    type(:order)

    queries do
      list(:my_orders, :my_orders, description: "当前用户订单列表（R14）")
      read_one(:order_status, :get_by_id, description: "订单状态轮询（2s×30s 轻量面，R14）")
      list(:workspace_orders, :workspace_orders, description: "工作台订单列表（R24 管理面）")
      action(:workspace_payment_stats, :workspace_payment_stats)
    end

    mutations do
      create(:create_order, :create_for_enrollment)
      create(:replace_provider, :replace_provider)
      update(:cancel_order, :cancel_pending)
      # refund/retry_refund 的 web 面入口改为手写两段确认 mutation
      # （graphql_schema.ex + Cgc2046Web.PaymentConfirmation，复用 Mcp.PendingOperation）
    end
  end

  # ── 建单（U1：从 enrollment 派生租户；定价/占位语义随 U2/U3 落地）────────

  defp prepare_create(changeset) do
    enrollment_id = Ash.Changeset.get_attribute(changeset, :enrollment_id)

    with {:ok, workspace_id} <- enrollment_workspace(enrollment_id),
         {:ok, tenant} <- resolve_tenant(changeset.tenant, workspace_id) do
      Ash.Changeset.force_change_attribute(changeset, :workspace_id, tenant)
    else
      {:error, reason} -> add_domain_error(changeset, reason)
    end
  end

  # ⑨ 端口收编（ADR-0010 批次4）：SQL 原样在 Admission 侧，本模块只委托
  defp enrollment_workspace(id), do: Cgc2046.Admission.Enrollment.workspace_id_for_order(id)

  # 渠道凭据 → 记录 metadata（AshGraphql mutation payload 的 credential 字段）
  defp attach_credential(changeset) do
    Ash.Changeset.after_action(changeset, fn cs, record ->
      case cs.context[:payment_credential] do
        nil -> {:ok, record}
        credential -> {:ok, Ash.Resource.set_metadata(record, %{credential: credential})}
      end
    end)
  end

  # GraphQL 入口不注入 tenant（nil 时从 enrollment 派生）；显式传错 tenant 仍拒绝
  # （防跨 workspace 越权，报名同款）
  defp resolve_tenant(nil, workspace_id), do: {:ok, workspace_id}
  defp resolve_tenant(tenant, tenant), do: {:ok, tenant}
  defp resolve_tenant(_, _), do: {:error, :target_tenant_mismatch}

  # ── U5 下单链路 ────────────────────────────────────────────────────────────

  # 下单前校验链：本人 payment_pending 报名 → 目标定价 → 押金同意门 → 档位快照
  # → 截止时间 → 渠道下单（同事务，失败整单回滚：无凭据无订单）。档位取
  # Event/Course 当前配置（R3：下单时快照，改价/删档不追溯已生成订单；档位在
  # 下单前被删/过期则拒绝）。
  #
  # 顺序纪律（#727）：校验先于副作用——门排在 `discard_stale_pending_order` 与
  # `channel_create_payment` 之前。渠道下单是事务外副作用（真会向渠道下 prepay
  # 单），门必须先于它；排在废旧单之前是 validate-before-mutate 纪律（action 事务
  # 回滚本会撤销废旧单，但正确性不该依赖回滚）。未带 consent 的老客户端重进支付页：
  # 拒单、不新增订单、已有 pending 单原样存活。
  defp prepare_create_for_enrollment(changeset) do
    actor = changeset.context[:private][:actor]
    enrollment_id = Ash.Changeset.get_argument(changeset, :enrollment_id)
    provider = Ash.Changeset.get_argument(changeset, :provider)

    # out_trade_no 单点生成：先定号再传渠道与落库——两处分别生成会导致
    # 「渠道单号 ≠ 库内单号」（真实验收实证：支付回调按渠道单号查库必 404，
    # 形成渠道有我无孤儿单）。故先生成，channel_create_payment 与 force_change 共用。
    out_trade_no = generate_out_trade_no()

    with {:ok, enrollment} <- load_enrollment(enrollment_id),
         :ok <- enrollee_only(enrollment, actor),
         :ok <- payment_pending_only(enrollment),
         {:ok, target} <- load_target(enrollment),
         :ok <- deposit_consent_gate(changeset, enrollment, target),
         # 幂等下单（#405）：重进支付页在锁内废掉该报名的现有 pending 单
         # （cancelled/reenter_refresh，审计留痕），腾出唯一索引窗口再开新单——
         # 不再向用户抛 order_duplicate_active 死循环。渠道侧旧 prepay 单自然
         # 过期，支付回调按新单号路由。
         :ok <- discard_stale_pending_order(enrollment.id),
         {:ok, tier} <- resolve_order_amount(enrollment, target),
         {:ok, expire_at} <- order_expire_at(target),
         {:ok, credential} <- channel_create_payment(provider, enrollment, tier, out_trade_no) do
      # 同意留痕（#750）：门通过即落同意事实（时点 + 条款版本，#510 同形）——
      # 押金没收（no-show forfeit）是不可逆资金动作，事后可举证。非押金单不落。
      {consent_at, consent_terms} =
        if order_kind(enrollment, target) == :deposit,
          do: {DateTime.utc_now() |> DateTime.truncate(:second), @deposit_terms_version},
          else: {nil, nil}

      changeset
      |> Ash.Changeset.force_change_attribute(:workspace_id, enrollment.workspace_id)
      |> Ash.Changeset.force_change_attribute(:enrollment_id, enrollment.id)
      |> Ash.Changeset.force_change_attribute(:order_kind, order_kind(enrollment, target))
      |> Ash.Changeset.force_change_attribute(:provider, provider)
      |> Ash.Changeset.force_change_attribute(:out_trade_no, out_trade_no)
      |> Ash.Changeset.force_change_attribute(:amount_cents, tier["amount_cents"])
      |> Ash.Changeset.force_change_attribute(:tier_snapshot, tier)
      |> Ash.Changeset.force_change_attribute(:expire_at, expire_at)
      |> Ash.Changeset.force_change_attribute(:deposit_consent_at, consent_at)
      |> Ash.Changeset.force_change_attribute(:deposit_terms_version, consent_terms)
      |> Ash.Changeset.put_context(:payment_credential, credential)
    else
      {:error, reason} -> add_domain_error(changeset, reason)
    end
  end

  # 换渠道（R11）：旧单 CAS pending→cancelled（cancel_reason=provider_switch）后
  # 走同一下单链（新 out_trade_no + 新凭据 + 新截止窗）。并发双换由旧单 CAS
  # num_rows=0 裁决（第二笔被拒），部分唯一索引兜底。
  defp prepare_replace_provider(changeset) do
    actor = changeset.context[:private][:actor]
    order_id = Ash.Changeset.get_argument(changeset, :order_id)
    provider = Ash.Changeset.get_argument(changeset, :provider)

    out_trade_no = generate_out_trade_no()

    with {:ok, old_order} <- load_order(order_id),
         {:ok, enrollment} <- load_enrollment(old_order.enrollment_id),
         :ok <- enrollee_only(enrollment, actor),
         {:ok, target} <- load_target(enrollment),
         # 同意事实校验（#750/F-05）：押金单沿旧单承诺换渠道的前提是旧单有
         # 同意留痕——存量部署前押金单无留痕（窗口有界：expire_at 封顶），
         # 拒换渠道 fail-safe；重新创单走同意门补留痕。新单继承旧单的同意
         # 时点与条款版本（同一承诺沿单延续，不产生新的同意时点）。
         :ok <- deposit_consent_inheritable?(old_order),
         {:ok, tier} <- resolve_replaced_amount(old_order, enrollment, target),
         {:ok, expire_at} <- order_expire_at(target),
         {:ok, credential} <- channel_create_payment(provider, enrollment, tier, out_trade_no),
         :ok <- cancel_old_order(order_id) do
      changeset
      |> Ash.Changeset.force_change_attribute(:workspace_id, enrollment.workspace_id)
      |> Ash.Changeset.force_change_attribute(:enrollment_id, enrollment.id)
      # order_kind 与金额源同源（见 resolve_replaced_amount/3）：换渠道继承被替换
      # 订单的口径，不按 Event 现状重算——避免「押金金额 + enrollment 标签」这类
      # 自相矛盾的单（标签是结算/统计法则的键，KTD7）。
      |> Ash.Changeset.force_change_attribute(:order_kind, old_order.order_kind)
      |> Ash.Changeset.force_change_attribute(:provider, provider)
      |> Ash.Changeset.force_change_attribute(:out_trade_no, out_trade_no)
      |> Ash.Changeset.force_change_attribute(:amount_cents, tier["amount_cents"])
      |> Ash.Changeset.force_change_attribute(:tier_snapshot, tier)
      |> Ash.Changeset.force_change_attribute(:expire_at, expire_at)
      |> Ash.Changeset.force_change_attribute(
        :deposit_consent_at,
        old_order.deposit_consent_at
      )
      |> Ash.Changeset.force_change_attribute(
        :deposit_terms_version,
        old_order.deposit_terms_version
      )
      |> Ash.Changeset.put_context(:payment_credential, credential)
    else
      {:error, reason} -> add_domain_error(changeset, reason)
    end
  end

  # 用户取消 pending 单（R12）：本人校验 + CAS；报名保持 payment_pending。
  defp prepare_cancel_pending(changeset) do
    actor = changeset.context[:private][:actor]

    with {:ok, enrollment} <- load_enrollment(changeset.data.enrollment_id),
         :ok <- enrollee_only(enrollment, actor) do
      case claim(changeset, [:pending], "status = 'cancelled', cancel_reason = $1", [
             "user_cancelled"
           ]) do
        {:ok, changeset} ->
          changeset
          |> Ash.Changeset.force_change_attribute(:status, :cancelled)
          |> Ash.Changeset.force_change_attribute(:cancel_reason, "user_cancelled")

        {:error, changeset} ->
          changeset
      end
    else
      {:error, reason} -> add_domain_error(changeset, reason)
    end
  end

  # review F5：FOR UPDATE 行锁序列化下单与批量免缴的竞态——锁内重读 status，
  # 免缴事务先提交则此处读到 confirmed 拒单；下单先持锁则批量免缴 CAS 等待
  # 后跳过该笔（num_rows=0），不再出现「已免缴确认后仍插入 pending 单」。
  # before_action 运行在 action 事务内，行锁存活到 insert 提交。
  # ⑨ 端口收编（ADR-0010 批次4）：FOR UPDATE SQL 原样在 Admission 侧。
  # 锁生命周期零变化——before_action 运行在 action 事务内，行锁仍存活到
  # 调用方（本模块）事务提交。
  defp load_enrollment(id), do: Cgc2046.Admission.Enrollment.lock_for_order(id)

  # 读被替换订单：order_kind + tier_snapshot 为换渠道金额源（U2/KTD1：押金单
  # 按原单快照换渠道，不重新读 Event）。
  defp load_order(id) when is_binary(id) do
    sql = """
    SELECT id, enrollment_id, provider, status, amount_cents, order_kind, tier_snapshot,
           deposit_consent_at, deposit_terms_version
    FROM payments_orders WHERE id = $1
    """

    case Cgc2046.Repo.query(sql, [Cgc2046.Repo.uuid!(id)]) do
      {:ok,
       %{
         rows: [
           [
             id,
             enrollment_id,
             _provider,
             status,
             amount_cents,
             order_kind,
             snapshot,
             deposit_consent_at,
             deposit_terms_version
           ]
         ]
       }} ->
        {:ok,
         %{
           id: Ecto.UUID.load!(id),
           enrollment_id: Ecto.UUID.load!(enrollment_id),
           status: existing_atom(status),
           amount_cents: amount_cents,
           order_kind: existing_atom(order_kind),
           tier_snapshot: snapshot,
           # 换渠道的同意事实继承源（#750）：NaiveDateTime（无时区解码）与
           # order_expire_at 同款归一
           deposit_consent_at:
             deposit_consent_at &&
               DateTime.from_naive!(deposit_consent_at, "Etc/UTC"),
           deposit_terms_version: deposit_terms_version
         }}

      {:ok, %{rows: []}} ->
        {:error, :order_not_found}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
  end

  defp load_order(_id), do: {:error, :order_required}

  # 报名人本人（不泄露存在性：他人一律 :enrollment_not_found）
  defp enrollee_only(%{user_id: user_id}, %{id: actor_id}) when user_id == actor_id, do: :ok
  defp enrollee_only(_enrollment, _actor), do: {:error, :enrollment_not_found}

  defp payment_pending_only(%{status: :payment_pending}), do: :ok

  defp payment_pending_only(%{status: :confirmed}),
    do: {:error, :not_payment_pending}

  defp payment_pending_only(%{status: :pending}),
    do: {:error, :not_payment_pending}

  defp payment_pending_only(_enrollment), do: {:error, :not_payment_pending}

  # 目标定价面（Event/Course 二选一，同 enrollment 目标规则）
  defp load_target(%{event_id: event_id}) when is_binary(event_id),
    do: load_target_row("events", event_id)

  defp load_target(%{course_id: course_id}) when is_binary(course_id),
    do: load_target_row("courses", course_id)

  defp load_target(_enrollment), do: {:error, :enrollment_required}

  # 押金单 tier 快照的展示名：管理面 tier_name、渠道订单 subject（微信/支付宝
  # payment_description/payment_subject）、通知 receipt_data 同源读此名。
  @deposit_tier_name "押金"

  # 换渠道的同意事实校验（#750/F-05）：押金单必须有同意留痕才可沿旧单承诺
  # 换渠道。存量部署前押金单无留痕——拒（fail-safe），用户重新创单走同意门
  # 补留痕；窗口有界（expire_at 封顶，最长 2h）。定价单无此约束。
  defp deposit_consent_inheritable?(%{order_kind: :deposit, deposit_consent_at: nil}),
    do: {:error, :deposit_consent_missing}

  defp deposit_consent_inheritable?(_order), do: :ok

  defp load_target_row(table, id) do
    # 押金金额以活动现值为权威（#749）：events 带 deposit_amount_cents 列，
    # courses 无押金语义补常量 nil（同 deposit_enabled 的分支写法）
    deposit_columns =
      if table == "events",
        do: ", COALESCE(deposit_enabled, false), deposit_amount_cents",
        else: ", false, NULL"

    case Cgc2046.Repo.query(
           "SELECT pricing_enabled, price_tiers, registration_deadline#{deposit_columns} FROM #{table} WHERE id = $1",
           [Cgc2046.Repo.uuid!(id)]
         ) do
      {:ok, %{rows: [[pricing_enabled, price_tiers, deadline, deposit_enabled, deposit_amount]]}} ->
        {:ok,
         %{
           pricing_enabled: pricing_enabled,
           price_tiers: price_tiers || [],
           registration_deadline: deadline,
           deposit_enabled: deposit_enabled,
           deposit_amount_cents: deposit_amount
         }}

      {:ok, %{rows: []}} ->
        {:error, :target_not_found}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
  end

  defp order_kind(%{event_id: event_id}, %{deposit_enabled: true}) when not is_nil(event_id),
    do: :deposit

  defp order_kind(_enrollment, _target), do: :enrollment

  # 押金同意门（#727，U1/KTD10 披露门下沉）：判据是后端自己的 order_kind/2
  # （enrollment.event_id + events.deposit_enabled），**不认客户端提交的押金
  # 识别**——客户端漏传/脏值只影响它自己是否被拒，绝不影响门的强弱。
  # 非押金单忽略本参数（定价/免费单零改动）；押金单只有 `deposit_consent == true`
  # 放行，缺失、null、false 一律拒（fail-closed，同 #510 age_confirmed 口径）。
  defp deposit_consent_gate(changeset, enrollment, target) do
    case order_kind(enrollment, target) do
      :deposit ->
        if Ash.Changeset.get_argument(changeset, :deposit_consent) == true,
          do: :ok,
          else: {:error, :deposit_consent_required}

      :enrollment ->
        :ok
    end
  end

  # ── 金额源分派（U2/KTD1）────────────────────────────────────────────────

  # 押金单 tier 快照的展示名：管理面 tier_name、渠道订单 subject（微信/支付宝
  # payment_description/payment_subject）、通知 receipt_data 同源读此名。
  @deposit_tier_name "押金"

  # 下单金额源按 order_kind 分派：押金单跳过 resolve_tier/2，以**活动现值**
  # 押金金额合成「押金」形状 tier——amount_cents / tier_snapshot /
  # channel_create_payment/4 / 管理面 tier_name 等下游消费者零改动。
  defp resolve_order_amount(enrollment, target) do
    case order_kind(enrollment, target) do
      :deposit -> enrollment_deposit_tier(target)
      :enrollment -> resolve_tier(enrollment, target)
    end
  end

  # 换渠道沿用被替换订单自己的口径（KTD1「取订单 tier_snapshot，不重新读 Event」）：
  # 押金单按原单快照换渠道，Owner 事后改押金金额/关押金都不改写在途单的承诺口径；
  # 定价单维持现状（按当前配置的档位解析，R3）。调用方据此同源写 order_kind。
  defp resolve_replaced_amount(order, enrollment, target) do
    case order.order_kind do
      :deposit -> order_deposit_tier(order)
      :enrollment -> resolve_tier(enrollment, target)
    end
  end

  # 押金现值 → tier（#749）：金额源是 `events.deposit_amount_cents` 现值，
  # `submission_payload` 不参与（历史预埋的脏键天然免疫）。非正整数（脏配置
  # 0/nil）一律 fail-closed——绝不以零金额调渠道下单，报稳定业务错误交前端
  # 重报名。
  defp enrollment_deposit_tier(%{deposit_amount_cents: amount_cents}),
    do: deposit_tier(amount_cents)

  defp order_deposit_tier(%{tier_snapshot: snapshot}) when is_map(snapshot),
    do: deposit_tier(Map.get(snapshot, "amount_cents"))

  defp order_deposit_tier(_order), do: {:error, :deposit_amount_missing}

  defp deposit_tier(amount_cents) when is_integer(amount_cents) and amount_cents > 0,
    do: {:ok, %{"name" => @deposit_tier_name, "amount_cents" => amount_cents}}

  defp deposit_tier(_amount_cents), do: {:error, :deposit_amount_missing}

  # 档位解析：报名时选的 tier_id → 当前配置中的档位（改价后下单按现价快照）。
  # #687：金额 fail-closed——脏 amount_cents（force write / 裸 SQL 存量，写入路径
  # PriceTiersValidation 已拦）绝不物化 ¥0/脏金额订单或调渠道，与押金单
  # deposit_tier/1 的 order_deposit_amount_missing 同款红线（展示侧见
  # PriceTier.available_tiers/1 的 nil 降级 + 前端「金额待定」禁选）。
  defp resolve_tier(enrollment, target) do
    tier_id = enrollment.submission_payload["tier_id"]

    with {:ok, tier} <- Cgc2046.Offering.PriceTier.find(target.price_tiers, tier_id),
         true <-
           Cgc2046.Offering.PriceTier.available?(tier, DateTime.utc_now()) ||
             {:error, :tier_not_available},
         true <-
           (is_integer(tier["amount_cents"]) and tier["amount_cents"] > 0) ||
             {:error, :tier_amount_invalid} do
      {:ok, tier}
    end
  end

  # R6：订单截止 = min(下单 + 2h, registration_deadline)；deadline 已过 → 拒绝下单
  @order_window_seconds 2 * 3600

  defp order_expire_at(%{registration_deadline: nil}) do
    {:ok, DateTime.add(DateTime.utc_now(), @order_window_seconds)}
  end

  # 裸 SQL 读出的 deadline 是 NaiveDateTime（无时区解码），先归一为 UTC
  defp order_expire_at(%{registration_deadline: %NaiveDateTime{} = naive}) do
    order_expire_at(%{registration_deadline: DateTime.from_naive!(naive, "Etc/UTC")})
  end

  defp order_expire_at(%{registration_deadline: deadline}) do
    default = DateTime.add(DateTime.utc_now(), @order_window_seconds)

    cond do
      DateTime.compare(deadline, DateTime.utc_now()) != :gt ->
        {:error, :registration_closed}

      DateTime.compare(deadline, default) == :lt ->
        {:ok, deadline}

      true ->
        {:ok, default}
    end
  end

  # 渠道下单（事务内；失败回滚 = 无凭据无订单）。JSAPI 需要报名者的微信 openid
  # （小程序 identity，下单参数由本处提供，KTD3）。
  defp channel_create_payment(provider, enrollment, tier, out_trade_no) do
    ctx =
      if provider == :wechat_jsapi do
        with {:ok, openid} <- wechat_openid(enrollment.user_id), do: {:ok, %{openid: openid}}
      else
        {:ok, %{}}
      end

    with {:ok, ctx} <- ctx do
      order_shape = %{
        provider: provider,
        out_trade_no: out_trade_no,
        amount_cents: tier["amount_cents"],
        tier_snapshot: tier
      }

      Cgc2046.Payments.Provider.for(provider).create_payment(order_shape, ctx)
    end
  end

  defp wechat_openid(user_id) do
    case Cgc2046.Repo.query(
           "SELECT uid FROM user_identities WHERE user_id = $1 AND provider = 'wechat' LIMIT 1",
           [Cgc2046.Repo.uuid!(user_id)]
         ) do
      {:ok, %{rows: [[uid]]}} -> {:ok, uid}
      {:ok, %{rows: []}} -> {:error, :openid_required}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  # 旧单 CAS：pending → cancelled（并发双换第二笔 num_rows=0 拒绝）
  defp cancel_old_order(order_id) do
    sql = """
    UPDATE payments_orders
    SET status = 'cancelled', cancel_reason = 'provider_switch', updated_at = NOW()
    WHERE id = $1 AND status = 'pending'
    """

    case Cgc2046.Repo.query(sql, [Cgc2046.Repo.uuid!(order_id)]) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> {:error, :already_processed}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  # 幂等下单（#405）：废掉该报名的现有 pending 单，为重进支付页的新单腾出
  # unique_active_order 索引窗口。调用点已持 enrollment 行 FOR UPDATE 锁
  # （load_enrollment → lock_for_order），同报名下单串行，num_rows ∈ {0,1}：
  # 0 = 首单无旧单；1 = 废旧成功。索引兜底保证 >1 不可能。
  defp discard_stale_pending_order(enrollment_id) do
    sql = """
    UPDATE payments_orders
    SET status = 'cancelled', cancel_reason = 'reenter_refresh', updated_at = NOW()
    WHERE enrollment_id = $1 AND status = 'pending'
    """

    case Cgc2046.Repo.query(sql, [Cgc2046.Repo.uuid!(enrollment_id)]) do
      {:ok, %{num_rows: n}} when n in [0, 1] -> :ok
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  # 平台侧全局唯一商户单号（R6）。长度硬约束 = 微信 APIv3 上限 32 字符
  # （支付宝 64）——"CGC" + UUID hex 前 29 位；2026-08-24 生产实证：35 字符
  # 单号微信下单必 400 PARAM_ERROR「商户订单号错误」。截位后 116 bit 随机性
  # + unique_out_trade_no 唯一索引兜底碰撞。
  defp generate_out_trade_no do
    "CGC" <> binary_part(String.replace(Ecto.UUID.generate(), "-", ""), 0, 29)
  end

  # 裸 SQL 读出的文本列 → 既有原子（status / order_kind）；未声明值上抛而非
  # 造原子（unsafe_to_atom 纪律）。
  defp existing_atom(value) when is_binary(value), do: String.to_existing_atom(value)
  defp existing_atom(value) when is_atom(value), do: value

  # ── 信号 payload（SignalEmitter 契约：fn changeset, record -> map）─────────

  def paid_signal_payload(_changeset, order) do
    %{
      "order_id" => order.id,
      "enrollment_id" => order.enrollment_id,
      "amount_cents" => order.amount_cents,
      "provider" => to_string(order.provider)
    }
  end

  # ── 跨 context 端口（ADR-0009 写点收编）────────────────────────────────

  @doc """
  报名侧作废端口（ADR-0009 Fable 5 MEDIUM-2 收编；R12/e2e #1）：Admission 的
  Enrollment 在取消/免缴路径离开占位态的同一事务内调用——将该报名关联的
  pending 订单批量置 cancelled 并落 cancel_reason。

  语义（与收编前 enrollment.ex 内嵌 SQL 逐行等价）：

  - 仅命中 `status = 'pending'`（已过期时点但未被 expire 扫描置为 expired 的
    单一并置为 cancelled，状态守卫只认 status 列，不看 expire_at）；
  - cancelled 是终态，部分唯一索引（R11）放行后续新报名的新订单；
  - 本地作废不关渠道单、QR 仍可被支付——迟到收款由落账 worker 走作废单
    自动退款分支兜底（AE2 语义）；
  - 返回 {:ok, 作废笔数}（0 笔合法：报名可能尚无订单）；SQL 失败
    {:error, {:database, _}}，调用方整体回滚（本函数用 Repo.query 跑在
    调用方事务连接上，不开隐式独立事务）。
  """
  def void_pending_for_enrollment(enrollment_id, cancel_reason) do
    case Cgc2046.Repo.query(
           "UPDATE payments_orders SET status = 'cancelled', cancel_reason = $2, updated_at = NOW() WHERE enrollment_id = $1 AND status = 'pending'",
           [Cgc2046.Repo.uuid!(enrollment_id), cancel_reason]
         ) do
      {:ok, %{num_rows: count}} -> {:ok, count}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  # ── 状态迁移（DB 级 CAS：条件 UPDATE + num_rows 守卫）────────────────────

  defp prepare_mark_paid(changeset) do
    transaction_id = Ash.Changeset.get_argument(changeset, :transaction_id)

    case claim(changeset, [:pending], "status = 'paid', transaction_id = $1", [transaction_id]) do
      {:ok, changeset} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :paid)
        |> Ash.Changeset.force_change_attribute(:transaction_id, transaction_id)

      {:error, changeset} ->
        changeset
    end
  end

  defp prepare_cancel(changeset) do
    cancel_reason = Ash.Changeset.get_argument(changeset, :cancel_reason)

    case claim(changeset, [:pending], "status = 'cancelled', cancel_reason = $1", [
           cancel_reason
         ]) do
      {:ok, changeset} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :cancelled)
        |> Ash.Changeset.force_change_attribute(:cancel_reason, cancel_reason)

      {:error, changeset} ->
        changeset
    end
  end

  defp prepare_expire(changeset) do
    case Cgc2046.Admission.Enrollment.lock_for_order(changeset.data.enrollment_id) do
      {:ok, _} -> do_expire(changeset)
      {:error, reason} -> add_domain_error(changeset, {:database, reason})
    end
  end

  defp do_expire(changeset) do
    case claim(changeset, [:pending], "status = 'expired'") do
      {:ok, changeset} ->
        # 报名侧联动收编 Admission 端口（ADR-0009 U5 / R20，KTD6 同事务）：
        # CAS payment_pending→expired + 名额回落由 Enrollment 承担。num_rows=0 =
        # 报名已流转（免缴 confirmed / 已取消）——订单过期照常，无名额可释，迟到
        # 收款由落账 worker 自动退款链兜底（KTD12 不变量）。失败 → {:error,_}
        # 整体回滚（含订单 CAS），扫描下拍重试。
        case Cgc2046.Admission.Enrollment.release_for_payment_expiry(changeset.data.enrollment_id) do
          :ok -> Ash.Changeset.force_change_attribute(changeset, :status, :expired)
          {:error, reason} -> add_domain_error(changeset, {:database, reason})
        end

      {:error, changeset} ->
        changeset
    end
  end

  defp prepare_start_refund(changeset) do
    case claim(changeset, [:paid, :expired, :cancelled], "status = 'refunding'") do
      {:ok, changeset} -> Ash.Changeset.force_change_attribute(changeset, :status, :refunding)
      {:error, changeset} -> changeset
    end
  end

  # no-show 结算 CAS：仅 paid 源态（KTD7 一次性迁移）**且仅押金单**——否则
  # admin/内部面误调会没收普通报名单（CWE-863）；非 paid 或非押金单一律
  # num_rows=0 → :already_processed（幂等语义不变）。

  defp prepare_forfeit(changeset) do
    case claim(changeset, [:paid], "status = 'forfeited'", [], "order_kind = 'deposit'") do
      {:ok, changeset} -> Ash.Changeset.force_change_attribute(changeset, :status, :forfeited)
      {:error, changeset} -> changeset
    end
  end

  defp prepare_refund_succeeded(changeset) do
    now = DateTime.utc_now()

    case claim(changeset, [:refunding], "status = 'refunded', refunded_at = $1", [now]) do
      {:ok, changeset} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :refunded)
        |> Ash.Changeset.force_change_attribute(:refunded_at, now)

      {:error, changeset} ->
        changeset
    end
  end

  defp prepare_mark_refund_failed(changeset) do
    case claim(changeset, [:refunding], "status = 'refund_failed'") do
      {:ok, changeset} -> Ash.Changeset.force_change_attribute(changeset, :status, :refund_failed)
      {:error, changeset} -> changeset
    end
  end

  defp prepare_retry_refund(changeset) do
    case claim(changeset, [:refund_failed], "status = 'refunding'") do
      {:ok, changeset} -> Ash.Changeset.force_change_attribute(changeset, :status, :refunding)
      {:error, changeset} -> changeset
    end
  end

  # #545：CAS forfeited → refunding（claim 单点，同 prepare_retry_refund 形状）
  defp prepare_unforfeit(changeset) do
    case claim(changeset, [:forfeited], "status = 'refunding'") do
      {:ok, changeset} -> Ash.Changeset.force_change_attribute(changeset, :status, :refunding)
      {:error, changeset} -> changeset
    end
  end

  # 管理员单笔退款（R15）：CAS paid → refunding。closed 后仍可（无 Event
  # status 校验）；非 paid（含 expired 自动退款路径）被状态守卫拒绝。
  defp prepare_refund(changeset) do
    case claim(changeset, [:paid], "status = 'refunding'") do
      {:ok, changeset} -> Ash.Changeset.force_change_attribute(changeset, :status, :refunding)
      {:error, changeset} -> changeset
    end
  end

  # 渠道退款 job 同事务入队（SignalEmitter outbox 同款纪律）：CAS 成功才有
  # after_action，失败路径不产生孤儿 job。R22 发起人精确归属：单笔管理员退款/
  # 重试的 mutation actor 随 job 下传（initiator_user_id），worker 通知收件人
  # 精确到「报名人 + 发起管理员」；自动退款/批量入队无 actor → 管理者超集。
  defp enqueue_refund_job(changeset, order) do
    actor = get_in(changeset.context, [:private, :actor])

    args =
      %{order_id: order.id}
      |> then(fn args ->
        if actor, do: Map.put(args, :initiator_user_id, actor.id), else: args
      end)

    args
    |> Cgc2046.Payments.Workers.PaymentRefundWorker.new()
    |> Oban.insert!()

    {:ok, order}
  end

  def refund_log_metadata(_changeset, order) do
    %{
      "order_id" => order.id,
      "enrollment_id" => order.enrollment_id,
      "amount_cents" => order.amount_cents,
      "provider" => to_string(order.provider)
    }
  end

  # #545：unforfeit 审计在退款元数据之上补 from_status + 必填 reason
  def unforfeit_log_metadata(changeset, order) do
    Map.merge(refund_log_metadata(changeset, order), %{
      "from_status" => "forfeited",
      "reason" => Ash.Changeset.get_argument(changeset, :reason)
    })
  end

  # 条件 UPDATE CAS：WHERE 带 id + 源状态守卫（可按需追加 extra_where 谓词）。命中（num_rows=1）→ 返回
  # {:ok, changeset}，调用方 force_change 附加字段；未命中 → :already_processed；
  # SQL 失败（含 R11 唯一冲突等 DB 约束拒绝）→ :database。set_sql 内占位符
  # 从 $1 起连续编号，id 固定为最后一个参数。
  defp claim(changeset, from_statuses, set_sql, params \\ [], extra_where \\ nil) do
    sources = Enum.map_join(from_statuses, ", ", &"'#{&1}'")
    extra = if extra_where, do: " AND #{extra_where}", else: ""

    sql = """
    UPDATE payments_orders
    SET #{set_sql}, updated_at = NOW()
    WHERE id = $#{length(params) + 1} AND status IN (#{sources})#{extra}
    """

    case Cgc2046.Repo.query(sql, params ++ [Cgc2046.Repo.uuid!(changeset.data.id)]) do
      {:ok, %{num_rows: 1}} -> {:ok, changeset}
      {:ok, %{num_rows: 0}} -> {:error, add_domain_error(changeset, :already_processed)}
      {:error, reason} -> {:error, add_domain_error(changeset, {:database, reason})}
    end
  end

  # ── 错误文案（i18n Phase 0：BusinessError 携带稳定 code，前端按 code 查文案）──

  defp add_domain_error(changeset, reason) do
    Ash.Changeset.add_error(
      changeset,
      Cgc2046.Errors.BusinessError.exception(
        message: domain_error_message(reason),
        code: domain_error_code(reason),
        fields: [:status]
      )
    )
  end

  # create_for_enrollment / replace_provider 唯一约束冲突（已有活跃订单 / 并发
  # 下单）转业务错误。非 unique 错误原样返回（error_handler 返回值即入列的错误）。
  def handle_create_error(_changeset, error) do
    if Cgc2046.Errors.ConstraintConflict.unique_conflict?(error) do
      Cgc2046.Errors.BusinessError.exception(
        message: domain_error_message(:duplicate_active),
        code: domain_error_code(:duplicate_active)
      )
    else
      error
    end
  end

  defp domain_error_message(:enrollment_required), do: "enrollment_id is required"
  defp domain_error_message(:enrollment_not_found), do: "enrollment does not exist"

  defp domain_error_message(:target_tenant_mismatch),
    do: "enrollment does not belong to tenant"

  defp domain_error_message(:already_processed), do: "order has already been processed"
  defp domain_error_message(:provider_not_configured), do: "payment provider is not configured"

  defp domain_error_message(:not_payment_pending),
    do: "enrollment is not awaiting payment"

  defp domain_error_message(:duplicate_active),
    do: "an active order already exists for this enrollment"

  defp domain_error_message(:deposit_amount_missing),
    do: "deposit amount snapshot is missing for this enrollment"

  defp domain_error_message(:tier_amount_invalid),
    do: "selected price tier has an invalid amount"

  defp domain_error_message(:deposit_consent_required),
    do: "deposit consent is required before creating a deposit order"

  # 换渠道校验（#750/F-05）：存量部署前押金单无同意留痕，拒换渠道
  defp domain_error_message(:deposit_consent_missing),
    do: "this deposit order has no recorded consent; create a new order to record it"

  defp domain_error_message({:database, _reason}), do: "database operation failed"
  defp domain_error_message(reason), do: inspect(reason)

  defp domain_error_code({:database, _reason}), do: "database_error"
  defp domain_error_code(:enrollment_required), do: "order_enrollment_required"
  defp domain_error_code(:enrollment_not_found), do: "order_enrollment_not_found"
  defp domain_error_code(:target_tenant_mismatch), do: "order_target_tenant_mismatch"
  defp domain_error_code(:already_processed), do: "order_already_processed"
  defp domain_error_code(:provider_not_configured), do: "order_provider_not_configured"
  defp domain_error_code(:not_payment_pending), do: "order_not_payment_pending"
  defp domain_error_code(:duplicate_active), do: "order_duplicate_active"

  # 押金单金额源缺快照（U2/KTD1）：历史报名/缴费模式事后切换时 fail-closed
  defp domain_error_code(:deposit_amount_missing), do: "order_deposit_amount_missing"

  # 定价单档位金额脏（#687，resolve_tier/2 fail-closed）：显式子句化以进契约工件
  defp domain_error_code(:tier_amount_invalid), do: "order_tier_amount_invalid"

  # 押金同意门（#727）：显式子句化以进契约工件（兜底拼出的同名字符串 AST 提取不到）
  defp domain_error_code(:deposit_consent_required), do: "order_deposit_consent_required"

  # 换渠道同意事实校验（#750/F-05）：显式子句化以进契约工件
  defp domain_error_code(:deposit_consent_missing), do: "order_deposit_consent_missing"
  # 已含资源语义的 load_*/openid 原子显式子句化（#241 F3）：兜底会拼出
  # order_order_not_found 双前缀；openid_required 显式化以进契约工件
  defp domain_error_code(:order_not_found), do: "order_not_found"
  defp domain_error_code(:order_required), do: "order_required"
  defp domain_error_code(:openid_required), do: "order_openid_required"

  # 渠道下单被拒（adapter 非 200 归一原子）：显式化以进契约工件（#241 F3 同款）
  defp domain_error_code(:channel_create_failed), do: "order_channel_create_failed"

  defp domain_error_code(reason) when is_atom(reason), do: "order_" <> Atom.to_string(reason)
  defp domain_error_code({kind, _}) when is_atom(kind), do: "order_" <> Atom.to_string(kind)
  defp domain_error_code(_), do: "order_unknown"
end
