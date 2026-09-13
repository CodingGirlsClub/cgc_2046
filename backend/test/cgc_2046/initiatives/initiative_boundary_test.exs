defmodule Cgc2046.InitiativeBoundaryTest do
  use Cgc2046.DataCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo
  require Ash.Query
  alias Cgc2046.AccountsFixtures, as: F
  alias Cgc2046.EventsFixtures, as: EF
  alias Cgc2046.Events.{Event, Qualification}
  alias Cgc2046.Initiatives.{Initiative, InitiativeRule}
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Payments.Order
  alias Cgc2046.Payments.Workers.PaymentRefundWorker
  alias Cgc2046.Notifications.{Delivery, NotificationDelivery}
  alias Cgc2046.Notifications.Workers.DeliveryWorker

  setup do
    admin = F.platform_admin("initiative-boundary")

    %{
      admin: admin,
      workspace: F.create_workspace(admin),
      learner: F.register_user("initiative-boundary-learner")
    }
  end

  defp initiative(admin) do
    i =
      Initiative
      |> Ash.Changeset.for_create(:create, %{
        name: "Boundary",
        slug: "boundary",
        created_by: admin.id
      })
      |> Ash.create!(actor: admin)

    for {key, value} <- [
          deposit: %{enabled: true, amount_cents: 6900},
          age_gate: %{min_age: 18},
          min_participants: %{count: 8},
          deadline_rule: %{hours_before_start: 72}
        ] do
      InitiativeRule
      |> Ash.Changeset.for_create(:create, %{
        initiative_id: i.id,
        key: key,
        value: value,
        locked: true
      })
      |> Ash.create!(actor: admin)
    end

    i |> Ash.Changeset.for_update(:open, %{}) |> Ash.update!(actor: admin)
  end

  defp enroll(event, learner) do
    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, %{event_id: event.id, user_id: learner.id})
    |> Ash.create!(actor: learner, tenant: event.workspace_id)
  end

  defp paid_order(e, kind) do
    Order
    |> Ash.Changeset.for_create(:create, %{
      enrollment_id: e.id,
      order_kind: kind,
      provider: :wechat_native,
      out_trade_no: Ecto.UUID.generate(),
      amount_cents: 6900,
      tier_snapshot: %{},
      expire_at: DateTime.add(DateTime.utc_now(), 3600)
    })
    |> Ash.create!(authorize?: false, tenant: e.workspace_id)
    |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: Ecto.UUID.generate()})
    |> Ash.update!(authorize?: false, tenant: e.workspace_id)
  end

  test "closed initiative cannot reopen or close twice", %{admin: admin} do
    i = initiative(admin) |> Ash.Changeset.for_update(:close, %{}) |> Ash.update!(actor: admin)
    assert {:error, _} = i |> Ash.Changeset.for_update(:open, %{}) |> Ash.update(actor: admin)
    assert {:error, _} = i |> Ash.Changeset.for_update(:close, %{}) |> Ash.update(actor: admin)
  end

  test "initiative slug is a URL segment", %{admin: admin} do
    assert {:error, _} =
             Initiative
             |> Ash.Changeset.for_create(:create, %{
               name: "Bad",
               slug: "bad/path",
               created_by: admin.id
             })
             |> Ash.create(actor: admin)
  end

  test "enabled deposit rule requires amount", %{admin: admin} do
    i = initiative(admin)

    r =
      InitiativeRule
      |> Ash.Query.filter(initiative_id == ^i.id and key == :deposit)
      |> Ash.read_one!(actor: admin)

    assert {:error, _} =
             r
             |> Ash.Changeset.for_update(:update, %{value: %{enabled: true}})
             |> Ash.update(actor: admin)

    assert Ash.get!(InitiativeRule, r.id, actor: admin).value["amount_cents"] == 6900
  end

  test "published event cannot detach", ctx do
    i = initiative(ctx.admin)

    e =
      EF.create_event(ctx.workspace, ctx.admin, %{
        initiative_id: i.id,
        starts_at: DateTime.add(DateTime.utc_now(), 10, :day)
      })

    assert {:error, _} =
             e
             |> Ash.Changeset.for_update(:update, %{initiative_id: nil})
             |> Ash.update(actor: ctx.admin, tenant: ctx.workspace.id)
  end

  test "locked fields reject local writes and unrelated editing preserves deadline", ctx do
    i = initiative(ctx.admin)

    e =
      EF.create_event(ctx.workspace, ctx.admin, %{
        initiative_id: i.id,
        starts_at: DateTime.add(DateTime.utc_now(), 10, :day)
      })

    assert {:error, _} =
             e
             |> Ash.Changeset.for_update(:update, %{deposit_amount_cents: 1})
             |> Ash.update(actor: ctx.admin, tenant: ctx.workspace.id)

    changed =
      e
      |> Ash.Changeset.for_update(:update, %{title: "Renamed"})
      |> Ash.update!(actor: ctx.admin, tenant: ctx.workspace.id)

    assert changed.registration_deadline == e.registration_deadline
  end

  test "locked deadline propagation accepts database timestamps", ctx do
    i = initiative(ctx.admin)

    e =
      EF.create_event(ctx.workspace, ctx.admin, %{
        initiative_id: i.id,
        starts_at: DateTime.add(DateTime.utc_now(), 10, :day)
      })

    r =
      InitiativeRule
      |> Ash.Query.filter(initiative_id == ^i.id and key == :deadline_rule)
      |> Ash.read_one!(actor: ctx.admin)

    assert {:ok, _} =
             r
             |> Ash.Changeset.for_update(:update, %{value: %{hours_before_start: 48}})
             |> Ash.update(actor: ctx.admin)

    assert Ash.get!(Event, e.id, authorize?: false).registration_deadline ==
             DateTime.add(e.starts_at, -48, :hour)
  end

  test "qualification cannot run before deadline", ctx do
    e = EF.create_event(ctx.workspace, ctx.admin, %{min_participants: 2})
    assert :skip = Qualification.qualify(e)
    assert Ash.get!(Event, e.id, authorize?: false).qualification_status == :pending
  end

  test "self cancellation before deadline starts exactly one deposit refund", ctx do
    event =
      EF.create_event(ctx.workspace, ctx.admin, %{
        deposit_enabled: true,
        deposit_amount_cents: 6900
      })

    e = enroll(event, ctx.learner)
    order = paid_order(e, :deposit)

    assert {:ok, _} =
             e
             |> Ash.Changeset.for_update(:cancel, %{})
             |> Ash.update(actor: ctx.learner, tenant: ctx.workspace.id)

    assert EF.ledger_occupancy(event) == 0
    assert Ash.get!(Order, order.id, authorize?: false).status == :refunding
    assert [%{args: %{"order_id" => id}}] = all_enqueued(worker: PaymentRefundWorker)
    assert id == order.id

    assert {:error, _} =
             e
             |> Ash.Changeset.for_update(:cancel, %{})
             |> Ash.update(actor: ctx.learner, tenant: ctx.workspace.id)

    assert length(all_enqueued(worker: PaymentRefundWorker)) == 1
  end

  test "after deadline cancellation and ordinary tickets do not refund", ctx do
    event = EF.create_event(ctx.workspace, ctx.admin)
    e = enroll(event, ctx.learner)
    order = paid_order(e, :deposit)

    Cgc2046.Repo.query!(
      "UPDATE events SET registration_deadline = NOW() - INTERVAL '1 hour' WHERE id = $1",
      [Ecto.UUID.dump!(event.id)]
    )

    assert {:ok, _} =
             e
             |> Ash.Changeset.for_update(:cancel, %{})
             |> Ash.update(actor: ctx.learner, tenant: ctx.workspace.id)

    assert Ash.get!(Order, order.id, authorize?: false).status == :paid
    assert EF.ledger_occupancy(event) == 0
    assert all_enqueued(worker: PaymentRefundWorker) == []
  end

  test "repeated schedule edits each have their own durable signal", ctx do
    e = EF.create_event(ctx.workspace, ctx.admin)

    for days <- [3, 4] do
      e
      |> Ash.Changeset.for_update(:update, %{
        starts_at: DateTime.add(DateTime.utc_now(), days, :day)
      })
      |> Ash.update!(actor: ctx.admin, tenant: ctx.workspace.id)
    end

    jobs =
      all_enqueued(worker: Cgc2046.Workflows.SignalPublishWorker)
      |> Enum.filter(&(&1.args["signal_type"] == "event.schedule_changed"))

    assert length(jobs) == 2
    assert length(Enum.uniq_by(jobs, & &1.args["data"]["idempotency_key"])) == 2
    assert all_enqueued(worker: PaymentRefundWorker) == []
  end

  test "notification string platform resolves configured template and waits for consent", ctx do
    assert :ok =
             Delivery.enqueue(
               {ctx.learner.id, [%{provider: :wechat, uid: "boundary-openid"}]},
               "approval_result",
               %{},
               %{"idempotency_key" => "boundary-consent"}
             )

    [row] = Ash.read!(NotificationDelivery, authorize?: false)
    assert {:error, :consent_exhausted} = perform_job(DeliveryWorker, %{"delivery_id" => row.id})
    assert Ash.get!(NotificationDelivery, row.id, authorize?: false).status == :pending
  end

  test "replayed notification enqueue is idempotent", ctx do
    for _ <- 1..2,
        do:
          Delivery.enqueue({ctx.learner.id, []}, "event_schedule_changed", %{}, %{
            "idempotency_key" => "boundary-replay"
          })

    assert length(Ash.read!(NotificationDelivery, authorize?: false)) == 1
    assert length(all_enqueued(worker: DeliveryWorker)) == 1
  end
end
