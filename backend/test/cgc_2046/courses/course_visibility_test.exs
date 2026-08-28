defmodule Cgc2046.Courses.CourseVisibilityTest do
  @moduledoc """
  Course 读策略同构覆盖：匿名白名单 + draft 收紧 + 角色组合 + 跨租户。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Courses.Course
  alias Cgc2046.EventsFixtures, as: EventFixtures

  defp reload(id, actor \\ nil, tenant \\ nil) do
    opts = [authorize?: true]
    opts = if actor, do: Keyword.put(opts, :actor, actor), else: opts
    opts = if tenant, do: Keyword.put(opts, :tenant, tenant), else: opts

    Ash.get(Course, id, opts)
  end

  describe "匿名读策略" do
    test "open+public 匿名可读，workspace / draft 匿名 NotFound" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      public_course = EventFixtures.create_course(workspace, admin)
      workspace_course = EventFixtures.create_course(workspace, admin, %{visibility: :workspace})
      draft = create_draft(workspace, admin, "Anon Draft")

      assert {:ok, _} = reload(public_course.id)

      assert {:error, %{errors: [%Ash.Error.Query.NotFound{}]}} = reload(workspace_course.id)
      assert {:error, %{errors: [%Ash.Error.Query.NotFound{}]}} = reload(draft.id)
    end
  end

  describe "draft 读收紧" do
    test "纯 Owner / 纯 Admin / 平台管理员可读 draft；普通成员 NotFound" do
      %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()
      admin = Fixtures.register_user("course-vis-admin")
      Fixtures.add_member(workspace, admin, [:admin])
      platform = Fixtures.platform_admin("course-vis-platform")

      draft = create_draft(workspace, owner, "Course Draft")

      assert {:ok, _} = reload(draft.id, owner, workspace.id)
      assert {:ok, _} = reload(draft.id, admin, workspace.id)
      assert {:ok, _} = reload(draft.id, platform, workspace.id)

      assert {:error, %{errors: [%Ash.Error.Query.NotFound{}]}} =
               reload(draft.id, member, workspace.id)
    end

    test "成员角色单角色与两两组合读 draft 均 NotFound" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      draft = create_draft(workspace, owner, "Course Role Matrix")

      for roles <- member_role_combos() do
        actor = Fixtures.register_user("course-role-#{Enum.join(roles, "-")}")
        Fixtures.add_member(workspace, actor, roles)

        assert {:error, %{errors: [%Ash.Error.Query.NotFound{}]}} =
                 reload(draft.id, actor, workspace.id)
      end
    end

    test "跨租户：A 台 Owner 读 B 台 draft NotFound" do
      a = Fixtures.workspace_with_member()
      b = Fixtures.workspace_with_member()
      Fixtures.add_member(b.workspace, a.owner)

      draft_b = create_draft(b.workspace, b.owner, "Course B Draft")

      assert {:ok, _} = reload(draft_b.id, b.owner, b.workspace.id)

      assert {:error, %{errors: [%Ash.Error.Query.NotFound{}]}} =
               reload(draft_b.id, a.owner, b.workspace.id)
    end

    test "成员可读非 draft 的 open/closed/cancelled × visibility 组合" do
      %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()

      public_open = EventFixtures.create_course(workspace, owner, %{visibility: :public})
      workspace_open = EventFixtures.create_course(workspace, owner, %{visibility: :workspace})

      closed = EventFixtures.create_course(workspace, owner)

      {:ok, closed} =
        closed
        |> Ash.Changeset.for_update(:close, %{}, tenant: workspace.id, actor: owner)
        |> Ash.update(tenant: workspace.id, actor: owner)

      cancelled = EventFixtures.create_course(workspace, owner)

      {:ok, cancelled} =
        cancelled
        |> Ash.Changeset.for_update(:cancel, %{}, tenant: workspace.id, actor: owner)
        |> Ash.update(tenant: workspace.id, actor: owner)

      assert {:ok, _} = reload(public_open.id, member, workspace.id)
      assert {:ok, _} = reload(workspace_open.id, member, workspace.id)
      assert {:ok, _} = reload(closed.id, member, workspace.id)
      assert {:ok, _} = reload(cancelled.id, member, workspace.id)
    end

    test "成员按 slug 读 draft Course NotFound" do
      %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()
      draft = create_draft(workspace, owner, "Course Slug Draft")

      assert {:ok, nil} =
               Course
               |> Ash.Query.for_read(:get_by_slug, %{slug: draft.slug})
               |> Ash.read_one(actor: member, tenant: workspace.id)
    end
  end

  defp create_draft(workspace, actor, title) do
    Course
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
