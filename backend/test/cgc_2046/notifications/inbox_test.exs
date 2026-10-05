defmodule Cgc2046.Notifications.InboxTest do
  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo
  require Ash.Query
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Notifications.{Delivery, Fanout, Notification, NotificationDelivery}

  test "acceptance produces one safe record across identities, independently of quota" do
    user = Fixtures.register_user("accept-inbox")
    identities = [%{provider: :wechat, uid: "local-wx"}, %{provider: :tt, uid: "local-tt"}]

    data = %{
      "status" => "confirmed",
      "title" => "活动 A",
      "check_in_code" => "987654",
      "cookie" => "SENSITIVE_SENTINEL"
    }

    meta = %{"idempotency_key" => "source-a"}
    assert :ok = Delivery.enqueue({user.id, identities}, "approval_result", data, meta)
    assert [%{id: id, payload: payload, inserted_at: at}] = feed(user)
    assert payload == %{"title" => "报名审批结果", "body" => "活动 A：报名已通过。"}

    assert Cgc2046.Notifications.Consent.remaining(user.id, :wechat, "approval_result") ==
             {:ok, 0}

    assert :ok =
             Delivery.enqueue(
               {user.id, identities},
               "approval_result",
               Map.put(data, "title", "changed"),
               meta
             )

    assert [%{id: ^id, payload: ^payload, inserted_at: ^at}] = feed(user)

    assert 2 ==
             NotificationDelivery
             |> Ash.Query.filter(user_id == ^user.id)
             |> Ash.read!(authorize?: false)
             |> length()
  end

  test "capability-free acceptance has feed but no channel jobs; real zero identity keeps sentinel" do
    web = Fixtures.register_user("accept-web")
    zero = Fixtures.register_user("accept-zero")

    assert {:ok, 0} =
             Fanout.deliver_with_receipt(
               {web.id, [%{provider: :wechat_web, uid: "web"}]},
               "approval_result",
               %{"enrollment_id" => "e-web", "status" => "confirmed"},
               %{}
             )

    assert [%{type: "approval_result"}] = feed(web)

    assert [] =
             NotificationDelivery
             |> Ash.Query.filter(user_id == ^web.id)
             |> Ash.read!(authorize?: false)

    assert {:ok, 0} =
             Fanout.deliver_with_receipt(
               {zero.id, []},
               "approval_result",
               %{"enrollment_id" => "e-zero", "status" => "confirmed"},
               %{}
             )

    assert [%{type: "approval_result"}] = feed(zero)

    assert [%{platform: nil, identity_uid: nil}] =
             NotificationDelivery
             |> Ash.Query.filter(user_id == ^zero.id)
             |> Ash.read!(authorize?: false)
  end

  test "existing outbox is not backfilled and outer rollback removes accepted feed and jobs" do
    user = Fixtures.register_user("accept-rollback")
    identity = [%{provider: :wechat, uid: "rollback"}]

    assert {:error, :abort} =
             Cgc2046.Repo.transaction(fn ->
               Delivery.enqueue({user.id, identity}, "enrollment_completed", %{"title" => "A"}, %{
                 "idempotency_key" => "rollback-source"
               })

               assert [%{}] = feed(user)
               Cgc2046.Repo.rollback(:abort)
             end)

    assert [] = feed(user)

    assert [] =
             NotificationDelivery
             |> Ash.Query.filter(user_id == ^user.id)
             |> Ash.read!(authorize?: false)

    Delivery.enqueue({user.id, identity}, "enrollment_completed", %{}, %{
      "idempotency_key" => "old-source"
    })

    Cgc2046.Repo.delete_all(Notification)

    Delivery.enqueue({user.id, identity}, "enrollment_completed", %{}, %{
      "idempotency_key" => "old-source"
    })

    assert [] = feed(user)
  end

  test "second identity rejection rolls back the user's first job and inbox" do
    user = Fixtures.register_user("accept-second-failure")

    before_jobs =
      all_enqueued(worker: Cgc2046.Notifications.Workers.DeliveryWorker) |> Enum.map(& &1.id)

    assert_raise Ash.Error.Invalid, fn ->
      Delivery.enqueue(
        {user.id,
         [%{provider: :wechat, uid: "first"}, %{provider: :wechat, uid: %{invalid: true}}]},
        "enrollment_completed",
        %{},
        %{"idempotency_key" => "identity-fault"}
      )
    end

    assert [] = feed(user)

    assert [] =
             NotificationDelivery
             |> Ash.Query.filter(user_id == ^user.id)
             |> Ash.read!(authorize?: false)

    assert before_jobs ==
             all_enqueued(worker: Cgc2046.Notifications.Workers.DeliveryWorker)
             |> Enum.map(& &1.id)
  end

  test "speaker legs collapse for one user while schedule sessions remain distinct" do
    user = Fixtures.register_user("accept-source-legs")

    for leg <- ["managers", "speaker"] do
      Fanout.deliver(
        {user.id, []},
        "speaker_completed",
        %{"speaker_invitation_id" => "invitation"},
        %{"idempotency_key" => "speaker.completed:invitation", "leg" => leg}
      )
    end

    assert [%{type: "speaker_completed"}] = feed(user)

    for job <- [1, 1, 2] do
      Delivery.enqueue({user.id, []}, "event_schedule_changed", %{"title" => "同一安排"}, %{
        "idempotency_key" => "schedule:fanout-#{job}"
      })
    end

    assert Enum.map(feed(user), & &1.type) |> Enum.frequencies() == %{
             "speaker_completed" => 1,
             "event_schedule_changed" => 2
           }
  end

  test "reads and read marks do not consume a positive quota or enqueue delivery" do
    user = Fixtures.register_user("accept-quota")

    Cgc2046.Repo.query!(
      "INSERT INTO notification_consents (id,user_id,platform,template_key,remaining_uses,inserted_at,updated_at) VALUES (gen_random_uuid(),$1,'wechat','enrollment_completed',3,now(),now())",
      [Cgc2046.Repo.uuid!(user.id)]
    )

    Delivery.enqueue(
      {user.id, [%{provider: :wechat, uid: "quota"}]},
      "enrollment_completed",
      %{},
      %{"idempotency_key" => "quota-source"}
    )

    [row] = feed(user)

    delivery =
      NotificationDelivery
      |> Ash.Query.filter(user_id == ^user.id)
      |> Ash.read_one!(authorize?: false)

    jobs =
      all_enqueued(
        worker: Cgc2046.Notifications.Workers.DeliveryWorker,
        args: %{"delivery_id" => delivery.id}
      )
      |> Enum.map(& &1.id)

    row |> Ash.Changeset.for_update(:mark_read, %{}, actor: user) |> Ash.update!()
    assert [%{read_at: %DateTime{}}] = feed(user)

    assert {:ok, 3} =
             Cgc2046.Notifications.Consent.remaining(user.id, :wechat, "enrollment_completed")

    assert length(jobs) == 1

    assert jobs ==
             all_enqueued(
               worker: Cgc2046.Notifications.Workers.DeliveryWorker,
               args: %{"delivery_id" => delivery.id}
             )
             |> Enum.map(& &1.id)
  end

  defp feed(user),
    do: Notification |> Ash.Query.for_read(:read, %{}, actor: user) |> Ash.read!(page: false)
end
