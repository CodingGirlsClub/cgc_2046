defmodule Cgc2046.Initiatives.RuleDeadlineFreezeTest do
  @moduledoc """
  锁死规则路径的报名截止冻结回归（Codex review P1）。

  `RuleInheritance` 的两条写入路径都不经 `Event` 的资源级 `validate`
  （`PaymentModeValidation` moduledoc 自陈覆盖边界）：
  - 锁死规则传播 `propagate_rule_change/4` 走裸 SQL（`write_propagated`）；
  - 挂载 `prepare_event_changes` 在 `before_action` 里 force。

  因此资源层新增的 deadline 前移冻结守卫对它们无效：缩短锁死的
  `deadline_rule`（hours_before_start 变大 ⇒ 截止更早）仍能把在场押金单的
  自助取消退款窗口追溯关闭。本文件钉住两条路径都受同一守卫约束。
  """

  use Cgc2046.DataCase, async: true

  require Ash.Query

  alias Cgc2046.AccountsFixtures, as: F
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Events.Event
  alias Cgc2046.EventsFixtures, as: EF
  alias Cgc2046.Initiatives.{Initiative, InitiativeRule}

  setup do
    admin = F.platform_admin("rule-deadline-freeze")

    %{admin: admin, workspace: F.create_workspace(admin), learner: F.register_user("rdf-learner")}
  end

  defp open_initiative(admin, slug) do
    initiative =
      Initiative
      |> Ash.Changeset.for_create(:create, %{name: "冻结 #{slug}", slug: slug, created_by: admin.id})
      |> Ash.create!(actor: admin)

    for {key, value} <- %{
          deposit: %{enabled: true, amount_cents: 6900},
          age_gate: %{min_age: 18},
          min_participants: %{count: 8},
          deadline_rule: %{hours_before_start: 72}
        } do
      InitiativeRule
      |> Ash.Changeset.for_create(:create, %{
        initiative_id: initiative.id,
        key: key,
        value: value,
        locked: true
      })
      |> Ash.create!(actor: admin)
    end

    initiative
    |> Ash.Changeset.for_update(:open, %{})
    |> Ash.update!(actor: admin)
  end

  defp mounted_open(workspace, admin, initiative) do
    EF.create_event(workspace, admin, %{
      starts_at: EF.days_from_now(10),
      ends_at: EF.days_from_now(11),
      initiative_id: initiative.id
    })
  end

  defp add_paid_deposit_order(ctx, event) do
    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{
        event_id: event.id,
        user_id: ctx.learner.id,
        age_confirmed: true
      })
      |> Ash.create(actor: ctx.learner, tenant: event.workspace_id)

    Cgc2046.Repo.query!(
      """
      INSERT INTO payments_orders (id, enrollment_id, order_kind, amount_cents,
        provider, status, out_trade_no, expire_at, inserted_at, updated_at, workspace_id, tier_snapshot)
      VALUES (gen_random_uuid(), $1::uuid, 'deposit', 6900, 'wechat_native', 'paid',
        'rdf-txn', NOW() + INTERVAL '2 hours', NOW(), NOW(), $2::uuid,
        '{"name":"押金","amount_cents":6900}')
      """,
      [Ecto.UUID.dump!(enrollment.id), Ecto.UUID.dump!(event.workspace_id)]
    )

    :ok
  end

  defp update_rule(initiative, key, attrs, admin) do
    InitiativeRule
    |> Ash.Query.filter(initiative_id == ^initiative.id and key == ^key)
    |> Ash.read_one!(actor: admin)
    |> Ash.Changeset.for_update(:update, attrs)
    |> Ash.update(actor: admin)
  end

  defp assert_business_code({:error, %Ash.Error.Invalid{errors: errors}}, expected) do
    assert Enum.any?(errors, &match?(%BusinessError{code: ^expected}, &1)),
           "expected BusinessError code #{expected}, got: #{inspect(errors)}"
  end

  test "锁死规则传播：存在未终态押金单时禁止把 deadline 改早", ctx do
    initiative = open_initiative(ctx.admin, "rdf-prop")
    event = mounted_open(ctx.workspace, ctx.admin, initiative)
    :ok = add_paid_deposit_order(ctx, event)

    before = Ash.get!(Event, event.id, authorize?: false).registration_deadline

    # hours_before_start 变大 ⇒ 截止更早
    result =
      update_rule(initiative, :deadline_rule, %{value: %{hours_before_start: 200}}, ctx.admin)

    assert_business_code(result, "event_registration_deadline_frozen")
    assert Ash.get!(Event, event.id, authorize?: false).registration_deadline == before
  end

  test "锁死规则传播：无押金单时可改早（守卫不触发）", ctx do
    initiative = open_initiative(ctx.admin, "rdf-prop-ok")
    _event = mounted_open(ctx.workspace, ctx.admin, initiative)

    assert {:ok, _} =
             update_rule(
               initiative,
               :deadline_rule,
               %{value: %{hours_before_start: 200}},
               ctx.admin
             )
  end

  test "锁死规则传播：后移 deadline 不受影响（存单也在）", ctx do
    initiative = open_initiative(ctx.admin, "rdf-prop-later")
    event = mounted_open(ctx.workspace, ctx.admin, initiative)
    :ok = add_paid_deposit_order(ctx, event)

    # hours_before_start 变小 ⇒ 截止更晚
    assert {:ok, _} =
             update_rule(
               initiative,
               :deadline_rule,
               %{value: %{hours_before_start: 24}},
               ctx.admin
             )
  end

  test "挂载路径：force 写入更早的 deadline 时同样受守卫约束", ctx do
    # 场景：场次曾经 open 并收过押金，后被退回 draft（历史 / 重挂载），此时挂载到
    # 一个锁死 deadline_rule 更早的 Initiative——挂载在 before_action force 写入，
    # 资源级 validate 看不见（见 PaymentModeValidation moduledoc 覆盖边界）。
    initiative = open_initiative(ctx.admin, "rdf-mount")

    event = mounted_open(ctx.workspace, ctx.admin, initiative)
    :ok = add_paid_deposit_order(ctx, event)

    # 记录挂载前 deadline，退回 draft 以便重挂载
    before = Ash.get!(Event, event.id, authorize?: false).registration_deadline

    Cgc2046.Repo.query!(
      "UPDATE events SET status = 'draft', initiative_id = NULL, updated_at = NOW() WHERE id = $1",
      [Ecto.UUID.dump!(event.id)]
    )

    # 裸 SQL 写过 → 必须重新加载（Ash 乐观锁，否则 StaleRecord「event changed」）
    reloaded = Ash.get!(Event, event.id, authorize?: false)

    # 把锁死规则改成更早的截止（starts_at - 240h）
    assert {:ok, _} =
             update_rule(
               initiative,
               :deadline_rule,
               %{value: %{hours_before_start: 240}},
               ctx.admin
             )

    # 重挂载会把更早的 deadline force 上场 → 必须被拒，且旧值不变
    result =
      reloaded
      |> Ash.Changeset.for_update(:update, %{initiative_id: initiative.id})
      |> Ash.update(actor: ctx.admin, tenant: ctx.workspace.id)

    assert_business_code(result, "event_registration_deadline_frozen")

    after_deadline = Ash.get!(Event, event.id, authorize?: false).registration_deadline
    assert after_deadline == before
  end
end
