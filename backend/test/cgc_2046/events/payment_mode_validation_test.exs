defmodule Cgc2046.Events.PaymentModeValidationTest do
  @moduledoc """
  U3 / R1 / R3 / KTD3（AE1、AE2）：缴费三态互斥与押金必填项。

  - `deposit_enabled` 与 `pricing_enabled` 不可同真（资源校验 +
    DB CHECK `events_payment_mode_exclusive` 并发兜底，同映射
    `event_payment_mode_exclusive`）。
  - 押金开启必须正金额 + 非空 ends_at（no-show 结算锚点，KTD7）。
  - 未挂载 Initiative 的 Event 可独立开押金（AE2，落地 Initiative 计划 AE12）。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Events.Event
  alias Cgc2046.Events.PaymentModeValidation
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures

  setup do
    admin = Fixtures.platform_admin("payment-mode")
    workspace = Fixtures.create_workspace(admin)
    %{admin: admin, workspace: workspace}
  end

  defp create_event(ctx, attrs) do
    Event
    |> Ash.Changeset.for_create(:create, Map.merge(%{title: "PM"}, attrs),
      tenant: ctx.workspace.id
    )
    |> Ash.create(tenant: ctx.workspace.id, actor: ctx.admin)
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

  # #597：合法休眠态（R4）——定价关闭时保留档位是允许的，它正是 I2 防的残留来源。
  defp dormant_tiers,
    do: [%{"id" => Ash.UUID.generate(), "name" => "休眠", "amount_cents" => 9900}]

  defp deposit_attrs,
    do: %{
      deposit_enabled: true,
      deposit_amount_cents: 3000,
      ends_at: EventFixtures.days_from_now(3),
      registration_deadline: EventFixtures.days_from_now(3)
    }

  describe "三态互斥（R1 / AE1）" do
    test "已开定价的 Event update 开押金 → 被拒，错误码稳定", ctx do
      {:ok, event} =
        create_event(ctx, %{
          pricing_enabled: true,
          price_tiers: [%{"id" => Ash.UUID.generate(), "name" => "早鸟", "amount_cents" => 1000}]
        })

      assert {:error, _} =
               result =
               update_event(ctx, event, %{
                 deposit_enabled: true,
                 deposit_amount_cents: 3000,
                 ends_at: EventFixtures.days_from_now(3),
                 registration_deadline: EventFixtures.days_from_now(3)
               })

      assert_business_code(result, "event_payment_mode_exclusive")
      assert reload(event).deposit_enabled == false
    end

    test "已开押金的 Event update 开定价 → 被拒，错误码稳定", ctx do
      {:ok, event} =
        create_event(ctx, %{
          deposit_enabled: true,
          deposit_amount_cents: 3000,
          ends_at: EventFixtures.days_from_now(3),
          registration_deadline: EventFixtures.days_from_now(3)
        })

      assert {:error, _} =
               result =
               update_event(ctx, event, %{
                 pricing_enabled: true,
                 price_tiers: [
                   %{"id" => Ash.UUID.generate(), "name" => "早鸟", "amount_cents" => 1000}
                 ]
               })

      assert_business_code(result, "event_payment_mode_exclusive")
      assert reload(event).pricing_enabled == false
    end

    test "create 时同时开定价与押金 → 被拒，错误码稳定", ctx do
      assert {:error, _} =
               result =
               create_event(ctx, %{
                 pricing_enabled: true,
                 price_tiers: [
                   %{"id" => Ash.UUID.generate(), "name" => "早鸟", "amount_cents" => 1000}
                 ],
                 deposit_enabled: true,
                 deposit_amount_cents: 3000,
                 ends_at: EventFixtures.days_from_now(3),
                 registration_deadline: EventFixtures.days_from_now(3)
               })

      assert_business_code(result, "event_payment_mode_exclusive")
    end

    test "直接绕过资源校验写双真（并发模拟）→ DB CHECK 拒绝并映射稳定业务错误", ctx do
      # 并发形状：两个事务各基于旧值通过资源校验后同窗提交，后到写撞上
      # events_payment_mode_exclusive；此处以裸 SQL UPDATE 布置/模拟该双真行
      # 必须被 CHECK 拒绝（CHECK 本身即被测对象，force_open 同款布置纪律）。
      # 三个押金锚点写有效值 → 本次写**只**违反互斥约束（多约束同时违反时
      # Postgres 只报其中一条，归因必须唯一）。
      {:ok, event} = create_event(ctx, %{})

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation, constraint: name}}} =
               Cgc2046.Repo.query(
                 """
                 UPDATE events
                    SET deposit_enabled = true,
                        pricing_enabled = true,
                        ends_at = NOW() + interval '1 day',
                        registration_deadline = NOW() + interval '1 day',
                        deposit_amount_cents = 3000
                  WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(event.id)]
               )

      assert name == "events_payment_mode_exclusive"
      assert reload(event).deposit_enabled == false
      assert reload(event).pricing_enabled == false
    end
  end

  describe "押金 ⇒ 档位为空（#597）" do
    test "已有休眠档位的 Event 开押金 → 被拒，档位原样保留（拒绝不是清理）", ctx do
      {:ok, event} = create_event(ctx, %{price_tiers: dormant_tiers()})

      assert {:error, _} = result = update_event(ctx, event, deposit_attrs())

      assert_business_code(result, "event_deposit_price_tiers_conflict")
      reloaded = reload(event)
      assert reloaded.deposit_enabled == false
      assert reloaded.price_tiers == event.price_tiers
    end

    test "create 同时开押金与非空档位 → 被拒，错误码稳定", ctx do
      assert {:error, _} =
               result = create_event(ctx, Map.put(deposit_attrs(), :price_tiers, dormant_tiers()))

      assert_business_code(result, "event_deposit_price_tiers_conflict")
    end

    test "同一次写携带 price_tiers: [] → 开押金成功（调用方补救面）", ctx do
      {:ok, event} = create_event(ctx, %{price_tiers: dormant_tiers()})

      assert {:ok, updated} = update_event(ctx, event, Map.put(deposit_attrs(), :price_tiers, []))

      assert updated.deposit_enabled == true
      assert updated.price_tiers == []
    end

    test "已开押金的 Event 单独补写非空档位 → 被拒", ctx do
      {:ok, event} = create_event(ctx, deposit_attrs())

      assert {:error, _} = result = update_event(ctx, event, %{price_tiers: dormant_tiers()})

      assert_business_code(result, "event_deposit_price_tiers_conflict")
      assert reload(event).price_tiers == []
    end

    test "押金场改标题（不触档位）→ 通过（不锁死无关编辑）", ctx do
      {:ok, event} = create_event(ctx, deposit_attrs())

      assert {:ok, updated} = update_event(ctx, event, %{title: "PM renamed by 597"})
      assert updated.title == "PM renamed by 597"
    end

    test "裸 SQL 在押金场写档位（并发/旁路模拟）→ DB CHECK 拒绝，约束名稳定", ctx do
      {:ok, event} = create_event(ctx, deposit_attrs())

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation, constraint: name}}} =
               Cgc2046.Repo.query(
                 "UPDATE events SET price_tiers = $1::jsonb WHERE id = $2",
                 [
                   Jason.encode!(dormant_tiers()),
                   Ecto.UUID.dump!(event.id)
                 ]
               )

      assert name == "events_deposit_excludes_price_tiers"
      assert reload(event).price_tiers == []
    end

    test "对称残留（定价开 + 押金金额残留）被显式允许（#597 裁决 I6/I7 不立）", ctx do
      {:ok, event} = create_event(ctx, deposit_attrs())

      assert {:ok, priced} =
               update_event(ctx, event, %{
                 deposit_enabled: false,
                 pricing_enabled: true,
                 price_tiers: dormant_tiers()
               })

      assert priced.pricing_enabled == true
      assert priced.deposit_enabled == false
      # 金额残留惰性保留：资金路径全部以 deposit_enabled 门控
      # （enrollment.ex:869 模式匹配 / :987 if(deposit_enabled, ...)）
      assert priced.deposit_amount_cents == 3000

      # 残留不制造任何写入阻碍
      assert {:ok, renamed} = update_event(ctx, priced, %{title: "still editable"})
      assert renamed.title == "still editable"
    end
  end

  describe "并发兜底错误映射（#597）" do
    # 直接调 validate/3：集成用例经 handle_write_error 与 DB CHECK 也能拿到同一 code
    # （单源同码，见 PaymentModeValidation.price_tiers_conflict_error/1），故**域子句
    # 本体**需纯函数钉住——否则删掉该子句后集成用例仍绿（DB CHECK 兜底）。
    test "域校验子句本体：押金 + 非空档位 → 不落库即返回稳定业务错误" do
      changeset =
        Ash.Changeset.for_create(
          Event,
          :create,
          Map.put(deposit_attrs(), :price_tiers, dormant_tiers())
        )

      assert {:error,
              %BusinessError{
                code: "event_deposit_price_tiers_conflict",
                fields: [:price_tiers]
              }} = PaymentModeValidation.validate(changeset, [], %{})

      # 定价关闭但档位非空（无押金）仍合法（R4），域子句不得不误伤
      assert :ok =
               PaymentModeValidation.validate(
                 Ash.Changeset.for_create(Event, :create, %{price_tiers: dormant_tiers()}),
                 [],
                 %{}
               )
    end

    test "五条缴费 CHECK 冲突按约束名映射到各自稳定 code，未映射/非 check 错误原样上抛" do
      tiers_conflict = %Ash.Error.Changes.InvalidAttribute{
        field: :price_tiers,
        private_vars: [
          constraint_type: :check,
          constraint: "events_deposit_excludes_price_tiers"
        ]
      }

      assert %BusinessError{
               code: "event_deposit_price_tiers_conflict",
               fields: [:price_tiers]
             } = Event.handle_write_error(nil, tiers_conflict)

      exclusive_conflict = %Ash.Error.Changes.InvalidAttribute{
        field: :deposit_enabled,
        private_vars: [constraint_type: :check, constraint: "events_payment_mode_exclusive"]
      }

      assert %BusinessError{code: "event_payment_mode_exclusive"} =
               Event.handle_write_error(nil, exclusive_conflict)

      # #608 / #623：三条押金锚点 CHECK 显式按名分派（缺子句会被误报成互斥码）
      for {constraint, code, fields} <- [
            {"events_deposit_requires_registration_deadline",
             "event_deposit_registration_deadline_required", [:registration_deadline]},
            {"events_deposit_requires_ends_at", "event_deposit_ends_at_required", [:ends_at]},
            {"events_deposit_requires_positive_amount", "event_deposit_amount_required",
             [:deposit_amount_cents]}
          ] do
        assert %BusinessError{code: ^code, fields: ^fields} =
                 Event.handle_write_error(
                   nil,
                   %Ash.Error.Changes.InvalidAttribute{
                     field: :deposit_enabled,
                     private_vars: [constraint_type: :check, constraint: constraint]
                   }
                 )
      end

      # fail-closed（#623 D5）：未显式映射的 CHECK 冲突不得吞成任何业务码
      # （泛化兜底已删——加回即被本断言钉红）
      unknown_check = %Ash.Error.Changes.InvalidAttribute{
        field: :title,
        private_vars: [constraint_type: :check, constraint: "events_future_check"]
      }

      assert Event.handle_write_error(nil, unknown_check) == unknown_check

      # fail-closed：非 check 冲突（DB 真故障 / 其它约束）不得吞成业务错误
      other = %Ash.Error.Changes.InvalidAttribute{field: :title, message: "boom"}
      assert Event.handle_write_error(nil, other) == other
    end
  end

  describe "押金锚点 CHECK（#608 / #623，NOT VALID 兜底）" do
    # 裸 SQL 绕过域层（并发/旁路模拟）：每条 UPDATE **只违反一条** CHECK，其余锚点
    # 写有效值——多约束同时违反时 Postgres 只报其中一条，归因必须确定。
    # 时间列用 SQL NOW() 而非 Elixir 参数（timestamp 无时区，避免 Postgrex 编码坑）。
    test "押金开 + 报名截止空 → events_deposit_requires_registration_deadline 拒绝", ctx do
      {:ok, event} = create_event(ctx, %{})

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation, constraint: name}}} =
               Cgc2046.Repo.query(
                 """
                 UPDATE events
                    SET deposit_enabled = true,
                        registration_deadline = NULL,
                        ends_at = NOW() + interval '1 day',
                        deposit_amount_cents = 3000
                  WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(event.id)]
               )

      assert name == "events_deposit_requires_registration_deadline"
      refute reload(event).deposit_enabled
    end

    test "押金开 + ends_at 空 → events_deposit_requires_ends_at 拒绝", ctx do
      {:ok, event} = create_event(ctx, %{})

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation, constraint: name}}} =
               Cgc2046.Repo.query(
                 """
                 UPDATE events
                    SET deposit_enabled = true,
                        ends_at = NULL,
                        registration_deadline = NOW() + interval '1 day',
                        deposit_amount_cents = 3000
                  WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(event.id)]
               )

      assert name == "events_deposit_requires_ends_at"
      refute reload(event).deposit_enabled
    end

    test "押金开 + 金额 0 / NULL → events_deposit_requires_positive_amount 拒绝", ctx do
      {:ok, event} = create_event(ctx, %{})

      for amount <- [0, nil] do
        assert {:error, %Postgrex.Error{postgres: %{code: :check_violation, constraint: name}}} =
                 Cgc2046.Repo.query(
                   """
                   UPDATE events
                      SET deposit_enabled = true,
                          deposit_amount_cents = $2::integer,
                          registration_deadline = NOW() + interval '1 day',
                          ends_at = NOW() + interval '1 day'
                    WHERE id = $1
                   """,
                   [Ecto.UUID.dump!(event.id), amount]
                 )

        assert name == "events_deposit_requires_positive_amount"
      end

      refute reload(event).deposit_enabled
    end
  end

  describe "押金开启必填项（R3 / KTD7 锚点）" do
    test "开押金但金额为空 → 被拒，错误码稳定", ctx do
      assert {:error, _} =
               result =
               update_event(ctx, elem(create_event(ctx, %{}), 1), %{
                 deposit_enabled: true,
                 ends_at: EventFixtures.days_from_now(3),
                 registration_deadline: EventFixtures.days_from_now(3)
               })

      assert_business_code(result, "event_deposit_amount_required")
    end

    test "开押金但金额为 0 → 被拒，错误码稳定", ctx do
      assert {:error, _} =
               result =
               create_event(ctx, %{
                 deposit_enabled: true,
                 deposit_amount_cents: 0,
                 ends_at: EventFixtures.days_from_now(3),
                 registration_deadline: EventFixtures.days_from_now(3)
               })

      assert_business_code(result, "event_deposit_amount_required")
    end

    test "开押金但 ends_at 为空 → 被拒，错误码稳定", ctx do
      assert {:error, _} =
               result =
               create_event(ctx, %{deposit_enabled: true, deposit_amount_cents: 3000})

      assert_business_code(result, "event_deposit_ends_at_required")
    end
  end

  describe "ends_at 冻结守卫（adversarial P1）" do
    test "存在未终态押金单时禁止 ends_at 前移", ctx do
      event =
        EventFixtures.create_event(ctx.workspace, ctx.admin, %{
          deposit_enabled: true,
          deposit_amount_cents: 6900,
          ends_at: EventFixtures.days_from_now(8),
          registration_deadline: EventFixtures.days_from_now(8)
        })

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
        VALUES (gen_random_uuid(),
          $1::uuid,
          'deposit', 6900, 'wechat_native', 'paid', 'frozen-txn',
          NOW() + INTERVAL '2 hours', NOW(), NOW(),
          $2::uuid, '{"name":"\u62bc\u91d1","amount_cents":6900}')
        """,
        [Ecto.UUID.dump!(enrollment.id), Ecto.UUID.dump!(ctx.workspace.id)]
      )

      assert {:error, _} =
               result =
               update_event(ctx, event, %{ends_at: EventFixtures.days_from_now(1)})

      assert_business_code(result, "event_ends_at_frozen")
    end

    test "无押金单时 ends_at 可前移（守卫不触发）", ctx do
      event =
        EventFixtures.create_event(ctx.workspace, ctx.admin, %{
          deposit_enabled: true,
          deposit_amount_cents: 6900,
          ends_at: EventFixtures.days_from_now(8),
          registration_deadline: EventFixtures.days_from_now(8)
        })

      assert {:ok, _} =
               update_event(ctx, event, %{ends_at: EventFixtures.days_from_now(2)})
    end
  end

  # #587 时代的「存量行不被锁死」用例前提（裸 SQL 制造脏行后验证无关编辑可通过）
  # 已被三条锚点 CHECK 封死：脏行只在迁移前存在（生产普查 0 行 / dev 2 行），库内
  # 无法再制造——NOT VALID 对存量行的 UPDATE 同样生效，故存量行解锁 = 回填 +
  # VALIDATE（issue #634）。这里钉住「不可再制造」与「修复方向仍开放」两侧。
  describe "存量脏行（#608 / #634）" do
    test "押金已开的场无法再写空 ends_at；反向补锚点仍可写", ctx do
      {:ok, event} =
        create_event(ctx, %{
          deposit_enabled: true,
          deposit_amount_cents: 6900,
          ends_at: EventFixtures.days_from_now(3),
          registration_deadline: EventFixtures.days_from_now(3)
        })

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation, constraint: name}}} =
               Cgc2046.Repo.query("UPDATE events SET ends_at = NULL WHERE id = $1", [
                 Ecto.UUID.dump!(event.id)
               ])

      assert name == "events_deposit_requires_ends_at"

      # 域路径补锚点（反向）不受影响：新行版本满足 CHECK
      assert {:ok, fixed} =
               update_event(ctx, reload(event), %{ends_at: EventFixtures.days_from_now(5)})

      assert fixed.ends_at != nil
      assert fixed.deposit_amount_cents == 6900
    end
  end

  describe "独立使用（AE2 / Initiative 计划 AE12）" do
    test "未挂载 Initiative 的 Event 开押金 30 元 → 成功", ctx do
      ends_at = EventFixtures.days_from_now(3) |> DateTime.truncate(:second)
      deadline = EventFixtures.days_from_now(2) |> DateTime.truncate(:second)

      assert {:ok, event} =
               create_event(ctx, %{
                 deposit_enabled: true,
                 deposit_amount_cents: 3000,
                 ends_at: ends_at,
                 registration_deadline: deadline
               })

      assert event.deposit_enabled == true
      assert event.deposit_amount_cents == 3000
      assert event.initiative_id == nil
      assert DateTime.compare(event.ends_at, ends_at) == :eq
    end
  end
end
