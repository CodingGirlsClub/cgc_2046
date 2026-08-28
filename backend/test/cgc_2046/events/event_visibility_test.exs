defmodule Cgc2046.Events.EventVisibilityTest do
  @moduledoc """
  E-11 #127 可见性轴测试：读策略（D9 条件式 + 016 draft 收紧）+ 匿名白名单 + 切换。

  - 匿名（actor=nil）仅可读 `open + visibility=public`
  - 普通成员可读非 draft；Owner/Admin 与平台管理员可读全部生命周期
  - 非成员登录用户视同匿名
  - visibility 可随时双向切换（含 open 后，用户拍板）
  - D2 白名单：匿名读时 capacity/confirmed_count 为 %Ash.ForbiddenField{}

  读策略为过滤型（expr 条件编译为 read filter）——无权记录对调用方表现为
  NotFound（公开语义：不存在优于无权）。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Courses.Course
  alias Cgc2046.Events.Event
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

    test "成员不可读 draft，Owner 可读 draft；非成员登录用户视同匿名" do
      %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()
      outsider = Fixtures.register_user("vis-outsider")

      workspace_event = EventFixtures.create_event(workspace, owner, %{visibility: :workspace})

      draft =
        Event
        |> Ash.Changeset.for_create(:create, %{title: "Draft 2", enrollment_policy: :open},
          tenant: workspace.id
        )
        |> Ash.create!(tenant: workspace.id, actor: owner)

      assert {:ok, _} = reload(Event, workspace_event.id, member, workspace.id)
      assert {:ok, _} = reload(Event, draft.id, owner, workspace.id)

      assert {:error, %{errors: [%Ash.Error.Query.NotFound{}]}} =
               reload(Event, draft.id, member, workspace.id)

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

  describe "draft 读收紧（Owner/Admin + 角色组合 + 跨租户）" do
    test "纯 Admin 可读 draft；平台管理员 bypass 仍可读 draft" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      admin = Fixtures.register_user("vis-ws-admin")
      Fixtures.add_member(workspace, admin, [:admin])
      platform = Fixtures.platform_admin("vis-platform")

      draft = create_draft(workspace, owner, Event, "Admin Draft")

      assert {:ok, _} = reload(Event, draft.id, admin, workspace.id)
      assert {:ok, _} = reload(Event, draft.id, platform, workspace.id)
    end

    test "成员角色单角色与两两组合读 draft 均 NotFound" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      draft = create_draft(workspace, owner, Event, "Role Matrix Draft")

      for roles <- member_role_combos() do
        actor = Fixtures.register_user("vis-role-#{Enum.join(roles, "-")}")
        Fixtures.add_member(workspace, actor, roles)

        assert {:error, %{errors: [%Ash.Error.Query.NotFound{}]}} =
                 reload(Event, draft.id, actor, workspace.id)
      end
    end

    test "跨租户：A 台 Owner 读 B 台 draft NotFound" do
      a = Fixtures.workspace_with_member()
      b = Fixtures.workspace_with_member()
      Fixtures.add_member(b.workspace, a.owner)

      draft_b = create_draft(b.workspace, b.owner, Event, "B Draft")

      assert {:ok, _} = reload(Event, draft_b.id, b.owner, b.workspace.id)

      assert {:error, %{errors: [%Ash.Error.Query.NotFound{}]}} =
               reload(Event, draft_b.id, a.owner, b.workspace.id)
    end

    test "成员可读非 draft 的 open/closed/cancelled × visibility 组合" do
      %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()

      public_open = EventFixtures.create_event(workspace, owner, %{visibility: :public})
      workspace_open = EventFixtures.create_event(workspace, owner, %{visibility: :workspace})

      closed = EventFixtures.create_event(workspace, owner)

      {:ok, closed} =
        closed
        |> Ash.Changeset.for_update(:close, %{}, tenant: workspace.id, actor: owner)
        |> Ash.update(tenant: workspace.id, actor: owner)

      cancelled = EventFixtures.create_event(workspace, owner)

      {:ok, cancelled} =
        cancelled
        |> Ash.Changeset.for_update(:cancel, %{}, tenant: workspace.id, actor: owner)
        |> Ash.update(tenant: workspace.id, actor: owner)

      assert {:ok, _} = reload(Event, public_open.id, member, workspace.id)
      assert {:ok, _} = reload(Event, workspace_open.id, member, workspace.id)
      assert {:ok, _} = reload(Event, closed.id, member, workspace.id)
      assert {:ok, _} = reload(Event, cancelled.id, member, workspace.id)
    end

    test "成员按 slug 读 draft Event NotFound" do
      %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()
      draft = create_draft(workspace, owner, Event, "Slug Draft")

      assert {:ok, nil} =
               Event
               |> Ash.Query.for_read(:get_by_slug, %{slug: draft.slug})
               |> Ash.read_one(actor: member, tenant: workspace.id)
    end
  end

  defp create_draft(workspace, actor, resource, title) do
    resource
    |> Ash.Changeset.for_create(:create, %{title: title, enrollment_policy: :open},
      tenant: workspace.id
    )
    |> Ash.create!(tenant: workspace.id, actor: actor)
  end

  defp member_role_combos do
    singles = [[], [:tutor], [:volunteer], [:learner]]

    pairs =
      for a <- [:tutor, :volunteer, :learner],
          b <- [:tutor, :volunteer, :learner],
          a < b,
          do: [a, b]

    singles ++ pairs
  end
end
