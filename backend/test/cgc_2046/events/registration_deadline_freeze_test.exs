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
