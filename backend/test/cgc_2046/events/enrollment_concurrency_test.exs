defmodule Cgc2046.Events.EnrollmentConcurrencyTest do
  use Cgc2046.DataCase, async: false

  alias Cgc2046.Events.{Enrollment, InviteBatch}
  alias Cgc2046.MiniprogramFixtures.Barrier
  alias Cgc2046.Phase2Fixtures, as: Fixtures

  test "capacity=1 的两个并发 open 报名恰好一个成功" do
    {admin, workspace, event, users} =
      unboxed(fn ->
        admin = Fixtures.platform_admin("capacity-race-admin")
        workspace = Fixtures.create_workspace(admin)
        event = Fixtures.create_event(workspace, admin, %{capacity: 1})

        users = [
          Fixtures.register_user("capacity-race-a"),
          Fixtures.register_user("capacity-race-b")
        ]

        {admin, workspace, event, users}
      end)

    cleanup_on_exit(workspace.id, [admin | users])
    barrier = start_supervised!({Barrier, 2})

    results = race_enrollments(event, users, barrier, %{})
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1

    assert Ash.get!(event.__struct__, event.id, authorize?: false).confirmed_count == 1
  end

  test "quota=1 的两个并发 invite_only 报名恰好消费一次" do
    invite_code = "RACE_#{Ecto.UUID.generate()}"

    {admin, workspace, event, batch, users} =
      unboxed(fn ->
        admin = Fixtures.platform_admin("quota-race-admin")
        workspace = Fixtures.create_workspace(admin)
        event = Fixtures.create_event(workspace, admin, %{enrollment_policy: :invite_only})

        batch =
          InviteBatch
          |> Ash.Changeset.for_create(:create, %{
            event_id: event.id,
            invite_code: invite_code,
            quota: 1
          })
          |> Ash.create!(tenant: workspace.id, actor: admin)

        users = [Fixtures.register_user("quota-race-a"), Fixtures.register_user("quota-race-b")]
        {admin, workspace, event, batch, users}
      end)

    cleanup_on_exit(workspace.id, [admin | users])
    barrier = start_supervised!({Barrier, 2})

    results = race_enrollments(event, users, barrier, %{invite_code: invite_code})
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    assert Ash.get!(InviteBatch, batch.id, authorize?: false).remaining_quota == 0
  end

  defp race_enrollments(event, users, barrier, extra_attrs) do
    users
    |> Enum.map(fn user ->
      Task.async(fn ->
        unboxed(fn ->
          Barrier.arrive(barrier)

          Enrollment
          |> Ash.Changeset.for_create(
            :create_enrollment,
            Map.merge(%{event_id: event.id, user_id: user.id}, extra_attrs)
          )
          |> Ash.create(tenant: event.workspace_id, actor: user)
        end)
      end)
    end)
    |> Task.await_many(15_000)
  end

  defp cleanup_on_exit(workspace_id, users) do
    on_exit(fn ->
      unboxed(fn ->
        Cgc2046.Repo.query!(
          "DELETE FROM membership_roles WHERE membership_id IN (SELECT id FROM workspace_memberships WHERE workspace_id = $1)",
          [Ecto.UUID.dump!(workspace_id)]
        )

        Cgc2046.Repo.query!("DELETE FROM workspace_memberships WHERE workspace_id = $1", [
          Ecto.UUID.dump!(workspace_id)
        ])

        Cgc2046.Repo.query!("DELETE FROM events WHERE workspace_id = $1", [
          Ecto.UUID.dump!(workspace_id)
        ])

        Cgc2046.Repo.query!("DELETE FROM workspaces WHERE id = $1", [
          Ecto.UUID.dump!(workspace_id)
        ])

        Enum.each(users, fn user ->
          Cgc2046.Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(user.id)])
        end)
      end)
    end)
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Cgc2046.Repo, fun)
end
