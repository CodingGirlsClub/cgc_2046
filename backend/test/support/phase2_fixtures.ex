defmodule Cgc2046.Phase2Fixtures do
  @moduledoc "Phase 2 业务 API 测试共用 fixture。"

  alias AshAuthentication.Info
  alias AshAuthentication.Strategy
  alias Cgc2046.Accounts.{MembershipContext, User, Workspace}
  alias Cgc2046.Events.{Course, Event}

  @password "sup3r-secret-password"

  def register_user(prefix) do
    email = "#{prefix}-#{Ecto.UUID.generate()}@example.com"

    {:ok, user} =
      User
      |> Info.strategy!(:password)
      |> Strategy.action(:register, %{email: email, password: @password})

    user
  end

  def platform_admin(prefix \\ "phase2-admin") do
    user = register_user(prefix)

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE users SET is_platform_admin = true WHERE id = $1",
        [Ecto.UUID.dump!(user.id)]
      )

    Ash.get!(User, user.id, authorize?: false)
  end

  def create_workspace(actor, attrs \\ %{}) do
    suffix = Ecto.UUID.generate()

    attrs =
      Map.merge(
        %{slug: "phase2-#{suffix}", name: "Phase 2 #{suffix}", join_policy: :request},
        attrs
      )

    Workspace
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(actor: actor)
  end

  def add_member(workspace, user, role_names \\ [:member]) do
    {:ok, membership} =
      MembershipContext.admit_member(user.id, workspace.id, role_names, on_conflict: :idempotent)

    membership
  end

  def create_event(workspace, actor, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          title: "Phase 2 Event",
          enrollment_policy: :open,
          capacity: nil,
          registration_deadline: DateTime.add(DateTime.utc_now(), 7, :day)
        },
        attrs
      )

    Event
    |> Ash.Changeset.for_create(:create, attrs, tenant: workspace.id)
    |> Ash.create!(tenant: workspace.id, actor: actor)
    |> force_open(:events)
  end

  def create_course(workspace, actor, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          title: "Phase 2 Course",
          enrollment_policy: :open,
          capacity: nil,
          registration_deadline: DateTime.add(DateTime.utc_now(), 7, :day)
        },
        attrs
      )

    Course
    |> Ash.Changeset.for_create(:create, attrs, tenant: workspace.id)
    |> Ash.create!(tenant: workspace.id, actor: actor)
    |> force_open(:courses)
  end

  defp force_open(record, table) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE #{table} SET status = 'open' WHERE id = $1",
        [Ecto.UUID.dump!(record.id)]
      )

    Ash.get!(record.__struct__, record.id, authorize?: false)
  end
end
