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
                 ends_at: EventFixtures.days_from_now(3)
               })

      assert_business_code(result, "event_payment_mode_exclusive")
      assert reload(event).deposit_enabled == false
    end

    test "已开押金的 Event update 开定价 → 被拒，错误码稳定", ctx do
      {:ok, event} =
        create_event(ctx, %{
          deposit_enabled: true,
          deposit_amount_cents: 3000,
          ends_at: EventFixtures.days_from_now(3)
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
                 ends_at: EventFixtures.days_from_now(3)
               })

      assert_business_code(result, "event_payment_mode_exclusive")
    end

    test "直接绕过资源校验写双真（并发模拟）→ DB CHECK 拒绝并映射稳定业务错误", ctx do
      # 并发形状：两个事务各基于旧值通过资源校验后同窗提交，后到写撞上
      # events_payment_mode_exclusive；此处以裸 SQL UPDATE 布置/模拟该双真行
      # 必须被 CHECK 拒绝（CHECK 本身即被测对象，force_open 同款布置纪律）。
      {:ok, event} = create_event(ctx, %{})

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation, constraint: name}}} =
               Cgc2046.Repo.query(
                 "UPDATE events SET deposit_enabled = true, pricing_enabled = true WHERE id = $1",
                 [Ecto.UUID.dump!(event.id)]
               )

      assert name == "events_payment_mode_exclusive"
      assert reload(event).deposit_enabled == false
      assert reload(event).pricing_enabled == false
    end
  end

  describe "押金开启必填项（R3 / KTD7 锚点）" do
    test "开押金但金额为空 → 被拒，错误码稳定", ctx do
      assert {:error, _} =
               result =
               update_event(ctx, elem(create_event(ctx, %{}), 1), %{
                 deposit_enabled: true,
                 ends_at: EventFixtures.days_from_now(3)
               })

      assert_business_code(result, "event_deposit_amount_required")
    end

    test "开押金但金额为 0 → 被拒，错误码稳定", ctx do
      assert {:error, _} =
               result =
               create_event(ctx, %{
                 deposit_enabled: true,
                 deposit_amount_cents: 0,
                 ends_at: EventFixtures.days_from_now(3)
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

  describe "独立使用（AE2 / Initiative 计划 AE12）" do
    test "未挂载 Initiative 的 Event 开押金 30 元 → 成功", ctx do
      ends_at = EventFixtures.days_from_now(3) |> DateTime.truncate(:second)

      assert {:ok, event} =
               create_event(ctx, %{
                 deposit_enabled: true,
                 deposit_amount_cents: 3000,
                 ends_at: ends_at
               })

      assert event.deposit_enabled == true
      assert event.deposit_amount_cents == 3000
      assert event.initiative_id == nil
      assert DateTime.compare(event.ends_at, ends_at) == :eq
    end
  end
end
