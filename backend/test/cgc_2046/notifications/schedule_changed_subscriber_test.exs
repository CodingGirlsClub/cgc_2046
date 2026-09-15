defmodule Cgc2046.Notifications.ScheduleChangedSubscriberTest do
  use Cgc2046.DataCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures
  alias Cgc2046.Notifications.{NotificationDelivery, ScheduleChangedSubscriber}

  test "schedule signal creates durable delivery rows for active enrollments" do
    admin = Fixtures.platform_admin("schedule-subscriber")
    workspace = Fixtures.create_workspace(admin)
    learner = Fixtures.register_user("schedule-learner")
    event = EventsFixtures.create_event(workspace, admin)

    {:ok, _enrollment} =
      Cgc2046.Admission.Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{event_id: event.id, user_id: learner.id})
      |> Ash.create(tenant: workspace.id, actor: learner)

    assert :ok =
             ScheduleChangedSubscriber.handle("event.schedule_changed", %{
               "event_id" => event.id,
               "idempotency_key" => "event.schedule_changed:" <> event.id,
               "workspace_id" => workspace.id
             })

    assert [%{template_key: "event_schedule_changed", status: :pending}] =
             Ash.read!(NotificationDelivery, authorize?: false)
  end
end
