defmodule Cgc2046.Initiatives.CancelCascadeTest do
  @moduledoc """
  #628 ②：`Initiative :cancel` 的级联与退款口径（D2/D4 逐条钉住）。

  - **范围**：只级联挂载中仍 `open` 的场；`draft` 场保持 draft（无单无钱，
    且 Event `:cancel` 的 CAS 只吃 open）；`closed` / `cancelled` 场是历史事实，
    零触碰。
  - **退款复用既有链路**：级联只做 `Event :cancel`，退款/通知由既有
    `event.ended` → `OfferingCancelRefundWorker` 承担——本用例经
    `SignalSubscriber.deliver/2`（与生产 forwarder 同码入口）证明退款确实由该
    链路触发，而非本域另写批量走查。
  - **收尾不退款**：`close` 不级联、不入队、不退一分钱。
  - **幂等**：worker 重复执行不重复副作用（逐场 CAS + 计数为 0 时不落审计行）。
  """

  use Cgc2046.DataCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  require Ash.Query

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.AccountsFixtures, as: F
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Admission.Workers.OfferingCancelRefundWorker
  alias Cgc2046.Events.Event
  alias Cgc2046.EventsFixtures, as: EF
  alias Cgc2046.Initiatives.{CancelCascadeWorker, Initiative, InitiativeRule}
  alias Cgc2046.Payments.Order
  alias Cgc2046.Payments.Workers.PaymentRefundWorker
  alias Cgc2046.Workflows.{SignalPublishWorker, SignalSubscriber}

  @tier_id "66666666-6666-6666-6666-666666666666"

  setup do
    admin = F.platform_admin("initiative-cancel-cascade")

    %{
      admin: admin,
      workspace: F.create_workspace(admin),
      learner: F.register_user("cascade-learner")
    }
  end

  test "cancel 级联取消挂载的 open 场并退款（经既有 event.ended 链路）；draft 场不动", ctx do
    initiative = open_initiative(ctx.admin, "cascade-open")

    open_event =
      EF.create_event(ctx.workspace, ctx.admin, %{
        initiative_id: initiative.id,
        pricing_enabled: true,
        price_tiers: [%{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900}]
      })

    enrollment = enroll(ctx.workspace, open_event, ctx.learner)
    paid_order = paid_order(ctx.workspace, enrollment)

    draft_event = draft_mounted(ctx.workspace, ctx.admin, initiative)

    assert {:ok, _} = cancel(initiative, ctx.admin)

    # 同事务 outbox：级联 job 已入队，且终态已落库
    assert_enqueued(worker: CancelCascadeWorker, args: %{"initiative_id" => initiative.id})
    assert status_of(Initiative, initiative.id) == :cancelled

    assert :ok = perform_job(CancelCascadeWorker, %{"initiative_id" => initiative.id})

    assert status_of(Event, open_event.id) == :cancelled
    assert status_of(Event, draft_event.id) == :draft

    # 场次取消发 event.ended（退款链的唯一触发源）
    ended_jobs =
      Enum.filter(
        all_enqueued(worker: SignalPublishWorker),
        &(&1.args["signal_type"] == "event.ended" and
            &1.args["data"]["event_id"] == open_event.id)
      )

    assert [job] = ended_jobs

    # 经订阅方同码入口投递 → 既有批量退款链（本域零退款代码）
    assert :ok =
             SignalSubscriber.deliver(OfferingCancelRefundWorker, %{
               type: "event.ended",
               data: job.args["data"]
             })

    assert reload_order(paid_order).status == :refunding
    assert_enqueued(worker: PaymentRefundWorker, args: %{"order_id" => paid_order.id})

    # 级联审计行（系统动作，actor_id nil）
    assert [%{action: :initiative_cancel_batch, metadata: %{"cancelled_events" => 1}}] =
             AdminActionLog
             |> Ash.read!(authorize?: false)
             |> Enum.filter(
               &(&1.action == :initiative_cancel_batch and &1.target_id == initiative.id)
             )
  end

  test "cancel 只碰 open 场：closed / cancelled 挂载场零触碰（D4）", ctx do
    initiative = open_initiative(ctx.admin, "cascade-terminal")

    closed_event =
      EF.create_event(ctx.workspace, ctx.admin, %{initiative_id: initiative.id, capacity: 1})

    cancelled_event = EF.create_event(ctx.workspace, ctx.admin, %{initiative_id: initiative.id})

    # 布置：两场各自进入终态（closed 正常收尾 / cancelled 先行中止）
    {:ok, _} =
      closed_event
      |> Ash.Changeset.for_update(:close, %{})
      |> Ash.update(tenant: ctx.workspace.id, actor: ctx.admin)

    {:ok, _} =
      cancelled_event
      |> Ash.Changeset.for_update(:cancel, %{})
      |> Ash.update(tenant: ctx.workspace.id, actor: ctx.admin)

    closed_at = reload(closed_event).updated_at
    cancelled_at = reload(cancelled_event).updated_at

    assert {:ok, _} = cancel(initiative, ctx.admin)
    assert :ok = perform_job(CancelCascadeWorker, %{"initiative_id" => initiative.id})

    assert status_of(Event, closed_event.id) == :closed
    assert status_of(Event, cancelled_event.id) == :cancelled
    # updated_at 未变 = 真的一行都没写（不是「写回同值」）
    assert reload(closed_event).updated_at == closed_at
    assert reload(cancelled_event).updated_at == cancelled_at
  end

  test "幂等：worker 重复执行不重复副作用（第二拍零计数、不落第二行审计）", ctx do
    initiative = open_initiative(ctx.admin, "cascade-idempotent")
    event = EF.create_event(ctx.workspace, ctx.admin, %{initiative_id: initiative.id})

    assert {:ok, _} = cancel(initiative, ctx.admin)

    assert :ok = perform_job(CancelCascadeWorker, %{"initiative_id" => initiative.id})
    assert status_of(Event, event.id) == :cancelled

    cancelled_at = reload(event).updated_at

    # 第二拍：扫不到 open 场 ⇒ 零动作、零审计噪音行
    assert :ok = perform_job(CancelCascadeWorker, %{"initiative_id" => initiative.id})
    assert reload(event).updated_at == cancelled_at
    assert status_of(Event, event.id) == :cancelled

    # 第三拍（直投 CAS 再证）：Event :cancel 的状态门拒绝重复迁移
    assert {:error, _} =
             event
             |> Ash.Changeset.for_update(:cancel, %{})
             |> Ash.update(tenant: ctx.workspace.id, authorize?: false)

    assert [%{action: :initiative_cancel_batch}] =
             AdminActionLog
             |> Ash.read!(authorize?: false)
             |> Enum.filter(
               &(&1.action == :initiative_cancel_batch and &1.target_id == initiative.id)
             )
  end

  test "close 不级联、不退款（收尾口径）", ctx do
    initiative = open_initiative(ctx.admin, "cascade-close")

    event =
      EF.create_event(ctx.workspace, ctx.admin, %{
        initiative_id: initiative.id,
        pricing_enabled: true,
        price_tiers: [%{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900}]
      })

    enrollment = enroll(ctx.workspace, event, ctx.learner)
    paid = paid_order(ctx.workspace, enrollment)

    before_jobs = length(all_enqueued(worker: PaymentRefundWorker))

    assert {:ok, _} =
             initiative |> Ash.Changeset.for_update(:close, %{}) |> Ash.update(actor: ctx.admin)

    assert status_of(Event, event.id) == :open
    assert reload_order(paid).status == :paid
    assert length(all_enqueued(worker: PaymentRefundWorker)) == before_jobs

    refute Enum.any?(
             all_enqueued(worker: CancelCascadeWorker),
             &(&1.args["initiative_id"] == initiative.id)
           )

    refute Enum.any?(
             all_enqueued(worker: SignalPublishWorker),
             &(&1.args["signal_type"] == "event.ended" and
                 &1.args["data"]["event_id"] == event.id)
           )
  end

  test "规则写面在 cancel 后冻结：挂载场的锁死字段不再被传播（#587 范围 SQL 未改）", ctx do
    initiative =
      open_initiative(ctx.admin, "cascade-rule-freeze", %{
        min_participants: {%{count: 8}, true}
      })

    event = draft_mounted(ctx.workspace, ctx.admin, initiative)
    assert {:ok, _} = cancel(initiative, ctx.admin)

    assert {:error, %Ash.Error.Invalid{}} =
             initiative
             |> rule(:min_participants, ctx.admin)
             |> Ash.Changeset.for_update(:update, %{value: %{count: 3}})
             |> Ash.update(actor: ctx.admin)

    assert reload(event).min_participants == 8
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp open_initiative(admin, slug, rule_overrides \\ %{}) do
    initiative =
      Initiative
      |> Ash.Changeset.for_create(:create, %{
        name: "级联 #{slug}",
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

    initiative |> Ash.Changeset.for_update(:open, %{}) |> Ash.update!(actor: admin)
  end

  defp default_rules do
    %{
      deposit: {%{enabled: false}, false},
      age_gate: {%{min_age: 18}, false},
      min_participants: {%{count: 8}, false},
      deadline_rule: {%{hours_before_start: 72}, false}
    }
  end

  defp draft_mounted(workspace, admin, initiative) do
    Event
    |> Ash.Changeset.for_create(
      :create,
      %{
        title: "级联草稿场",
        enrollment_policy: :open,
        starts_at: EF.days_from_now(10),
        ends_at: EF.days_from_now(11),
        initiative_id: initiative.id
      },
      tenant: workspace.id
    )
    |> Ash.create!(tenant: workspace.id, actor: admin)
  end

  # #510：挂载场经 age_gate 规则传播带 min_age——enroll 布置恒带年龄确认
  defp enroll(workspace, event, learner) do
    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, %{
      event_id: event.id,
      user_id: learner.id,
      tier_id: @tier_id,
      age_confirmed: true
    })
    |> Ash.create!(tenant: workspace.id, actor: learner)
  end

  defp paid_order(workspace, enrollment) do
    {:ok, order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        enrollment_id: enrollment.id,
        provider: :wechat_native,
        out_trade_no: "oto-" <> Ecto.UUID.generate(),
        amount_cents: 19_900,
        tier_snapshot: %{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900},
        expire_at: DateTime.add(DateTime.utc_now(), 2, :hour)
      })
      |> Ash.create(tenant: workspace.id, authorize?: false)

    {:ok, paid} =
      order
      |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "txn-" <> Ecto.UUID.generate()})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    {:ok, _} =
      enrollment
      |> Ash.Changeset.for_update(:settle_paid, %{})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    paid
  end

  defp cancel(initiative, admin) do
    initiative |> Ash.Changeset.for_update(:cancel, %{}) |> Ash.update(actor: admin)
  end

  defp rule(initiative, key, admin) do
    InitiativeRule
    |> Ash.Query.filter(initiative_id == ^initiative.id and key == ^key)
    |> Ash.read_one!(actor: admin)
  end

  defp status_of(resource, id), do: Ash.get!(resource, id, authorize?: false).status
  defp reload(event), do: Ash.get!(Event, event.id, authorize?: false)
  defp reload_order(order), do: Ash.get!(Order, order.id, authorize?: false)
end
