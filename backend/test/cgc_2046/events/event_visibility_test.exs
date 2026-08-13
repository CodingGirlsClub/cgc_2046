defmodule Cgc2046.Events.EventVisibilityTest do
  @moduledoc """
  E-11 #127 可见性轴测试：读策略（D9 条件式）+ 匿名白名单 + 切换。

  - 匿名（actor=nil）仅可读 `open + visibility=public`
  - 成员/平台管理员可读全部；非成员登录用户视同匿名
  - visibility 可随时双向切换（含 open 后，用户拍板）
  - D2 白名单：匿名读时 capacity/confirmed_count 为 %Ash.ForbiddenField{}

  读策略为过滤型（expr 条件编译为 read filter）——无权记录对调用方表现为
  NotFound（公开语义：不存在优于无权）。
  """

  use Cgc2046.DataCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.{Course, Event}
  alias Cgc2046.EventsFixtures, as: EventFixtures

  defp reload(resource, id, actor \\ nil, tenant \\ nil) do
    opts = [authorize?: true]
    opts = if actor, do: Keyword.put(opts, :actor, actor), else: opts
    opts = if tenant, do: Keyword.put(opts, :tenant, tenant), else: opts

    Ash.get(resource, id, opts)
  end

  defp update_visibility(entity, workspace, actor, visibility) do
    entity
    |> Ash.Changeset.for_update(:update, %{visibility: visibility},
      tenant: workspace.id,
      actor: actor
    )
    |> Ash.update(tenant: workspace.id, actor: actor)
  end

  describe "匿名读策略（D9 条件式）" do
    test "open+public 匿名可读；open+workspace / draft / closed 匿名 NotFound" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      public_open = EventFixtures.create_event(workspace, admin)
      workspace_event = EventFixtures.create_event(workspace, admin, %{visibility: :workspace})

      draft =
        Event
        |> Ash.Changeset.for_create(:create, %{title: "Draft", enrollment_policy: :open},
          tenant: workspace.id
        )
        |> Ash.create!(tenant: workspace.id, actor: admin)

      closed = EventFixtures.create_event(workspace, admin)

      {:ok, _} =
        closed
        |> Ash.Changeset.for_update(:close, %{}, tenant: workspace.id, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert {:ok, %{id: id}} = reload(Event, public_open.id)
      assert id == public_open.id

      assert {:error, %{errors: [%Ash.Error.Query.NotFound{}]}} =
               reload(Event, workspace_event.id)

      assert {:error, %{errors: [%Ash.Error.Query.NotFound{}]}} = reload(Event, draft.id)
      assert {:error, %{errors: [%Ash.Error.Query.NotFound{}]}} = reload(Event, closed.id)
    end

    test "Course 同构：open+public 匿名可读，workspace 匿名 NotFound" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      public_course = EventFixtures.create_course(workspace, admin)
      workspace_course = EventFixtures.create_course(workspace, admin, %{visibility: :workspace})

      assert {:ok, _} = reload(Course, public_course.id)

      assert {:error, %{errors: [%Ash.Error.Query.NotFound{}]}} =
               reload(Course, workspace_course.id)
    end

    test "成员读全部 status/visibility；非成员登录用户视同匿名" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("vis-member")
      Fixtures.add_member(workspace, member)
      outsider = Fixtures.register_user("vis-outsider")

      workspace_event = EventFixtures.create_event(workspace, admin, %{visibility: :workspace})

      draft =
        Event
        |> Ash.Changeset.for_create(:create, %{title: "Draft 2", enrollment_policy: :open},
          tenant: workspace.id
        )
        |> Ash.create!(tenant: workspace.id, actor: admin)

      assert {:ok, _} = reload(Event, workspace_event.id, member, workspace.id)
      assert {:ok, _} = reload(Event, draft.id, member, workspace.id)

      assert {:error, %{errors: [%Ash.Error.Query.NotFound{}]}} =
               reload(Event, workspace_event.id, outsider, workspace.id)
    end
  end

  describe "visibility 切换（含 open 后，用户拍板）" do
    test "public → workspace：匿名立即失读；workspace → public：匿名恢复可读" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)
      assert {:ok, _} = reload(Event, event.id)

      assert {:ok, switched} = update_visibility(event, workspace, admin, :workspace)
      assert switched.visibility == :workspace
      assert {:error, %{errors: [%Ash.Error.Query.NotFound{}]}} = reload(Event, event.id)

      assert {:ok, back} = update_visibility(switched, workspace, admin, :public)
      assert back.visibility == :public
      assert {:ok, _} = reload(Event, event.id)
    end

    test "非 Owner/Admin 不能切换 visibility" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("vis-member2")
      Fixtures.add_member(workspace, member)
      event = EventFixtures.create_event(workspace, admin)

      assert {:error, _} = update_visibility(event, workspace, member, :workspace)
      assert reload(Event, event.id) |> elem(1) |> Map.get(:visibility) == :public
    end
  end

  describe "D2 白名单 field policies" do
    test "匿名读 open+public 时 capacity/confirmed_count 为 ForbiddenField；成员读完整" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("vis-member3")
      Fixtures.add_member(workspace, member)
      event = EventFixtures.create_event(workspace, admin, %{capacity: 5})

      {:ok, anon_view} = reload(Event, event.id)
      assert match?(%Ash.ForbiddenField{}, anon_view.capacity)
      assert match?(%Ash.ForbiddenField{}, anon_view.confirmed_count)
      assert match?(%Ash.ForbiddenField{}, anon_view.workspace_id)
      assert match?(%Ash.ForbiddenField{}, anon_view.research_enabled)
      assert anon_view.title == event.title
      assert anon_view.visibility == :public

      {:ok, member_view} = reload(Event, event.id, member, workspace.id)
      assert member_view.capacity == 5
      assert member_view.confirmed_count == 0
    end
  end
end
