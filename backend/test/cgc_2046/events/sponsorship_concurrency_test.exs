defmodule Cgc2046.Events.SponsorshipConcurrencyTest do
  use Cgc2046.DataCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Sponsorship
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.MiniprogramFixtures.Barrier

  @tier %{
    "id" => "7c9f4b60-0000-4000-8000-00000000000a",
    "name" => "冠名",
    "amount_suggestion" => 10_000,
    "benefits" => ["logo 展示位"],
    "exclusive" => true
  }

  test "同一独占档位的两个并发审批恰好一个 active（真实事务竞争，非 mock）" do
    {admin, workspace, sponsors, pending_ids} =
      unboxed(fn ->
        admin = Fixtures.platform_admin("exclusive-race-admin")
        workspace = Fixtures.create_workspace(admin)
        event = EventFixtures.create_event(workspace, admin, %{sponsorship_tiers: [@tier]})

        sponsors = [
          Fixtures.register_user("exclusive-race-a"),
          Fixtures.register_user("exclusive-race-b")
        ]

        pending_ids =
          Enum.map(sponsors, fn sponsor ->
            {:ok, pending} =
              Sponsorship
              |> Ash.Changeset.for_create(:create_sponsorship, %{
                level: :event,
                event_id: event.id,
                sponsor_user_id: sponsor.id,
                tier_id: @tier["id"],
                company_name: "Race Corp",
                contact_email: sponsor.email
              })
              |> Ash.create(tenant: workspace.id, actor: sponsor)

            pending.id
          end)

        {admin, workspace, sponsors, pending_ids}
      end)

    cleanup_on_exit(workspace.id, [admin | sponsors])
    barrier = start_supervised!({Barrier, 2})

    results = race_approvals(workspace, pending_ids, admin, barrier)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1

    statuses =
      Enum.map(pending_ids, fn id ->
        Ash.get!(Sponsorship, id, authorize?: false).status
      end)

    assert Enum.sort(statuses) == [:active, :pending]

    # 落败方错误必须指向独占位冲突（而非模糊的 already_processed）
    error =
      results
      |> Enum.find_value(fn
        {:error, error} -> error
        _ -> nil
      end)

    assert Exception.message(error) =~ "exclusive sponsorship slot"
  end

  defp race_approvals(workspace, pending_ids, admin, barrier) do
    pending_ids
    |> Enum.map(fn id ->
      Task.async(fn ->
        unboxed(fn ->
          Barrier.arrive(barrier)
          record = Ash.get!(Sponsorship, id, authorize?: false)

          record
          |> Ash.Changeset.for_update(:approve_sponsorship, %{})
          |> Ash.update(tenant: workspace.id, actor: admin)
          |> case do
            {:ok, approved} -> {:ok, id, approved.status}
            {:error, error} -> {:error, id, error}
          end
        end)
      end)
    end)
    |> Task.await_many(15_000)
    |> Enum.map(fn {tag, _id, value} -> {tag, value} end)
  end

  defp cleanup_on_exit(workspace_id, users) do
    on_exit(fn ->
      unboxed(fn ->
        Cgc2046.Repo.query!(
          "DELETE FROM sponsorship_deliveries WHERE sponsorship_id IN " <>
            "(SELECT id FROM sponsorships WHERE workspace_id = $1)",
          [Ecto.UUID.dump!(workspace_id)]
        )

        Cgc2046.Repo.query!("DELETE FROM sponsorships WHERE workspace_id = $1", [
          Ecto.UUID.dump!(workspace_id)
        ])

        Cgc2046.Repo.query!("DELETE FROM events WHERE workspace_id = $1", [
          Ecto.UUID.dump!(workspace_id)
        ])

        Cgc2046.Repo.query!(
          "DELETE FROM membership_roles WHERE membership_id IN " <>
            "(SELECT id FROM workspace_memberships WHERE workspace_id = $1)",
          [Ecto.UUID.dump!(workspace_id)]
        )

        Cgc2046.Repo.query!("DELETE FROM workspace_memberships WHERE workspace_id = $1", [
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
