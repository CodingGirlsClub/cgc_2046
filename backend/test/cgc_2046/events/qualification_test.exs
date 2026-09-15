defmodule Cgc2046.Events.QualificationTest do
  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Events.{Event, Qualification}
  alias Cgc2046.EventsFixtures

  test "event without minimum participants is not applicable" do
    assert Qualification.qualify(%Event{min_participants: nil}) == :not_applicable
  end

  test "qualification snapshots confirmed enrollments once" do
    admin = Fixtures.platform_admin("qualification-test")
    workspace = Fixtures.create_workspace(admin)
    event = EventsFixtures.create_event(workspace, admin, %{min_participants: 2})
    learner = Fixtures.register_user("qualification-learner")

    assert {:ok, enrollment} =
             Enrollment
             |> Ash.Changeset.for_create(:create_enrollment, %{
               event_id: event.id,
               user_id: learner.id
             })
             |> Ash.create(tenant: workspace.id, actor: learner)

    assert enrollment.status == :confirmed

    Cgc2046.Repo.query!(
      "UPDATE events SET registration_deadline = NOW() - INTERVAL '1 hour' WHERE id = $1",
      [Ecto.UUID.dump!(event.id)]
    )

    assert {:ok, :underfilled, _recipients, 1} = Qualification.qualify(event)
    assert :skip = Qualification.qualify(event)
    assert Ash.get!(Event, event.id, authorize?: false).qualification_status == :underfilled
  end
end
