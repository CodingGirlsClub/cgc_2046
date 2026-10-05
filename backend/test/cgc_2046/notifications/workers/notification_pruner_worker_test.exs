defmodule Cgc2046.Notifications.Workers.NotificationPrunerWorkerTest do
  use Cgc2046.DataCase, async: false
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Notifications.{Inbox, Notification}

  test "purge removes exactly the expired UTC boundary, independently of session timezone" do
    user = Fixtures.register_user("inbox-purge")
    now = ~U[2026-10-04 12:00:00.123456Z]
    cutoff = ~U[2026-09-04 12:00:00.123456Z]

    for {id, at} <- [
          {"old", DateTime.add(cutoff, -1, :microsecond)},
          {"edge", cutoff},
          {"new", DateTime.add(cutoff, 1, :microsecond)}
        ] do
      Notification
      |> Ash.Changeset.for_create(:record, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attributes(%{
        id: id,
        user_id: user.id,
        type: "enrollment_completed",
        payload: %{"title" => "报名", "body" => "成功"},
        inserted_at: at
      })
      |> Ash.create!()
    end

    Cgc2046.Repo.query!("SET LOCAL TIME ZONE 'Asia/Shanghai'")
    assert Inbox.cutoff(now) == cutoff
    assert Inbox.purge(now) == :ok
    assert [%{id: "new"}] = Cgc2046.Repo.all(Notification)
    assert Inbox.purge(now) == :ok
    assert [%{id: "new"}] = Cgc2046.Repo.all(Notification)
  end
end
