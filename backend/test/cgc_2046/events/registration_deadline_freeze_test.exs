defmodule Cgc2046.Events.RegistrationDeadlineFreezeTest do
  @moduledoc """
  报名截止前移冻结守卫（#543 押金自助取消退款的锚点对齐）。

  `registration_deadline` 是押金单自助取消退款资格的锚点
  （`CancelFlow.self_cancel_refund_eligible?` 对 :deposit 用
  `before_deadline?/2`，取消时锁行现算，不做下单快照比对）。因此 Owner/Admin
  把该值改早（或改成过去）会**追溯性关闭**既有押金单的自助退款窗口：
  判定为假时静默走 `{:ok, enrollment}` 分支——不打款、不报错，订单停在
  `paid`，而 `rules_registry` 的规则集中没有「cancelled 报名上仍有 paid 订单」
  这一条，脱离自动检测。

  同文件已对 `ends_at` 有前移冻结（`event_ends_at_frozen`，理由是同类的资金
  扳机不可追溯移动）；本文件把同一纪律补齐到 `registration_deadline`。

  注意因果边界：改 deadline **不会**把押金推进没收（没收由
  `DepositForfeitWorker` 按 `ends_at + 48h` + 无 Attendance 判定，deadline 不
  参与）——它关掉的是用户**唯一的自救退路**。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Events.Event
  alias Cgc2046.EventsFixtures, as: EventFixtures

  setup do
    admin = Fixtures.platform_admin("deadline-freeze")
    workspace = Fixtures.create_workspace(admin)
    %{admin: admin, workspace: workspace}
  end

  defp create_deposit_event(ctx) do
    EventFixtures.create_event(ctx.workspace, ctx.admin, %{
      title: "押金场",
      deposit_enabled: true,
      deposit_amount_cents: 6900,
      ends_at: EventFixtures.days_from_now(8),
      registration_deadline: EventFixtures.days_from_now(8)
    })
  end

  defp add_paid_deposit_order(ctx, event) do
    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{event_id: event.id, user_id: ctx.admin.id})
      |> Ash.create(tenant: ctx.workspace.id, authorize?: false)

    Cgc2046.Repo.query!(
      """
      INSERT INTO payments_orders (id, enrollment_id, order_kind, amount_cents,
        provider, status, out_trade_no, expire_at, inserted_at, updated_at, workspace_id, tier_snapshot)
      VALUES (gen_random_uuid(), $1::uuid, 'deposit', 6900, 'wechat_native', 'paid',
        'deadline-freeze-txn', NOW() + INTERVAL '2 hours', NOW(), NOW(), $2::uuid,
        '{"name":"押金","amount_cents":6900}')
      """,
      [Ecto.UUID.dump!(enrollment.id), Ecto.UUID.dump!(ctx.workspace.id)]
    )

    enrollment
  end

  # 押金场 + 一张未终态押金单（冻结守卫的触发条件）
  defp mount_deposit_event_with_order(ctx) do
    event = create_deposit_event(ctx)
    _ = add_paid_deposit_order(ctx, event)
    event
  end

  defp update_event(ctx, event, attrs) do
    event
    |> Ash.Changeset.for_update(:update, attrs)
    |> Ash.update(actor: ctx.admin, tenant: ctx.workspace.id)
  end

  defp assert_business_code({:error, %Ash.Error.Invalid{errors: errors}}, expected) do
    assert Enum.any?(errors, &match?(%BusinessError{code: ^expected}, &1)),
           "expected BusinessError code #{expected}, got: #{inspect(errors)}"
  end

  defp reload(event), do: Ash.get!(Event, event.id, authorize?: false)

  test "存在未终态押金单时禁止 registration_deadline 前移", ctx do
    event = create_deposit_event(ctx)
    _enrollment = add_paid_deposit_order(ctx, event)

    result = update_event(ctx, event, %{registration_deadline: EventFixtures.days_from_now(1)})

    assert_business_code(result, "event_registration_deadline_frozen")
  end

  test "同一次写入关掉押金开关 + 前移 deadline → 仍被拒（开关绕过回归钉）", ctx do
    # 原缺口：守卫写的是 `deposit_enabled == true and ...`，而该值取的是**写后
    # 生效值**——同一 changeset 里把开关关掉 + 前移 deadline，前置条件即为假，
    # 守卫整个跳过。但关掉开关**不移除既有押金单**（订单口径由
    # `payments_orders.order_kind` 决定，与活动开关解耦），而 CancelFlow 判自助
    # 退款资格仍取活动**当前**的 deadline → 存量押金单照样被追溯剥夺退款窗口。
    # 故冻结判据必须只看存量单，不看当前开关。
    event = mount_deposit_event_with_order(ctx)

    result =
      update_event(ctx, event, %{
        deposit_enabled: false,
        registration_deadline: EventFixtures.days_from_now(1)
      })

    assert_business_code(result, "event_registration_deadline_frozen")
  end

  test "同一次写入关掉押金开关 + 前移 ends_at → 同样被拒（兄弟实例）", ctx do
    # Codex 只报了 deadline；ends_at 守卫当时同形同病，一并修正并钉住。
    event = mount_deposit_event_with_order(ctx)

    result =
      update_event(ctx, event, %{
        deposit_enabled: false,
        ends_at: EventFixtures.days_from_now(1)
      })

    assert_business_code(result, "event_ends_at_frozen")
  end

  test "仅有 pending 押金单（尚未付款）时同样禁止前移 deadline（时序回归钉）", ctx do
    # 原缺口：判据只认 paid/refunding/refund_failed，漏了 pending。而待付单的
    # expire_at = min(下单+2h, 下单时看到的 deadline) 是**下单那刻算定的**，
    # 改活动截止不重算；结算路径的 CAS 只看 status='pending'（不复查活动截止）
    # → 「下单选待付 → 改早截止 → 2h 内付款到账」照样落 paid，而该单的自助
    # 退款窗口已被追溯关闭。故 pending 必须计入。
    event = create_deposit_event(ctx)

    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{
        event_id: event.id,
        user_id: ctx.admin.id
      })
      |> Ash.create(tenant: ctx.workspace.id, authorize?: false)

    Cgc2046.Repo.query!(
      """
      INSERT INTO payments_orders (id, enrollment_id, order_kind, amount_cents,
        provider, status, out_trade_no, expire_at, inserted_at, updated_at, workspace_id, tier_snapshot)
      VALUES (gen_random_uuid(), $1::uuid, 'deposit', 6900, 'wechat_native', 'pending',
        'deadline-freeze-pending', NOW() + INTERVAL '2 hours', NOW(), NOW(), $2::uuid,
        '{"name":"押金","amount_cents":6900}')
      """,
      [Ecto.UUID.dump!(enrollment.id), Ecto.UUID.dump!(ctx.workspace.id)]
    )

    result = update_event(ctx, event, %{registration_deadline: EventFixtures.days_from_now(1)})

    assert_business_code(result, "event_registration_deadline_frozen")
  end

  test "两步绕过：先置 null 再设过去值 → 第二步必须被拒（nil 语义回归钉）", ctx do
    # 缺口的机制：`moved_earlier?` 原对 nil 恒返 false，而
    # `Enrollment.before_deadline?(nil) == true`（nil = 无限期可退、最宽松）。
    # 于是「先把 deadline 置 null（放宽，本身该放行）→ 再设成过去」的第二步
    # 因 old=nil 被判定为「非前移」而跳过守卫 —— 实际把「永不关闭的窗口」
    # 变成了已关闭。故 nil → 具体日期必须算前移。
    event = mount_deposit_event_with_order(ctx)

    # 第一步：关押金 + 置空 deadline（放宽，允许）
    assert {:ok, _} =
             update_event(ctx, event, %{deposit_enabled: false, registration_deadline: nil})

    reloaded = Ash.get!(Event, event.id, authorize?: false)
    assert reloaded.registration_deadline == nil

    # 第二步：设成过去 —— 必须被拒
    result =
      update_event(ctx, reloaded, %{registration_deadline: EventFixtures.days_from_now(-3)})

    assert_business_code(result, "event_registration_deadline_frozen")
  end

  test "ends_at：无锚点场补锚到过去值必须放行（修复路径，与 deadline 相反）", ctx do
    # **刻意与上面的 deadline 用例方向相反**：ends_at 的 nil 不是「最宽松」而是
    # 「异常」——nil = 不触发没收 = 押金永久滞留（KTD7 绝不静默滞留），由
    # DepositForfeitWorker 落 deposit_settlement_unanchored Finding 暴露。
    # 故 `nil → 过去值`（运维补锚）是**修复动作**，必须放行；拦掉会永久锁死
    # 这类场的押金。DepositForfeitWorkerTest「锚点补回后 Finding 自消」钉的是
    # 同一条路径（补锚后下一拍结算为 forfeited）。
    #
    # 风险面：补锚确实会触发下一拍没收，但入参必须由管理员显式填写，且触发的是
    # 「修回正常态」，等价于「把 ends_at 设成现在再等 48h」——同一路径、同一终态。
    event = mount_deposit_event_with_order(ctx)

    assert {:ok, _} = update_event(ctx, event, %{deposit_enabled: false, ends_at: nil})

    reloaded = Ash.get!(Event, event.id, authorize?: false)
    assert reloaded.ends_at == nil

    assert {:ok, repaired} =
             update_event(ctx, reloaded, %{ends_at: EventFixtures.days_from_now(-3)})

    assert repaired.ends_at != nil
  end

  describe "锁内真值判定（#1103：旧值不再取 changeset 快照）" do
    test "并发放宽后，基于过期快照的写入仍被拦（此前漏判的前移）", ctx do
      # 完整复现 #1103 描述的两步：
      #   1) A 把 deadline 从 8 天放宽到 30 天并提交（合法，守卫放行）；
      #   2) B 手里是「A 提交之前」读到的旧 struct（快照 = 8 天），提交 20 天。
      # 旧实现用快照判：20 > 8 → 判为放宽 → 放行；实际库里是 30 天，20 是前移。
      event = mount_deposit_event_with_order(ctx)

      # 步骤 1：A 放宽到 30 天
      assert {:ok, _} =
               update_event(ctx, event, %{registration_deadline: EventFixtures.days_from_now(30)})

      widened = reload(event).registration_deadline

      # 前提：B 的快照（event 变量）必须已过期，否则这个用例测不到东西
      assert DateTime.compare(
               widened,
               Ash.Changeset.get_data(
                 Ash.Changeset.for_update(event, :update, %{}),
                 :registration_deadline
               )
             ) == :gt

      # 步骤 2：B 基于**旧快照**提交 20 天——相对快照是放宽，相对库中真值是前移
      result =
        update_event(ctx, event, %{registration_deadline: EventFixtures.days_from_now(20)})

      assert_business_code(result, "event_registration_deadline_frozen")
      # 库里仍是 A 写进去的值，B 的写入没落
      assert DateTime.compare(reload(event).registration_deadline, widened) == :eq
    end

    test "快照未过期时正常前移仍被拦（回归：守卫本身没被削弱）", ctx do
      event = mount_deposit_event_with_order(ctx)

      result =
        update_event(ctx, event, %{registration_deadline: EventFixtures.days_from_now(1)})

      assert_business_code(result, "event_registration_deadline_frozen")
    end

    test "并发放宽不误伤：宽 → 更宽放行", ctx do
      event = mount_deposit_event_with_order(ctx)

      assert {:ok, _} =
               update_event(ctx, event, %{registration_deadline: EventFixtures.days_from_now(30)})

      assert {:ok, updated} =
               update_event(ctx, reload(event), %{
                 registration_deadline: EventFixtures.days_from_now(40)
               })

      assert DateTime.compare(updated.registration_deadline, EventFixtures.days_from_now(30)) ==
               :gt
    end
  end

  test "无押金单时 registration_deadline 可前移（守卫不触发）", ctx do
    event = create_deposit_event(ctx)

    assert {:ok, updated} =
             update_event(ctx, event, %{registration_deadline: EventFixtures.days_from_now(1)})

    assert reload(updated).registration_deadline != nil
  end

  test "后移 registration_deadline 不受影响（存单也在）", ctx do
    event = create_deposit_event(ctx)
    _enrollment = add_paid_deposit_order(ctx, event)

    assert {:ok, _updated} =
             update_event(ctx, event, %{registration_deadline: EventFixtures.days_from_now(30)})
  end

  test "未开押金的场次不受该守卫约束", ctx do
    event =
      EventFixtures.create_event(ctx.workspace, ctx.admin, %{
        title: "免费场",
        registration_deadline: EventFixtures.days_from_now(8)
      })

    assert {:ok, _} =
             update_event(ctx, event, %{registration_deadline: EventFixtures.days_from_now(1)})
  end
end
