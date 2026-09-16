defmodule Cgc2046.Initiatives.RulePropagationTest do
  @moduledoc """
  issue #587：锁死规则传播（`RuleInheritance.propagate_rule_change/4`）契约。

  1. **账本同事务同步**：`deadline_rule` 传播后 `admission_capacity_ledgers`
     缓存列即刻等于 events 真值（不等任何信号 / worker），报名窗按新截止
     执法；且**有意不发** `offering.capacity_changed`。
  2. **押金不变量**：规则写入（挂载 + 传播）不得把场从「满足」翻成
     「押金开 + 报名截止空」；违规即拒绝整次规则更新并回滚，错误带 event_id。
  3. **范围**：只传播 draft / open；closed / cancelled 场连同账本缓存不变，
     且终态定价场不再阻断押金规则传播。
  4. **不重算成班事实**：改 min_participants 不动 qualification_status、不重发通知。
  5. **审计**：规则变更行 metadata 含 value_before / value_after / locked_before。
  """

  use Cgc2046.DataCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  require Ash.Query

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.AccountsFixtures, as: F
  alias Cgc2046.Admission.{CapacityLedger, Enrollment}
  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Events.{Event, Qualification}
  alias Cgc2046.EventsFixtures, as: EF
  alias Cgc2046.Initiatives.{Initiative, InitiativeRule}
  alias Cgc2046.Notifications.NotificationDelivery
  alias Cgc2046.Reconciliation.{Finding, ReconciliationScanWorker}
  alias Cgc2046.Repo
  alias Cgc2046.Workflows.SignalPublishWorker

  setup do
    admin = F.platform_admin("rule-propagation")

    %{
      admin: admin,
      workspace: F.create_workspace(admin),
      learner: F.register_user("rule-propagation-learner")
    }
  end

  # ── 验收 1：账本同事务同步 ────────────────────────────────────────────────

  test "deadline_rule 传播在同一事务内同步账本缓存且不发信号", ctx do
    initiative =
      open_initiative(ctx.admin, "prop-sync", %{deadline_rule: {%{hours_before_start: 250}, true}})

    event = mounted_open(ctx.workspace, ctx.admin, initiative, %{starts_at: EF.days_from_now(10)})

    # 挂载时锁死 deadline_rule 已写入 starts_at - 250h（已过去的截止）
    assert DateTime.compare(event.registration_deadline, DateTime.utc_now()) == :lt
    # 账本行与真值一致（未漂移的起点）
    assert :ok = CapacityLedger.sync_from_offering(event)
    assert ledger(event).registration_deadline == event.registration_deadline

    # 挂载快照了未锁默认规则（min_participants 8）——账本 CAS 仍是截止守卫之一
    assert event.min_participants == 8

    jobs_before = capacity_changed_jobs()

    assert {:ok, _} =
             update_rule(
               initiative,
               :deadline_rule,
               %{value: %{hours_before_start: 200}},
               ctx.admin
             )

    reloaded = reload(event)
    assert DateTime.compare(reloaded.registration_deadline, DateTime.utc_now()) == :gt
    # 同事务收敛：读账本不经任何信号投递 / worker
    assert ledger(event).registration_deadline == reloaded.registration_deadline
    # 有意静默路径（issue #587 D5）：规则传播不发 offering.capacity_changed
    assert capacity_changed_jobs() == jobs_before
    # 放宽后报名立即可成功（修复前账本陈旧会被 CAS 误拒）
    assert {:ok, _} = enroll(reloaded, ctx.learner)
  end

  test "deadline_rule 缩窄同样同事务收敛并立即关窗", ctx do
    initiative =
      open_initiative(ctx.admin, "prop-narrow", %{
        deadline_rule: {%{hours_before_start: 200}, true}
      })

    event = mounted_open(ctx.workspace, ctx.admin, initiative, %{starts_at: EF.days_from_now(10)})
    assert :ok = CapacityLedger.sync_from_offering(event)
    assert DateTime.compare(event.registration_deadline, DateTime.utc_now()) == :gt

    assert {:ok, _} =
             update_rule(
               initiative,
               :deadline_rule,
               %{value: %{hours_before_start: 250}},
               ctx.admin
             )

    reloaded = reload(event)
    assert DateTime.compare(reloaded.registration_deadline, DateTime.utc_now()) == :lt
    assert ledger(event).registration_deadline == reloaded.registration_deadline
    assert {:error, _} = enroll(reloaded, ctx.learner)
  end

  test "规则传播后对账规12 无 ledger_cache_drift", ctx do
    initiative =
      open_initiative(ctx.admin, "prop-recon", %{
        deadline_rule: {%{hours_before_start: 250}, true}
      })

    event = mounted_open(ctx.workspace, ctx.admin, initiative, %{starts_at: EF.days_from_now(10)})
    assert :ok = CapacityLedger.sync_from_offering(event)

    assert {:ok, _} =
             update_rule(
               initiative,
               :deadline_rule,
               %{value: %{hours_before_start: 200}},
               ctx.admin
             )

    assert :ok = perform_job(ReconciliationScanWorker, %{})
    assert findings(:ledger_cache_drift) == []
  end

  # ── 验收 2：押金不变量（传播路径）────────────────────────────────────────

  test "deadline_rule 传播会把押金场的报名截止写空 → 拒绝整次规则更新并回滚", ctx do
    initiative =
      open_initiative(ctx.admin, "prop-nil-deadline", %{
        deposit: {%{enabled: true, amount_cents: 6900}, true},
        deadline_rule: {%{hours_before_start: 72}, false}
      })

    event =
      mounted_open(ctx.workspace, ctx.admin, initiative, %{
        starts_at: EF.days_from_now(10),
        registration_deadline: EF.days_from_now(7)
      })

    assert event.deposit_enabled == true
    assert event.deposit_amount_cents == 6900

    # 解除档期（时间待定）：deadline_rule 未锁 → 报名截止保留，此刻不变量满足
    event =
      event
      |> Ash.Changeset.for_update(:update, %{starts_at: nil})
      |> Ash.update!(actor: ctx.admin, tenant: ctx.workspace.id)

    assert is_nil(event.starts_at)
    refute is_nil(event.registration_deadline)

    before = event_snapshot(event)

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             update_rule(
               initiative,
               :deadline_rule,
               %{value: %{hours_before_start: 72}, locked: true},
               ctx.admin
             )

    assert deadline_invariant_error?(errors, event.id)

    # 整次规则更新回滚：规则值 / 锁标记未变，场字段未变
    reloaded_rule = rule(initiative, :deadline_rule, ctx.admin)
    assert reloaded_rule.locked == false
    assert reloaded_rule.value == %{"hours_before_start" => 72}
    assert event_snapshot(event) == before
  end

  test "deposit 规则传播到报名截止为空的场 → 拒绝，不新建违规态", ctx do
    initiative =
      open_initiative(ctx.admin, "prop-deposit-nil", %{deposit: {%{enabled: false}, true}})

    event =
      mounted_open(ctx.workspace, ctx.admin, initiative, %{
        starts_at: nil,
        registration_deadline: nil
      })

    assert is_nil(event.registration_deadline)
    assert event.deposit_enabled == false

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             update_rule(
               initiative,
               :deposit,
               %{value: %{enabled: true, amount_cents: 6900}},
               ctx.admin
             )

    assert deadline_invariant_error?(errors, event.id)
    assert reload(event).deposit_enabled == false
  end

  # ── 验收 2：押金不变量（挂载路径，issue #587 §0-4）──────────────────────

  test "押金规则挂载到报名截止为空的场 → 拒绝，不产生「押金开 + 截止空」", ctx do
    initiative =
      open_initiative(ctx.admin, "prop-mount-guard", %{
        deposit: {%{enabled: true, amount_cents: 6900}, true}
      })

    assert {:error, error} =
             create_mounted(ctx.workspace, ctx.admin, initiative, %{
               starts_at: nil,
               registration_deadline: nil
             })

    assert deadline_invariant_error?(error.errors, nil)
    assert Ash.read!(Event, authorize?: false) == []
  end

  test "非押金场的 starts_at 为空仍写 nil 报名截止（语义不变）", ctx do
    initiative =
      open_initiative(ctx.admin, "prop-nil-start", %{
        deadline_rule: {%{hours_before_start: 72}, true}
      })

    event = mounted_open(ctx.workspace, ctx.admin, initiative, %{starts_at: nil})

    assert is_nil(event.starts_at)
    assert is_nil(event.registration_deadline)
    assert event.deposit_enabled == false
  end

  # ── 验收 3：终态场冻结 ───────────────────────────────────────────────────

  test "closed / cancelled 场在规则变更后完全不变，终态定价场不再阻断", ctx do
    initiative =
      open_initiative(ctx.admin, "prop-terminal", %{
        deposit: {%{enabled: false}, true},
        deadline_rule: {%{hours_before_start: 72}, true},
        min_participants: {%{count: 8}, true},
        age_gate: {%{min_age: 18}, true}
      })

    open_event =
      mounted_open(ctx.workspace, ctx.admin, initiative, %{starts_at: EF.days_from_now(10)})

    closed_event =
      ctx.workspace
      |> mounted_open(ctx.admin, initiative, %{starts_at: EF.days_from_now(10)})
      |> force_event_status("closed")

    cancelled_event =
      ctx.workspace
      |> mounted_open(ctx.admin, initiative, %{starts_at: EF.days_from_now(10)})
      |> force_event_status("cancelled")

    # 终态 + 已开定价：修复前会阻断整次押金规则更新（错误只给一个 event_id）
    priced_closed =
      ctx.workspace
      |> mounted_open(ctx.admin, initiative, %{starts_at: EF.days_from_now(10)})
      |> force_event_status("closed")
      |> force_priced()

    terminal = [closed_event, cancelled_event, priced_closed]

    for event <- [open_event | terminal],
        do: assert(:ok = CapacityLedger.sync_from_offering(event))

    snapshots = Map.new(terminal, &{&1.id, event_snapshot(&1)})
    ledgers_before = Map.new(terminal, &{&1.id, ledger(&1).registration_deadline})

    assert {:ok, _} =
             update_rule(
               initiative,
               :deposit,
               %{value: %{enabled: true, amount_cents: 6900}},
               ctx.admin
             )

    assert {:ok, _} =
             update_rule(
               initiative,
               :deadline_rule,
               %{value: %{hours_before_start: 48}},
               ctx.admin
             )

    assert {:ok, _} =
             update_rule(initiative, :min_participants, %{value: %{count: 4}}, ctx.admin)

    assert {:ok, _} = update_rule(initiative, :age_gate, %{value: %{min_age: 21}}, ctx.admin)

    for event <- terminal do
      assert event_snapshot(event) == snapshots[event.id]
      assert ledger(event).registration_deadline == ledgers_before[event.id]
    end

    # 终态定价场不被写入押金（前置守卫已按传播集合收窄）
    assert reload(priced_closed).deposit_enabled == false

    # 非终态场确实收到了传播
    reloaded_open = reload(open_event)
    assert reloaded_open.deposit_enabled == true
    assert reloaded_open.deposit_amount_cents == 6900
    assert reloaded_open.min_age == 21
    assert reloaded_open.min_participants == 4

    assert reloaded_open.registration_deadline ==
             DateTime.add(reloaded_open.starts_at, -48, :hour)
  end

  # ── 验收 5：成班事实不重算 ───────────────────────────────────────────────

  test "改 min_participants 不重算已成班事实、不重发通知", ctx do
    initiative =
      open_initiative(ctx.admin, "prop-qualified", %{min_participants: {%{count: 2}, true}})

    event = mounted_open(ctx.workspace, ctx.admin, initiative, %{starts_at: EF.days_from_now(10)})
    assert event.min_participants == 2

    learner2 = F.register_user("rule-propagation-learner-2")
    assert {:ok, _} = enroll(event, ctx.learner)
    assert {:ok, _} = enroll(event, learner2)

    # 到点（布置）：报名截止推入过去后跑一次成班判定
    Repo.query!(
      "UPDATE events SET registration_deadline = NOW() - INTERVAL '1 hour' WHERE id = $1",
      [Ecto.UUID.dump!(event.id)]
    )

    assert {:ok, :confirmed, _recipients, 2} = Qualification.qualify(reload(event))

    deliveries_before = length(Ash.read!(NotificationDelivery, authorize?: false))

    assert {:ok, _} =
             update_rule(initiative, :min_participants, %{value: %{count: 5}}, ctx.admin)

    reloaded = reload(event)
    assert reloaded.min_participants == 5
    assert reloaded.qualification_status == :confirmed
    assert length(Ash.read!(NotificationDelivery, authorize?: false)) == deliveries_before
  end

  # ── 验收 4：审计记值前后 ─────────────────────────────────────────────────

  test "规则变更审计含值前后", ctx do
    initiative =
      open_initiative(ctx.admin, "prop-audit", %{
        deposit: {%{enabled: true, amount_cents: 6900}, true}
      })

    assert {:ok, _} =
             update_rule(
               initiative,
               :deposit,
               %{value: %{enabled: true, amount_cents: 5900}},
               ctx.admin
             )

    logs =
      AdminActionLog
      |> Ash.Query.filter(action == :initiative_rule_update)
      |> Ash.read!(authorize?: false)

    assert [log] =
             Enum.filter(
               logs,
               &(get_in(&1.metadata, ["value_after", "amount_cents"]) == 5900)
             )

    assert log.metadata["value_before"] == %{"enabled" => true, "amount_cents" => 6900}
    assert log.metadata["value_after"] == %{"enabled" => true, "amount_cents" => 5900}
    assert log.metadata["locked"] == true
    assert log.metadata["locked_before"] == true
    assert log.metadata["rule_key"] == "deposit"
    assert log.metadata["initiative_id"] == initiative.id
  end

  # ── 附带缺陷：押金 × 定价判据取自 changeset（D6）─────────────────────────

  test "押金规则挂载到已开定价的场 → 稳定 code，判据取自 changeset", ctx do
    initiative =
      open_initiative(ctx.admin, "prop-pricing", %{
        deposit: {%{enabled: true, amount_cents: 6900}, true}
      })

    assert {:error, error} =
             create_mounted(ctx.workspace, ctx.admin, initiative, %{
               pricing_enabled: true,
               price_tiers: [
                 %{"id" => Ash.UUID.generate(), "name" => "标准", "amount_cents" => 19_900}
               ]
             })

    assert Enum.any?(
             error.errors,
             &match?(
               %BusinessError{code: "event_payment_mode_exclusive", fields: :pricing_enabled},
               &1
             )
           )

    assert Ash.read!(Event, authorize?: false) == []
  end

  # ── 布置助手 ─────────────────────────────────────────────────────────────

  defp open_initiative(admin, slug, rule_overrides) do
    initiative =
      Initiative
      |> Ash.Changeset.for_create(:create, %{
        name: "传播 #{slug}",
        slug: slug,
        created_by: admin.id
      })
      |> Ash.create!(actor: admin)

    for {key, {value, locked}} <- Map.merge(default_rules(), rule_overrides) do
      InitiativeRule
      |> Ash.Changeset.for_create(:create, %{
        initiative_id: initiative.id,
        key: key,
        value: value,
        locked: locked
      })
      |> Ash.create!(actor: admin)
    end

    initiative
    |> Ash.Changeset.for_update(:open, %{})
    |> Ash.update!(actor: admin)
  end

  defp default_rules do
    %{
      deposit: {%{enabled: false}, false},
      age_gate: {%{min_age: 18}, false},
      min_participants: {%{count: 8}, false},
      deadline_rule: {%{hours_before_start: 72}, false}
    }
  end

  defp rule(initiative, key, admin) do
    InitiativeRule
    |> Ash.Query.filter(initiative_id == ^initiative.id and key == ^key)
    |> Ash.read_one!(actor: admin)
  end

  defp update_rule(initiative, key, attrs, admin) do
    initiative
    |> rule(key, admin)
    |> Ash.Changeset.for_update(:update, attrs)
    |> Ash.update(actor: admin)
  end

  # 已挂载 + open（force_open 走裸 SQL，无 launched 信号 → 无账本行）
  defp mounted_open(workspace, admin, initiative, attrs) do
    EF.create_event(workspace, admin, Map.put(attrs, :initiative_id, initiative.id))
  end

  # 已挂载 + draft（挂载/规则写入的边界要求 draft）
  defp create_mounted(workspace, admin, initiative, attrs) do
    defaults = %{
      title: "传播草稿场",
      enrollment_policy: :open,
      starts_at: EF.days_from_now(10),
      ends_at: EF.days_from_now(11),
      initiative_id: initiative.id
    }

    Event
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs), tenant: workspace.id)
    |> Ash.create(actor: admin, tenant: workspace.id)
  end

  defp reload(event), do: Ash.get!(Event, event.id, authorize?: false)

  defp ledger(event) do
    {:ok, ledger} = CapacityLedger.fetch_by_offering(:event, event.id)
    ledger
  end

  defp enroll(event, learner) do
    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, %{event_id: event.id, user_id: learner.id})
    |> Ash.create(actor: learner, tenant: event.workspace_id)
  end

  # 布置而非被测对象（force_open 同款纪律）：状态机与定价列直写
  defp force_event_status(event, status) do
    Repo.query!("UPDATE events SET status = $1 WHERE id = $2", [
      status,
      Ecto.UUID.dump!(event.id)
    ])

    reload(event)
  end

  defp force_priced(event) do
    Repo.query!("UPDATE events SET pricing_enabled = true WHERE id = $1", [
      Ecto.UUID.dump!(event.id)
    ])

    reload(event)
  end

  defp event_snapshot(event) do
    Map.take(reload(event), [
      :status,
      :registration_deadline,
      :deposit_enabled,
      :deposit_amount_cents,
      :min_age,
      :min_participants,
      :qualification_status,
      :updated_at
    ])
  end

  defp capacity_changed_jobs do
    all_enqueued(worker: SignalPublishWorker)
    |> Enum.filter(&(&1.args["signal_type"] == "offering.capacity_changed"))
  end

  defp findings(rule) do
    Finding
    |> Ash.Query.filter(rule == ^rule)
    |> Ash.read!(authorize?: false)
  end

  # 持仓路径（创建）无 event_id 可指 → 只断言 code；带场 id 时同时断言定位
  defp deadline_invariant_error?(errors, nil) do
    Enum.any?(
      errors,
      &match?(
        %BusinessError{code: "event_deposit_registration_deadline_required", fields: _},
        &1
      )
    )
  end

  defp deadline_invariant_error?(errors, event_id) do
    Enum.any?(errors, fn
      %BusinessError{code: "event_deposit_registration_deadline_required", fields: fields} ->
        fields[:event_id] == event_id

      _ ->
        false
    end)
  end
end
