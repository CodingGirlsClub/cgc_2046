defmodule Cgc2046.Events.EventSlugTest do
  @moduledoc """
  E-5 #50 slug 约束：自动生成、单段格式校验、显式合法 slug 保留（Event/Course 双覆盖）。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Courses.Course
  alias Cgc2046.Events.Event

  defp create_event(workspace, admin, attrs \\ %{}) do
    Event
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{title: "Slug Test", enrollment_policy: :open}, attrs),
      tenant: workspace.id
    )
    |> Ash.create(tenant: workspace.id, actor: admin)
  end

  test "未传 slug 自动生成合法段；显式合法 slug 保留" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)

    assert {:ok, generated} = create_event(workspace, admin)
    assert generated.slug =~ ~r/^e-[a-f0-9]{8}$/

    assert {:ok, explicit} = create_event(workspace, admin, %{slug: "my-event-2026"})
    assert explicit.slug == "my-event-2026"
  end

  test "非法 slug（大写/路径分隔/URL 保留字符）拒绝" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)

    for bad <- ["Has-Upper", "a/b", "a?b", "a#b", "a b"] do
      assert {:error, error} = create_event(workspace, admin, %{slug: bad})
      assert Exception.message(error) =~ "slug must be a single lowercase URL segment"
    end
  end

  test "update 同样拒绝非法 slug（create 与 update 同规则）" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    {:ok, event} = create_event(workspace, admin)

    assert {:error, error} =
             event
             |> Ash.Changeset.for_update(:update, %{slug: "x/y"},
               tenant: workspace.id,
               actor: admin
             )
             |> Ash.update(tenant: workspace.id, actor: admin)

    assert Exception.message(error) =~ "slug must be a single lowercase URL segment"

    assert {:ok, kept} =
             event
             |> Ash.Changeset.for_update(:update, %{slug: "valid-slug-2"},
               tenant: workspace.id,
               actor: admin
             )
             |> Ash.update(tenant: workspace.id, actor: admin)

    assert kept.slug == "valid-slug-2"
  end

  test "Course 同构：自动生成 c- 前缀 + 非法 slug 拒绝" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)

    assert {:ok, course} =
             Course
             |> Ash.Changeset.for_create(
               :create,
               %{title: "Slug Course", enrollment_policy: :open},
               tenant: workspace.id
             )
             |> Ash.create(tenant: workspace.id, actor: admin)

    assert course.slug =~ ~r/^c-[a-f0-9]{8}$/

    assert {:error, _} =
             Course
             |> Ash.Changeset.for_create(
               :create,
               %{title: "Bad", enrollment_policy: :open, slug: "x/y"},
               tenant: workspace.id
             )
             |> Ash.create(tenant: workspace.id, actor: admin)
  end

  test "create 撞 slug（同 workspace）拒绝并给字段级错误" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)

    assert {:ok, _event} = create_event(workspace, admin, %{slug: "taken-same-ws"})

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             create_event(workspace, admin, %{slug: "taken-same-ws"})

    assert Enum.any?(errors, &(Exception.message(&1) =~ "already been taken"))
  end

  test "create 撞 slug（跨 workspace）拒绝：slug 全局唯一而非 per-workspace 唯一" do
    admin = Fixtures.platform_admin()
    workspace_a = Fixtures.create_workspace(admin)
    workspace_b = Fixtures.create_workspace(admin)

    assert {:ok, _event} = create_event(workspace_a, admin, %{slug: "taken-across-ws"})

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             create_event(workspace_b, admin, %{slug: "taken-across-ws"})

    assert Enum.any?(errors, &(Exception.message(&1) =~ "already been taken"))
  end

  test "update 撞 slug 拒绝" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    {:ok, _a} = create_event(workspace, admin, %{slug: "taken-update-a"})
    {:ok, b} = create_event(workspace, admin, %{slug: "taken-update-b"})

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             b
             |> Ash.Changeset.for_update(:update, %{slug: "taken-update-a"},
               tenant: workspace.id,
               actor: admin
             )
             |> Ash.update(tenant: workspace.id, actor: admin)

    assert Enum.any?(errors, &(Exception.message(&1) =~ "already been taken"))
  end

  test "Course create 撞 slug 拒绝并给字段级错误" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)

    create_course = fn ->
      Course
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Slug Course", enrollment_policy: :open, slug: "taken-course-slug"},
        tenant: workspace.id
      )
      |> Ash.create(tenant: workspace.id, actor: admin)
    end

    assert {:ok, _course} = create_course.()

    assert {:error, %Ash.Error.Invalid{errors: errors}} = create_course.()

    assert Enum.any?(errors, &(Exception.message(&1) =~ "already been taken"))
  end

  test "open 后改 slug 拒绝（Event）" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    {:ok, event} = create_event(workspace, admin, %{slug: "lock-open-event"})
    {:ok, launched} = launch(event, workspace, admin)
    assert launched.status == :open

    assert {:error, error} =
             launched
             |> Ash.Changeset.for_update(:update, %{slug: "new-slug"},
               tenant: workspace.id,
               actor: admin
             )
             |> Ash.update(tenant: workspace.id, actor: admin)

    assert Exception.message(error) =~ "slug is locked"

    # 错误须带被拒新值(可观测性:区分「参数丢失」与「锁定拦截」,2026-09-09 生产误判)
    assert Exception.message(error) =~ ~s(Value: "new-slug")

    assert Ash.get!(Event, event.id, tenant: workspace.id, authorize?: false).slug ==
             "lock-open-event"
  end

  test "closed 后改 slug 仍拒绝（Event）" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    {:ok, event} = create_event(workspace, admin, %{slug: "lock-closed-event"})
    {:ok, launched} = launch(event, workspace, admin)
    {:ok, closed} = close(launched, workspace, admin)
    assert closed.status == :closed

    assert {:error, error} =
             closed
             |> Ash.Changeset.for_update(:update, %{slug: "new-slug"},
               tenant: workspace.id,
               actor: admin
             )
             |> Ash.update(tenant: workspace.id, actor: admin)

    assert Exception.message(error) =~ "slug is locked"

    assert Ash.get!(Event, event.id, tenant: workspace.id, authorize?: false).slug ==
             "lock-closed-event"
  end

  test "Course 同构：open 后改 slug 拒绝" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)

    {:ok, course} =
      Course
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Slug Course", enrollment_policy: :open, slug: "lock-open-course"},
        tenant: workspace.id
      )
      |> Ash.create(tenant: workspace.id, actor: admin)

    {:ok, launched} = launch(course, workspace, admin)
    assert launched.status == :open

    assert {:error, error} =
             launched
             |> Ash.Changeset.for_update(:update, %{slug: "new-slug"},
               tenant: workspace.id,
               actor: admin
             )
             |> Ash.update(tenant: workspace.id, actor: admin)

    assert Exception.message(error) =~ "slug is locked"

    assert Ash.get!(Course, course.id, tenant: workspace.id, authorize?: false).slug ==
             "lock-open-course"
  end

  defp launch(entity, workspace, actor) do
    entity
    |> Ash.Changeset.for_update(:launch, %{}, tenant: workspace.id, actor: actor)
    |> Ash.update(tenant: workspace.id, actor: actor)
  end

  defp close(entity, workspace, actor) do
    entity
    |> Ash.Changeset.for_update(:close, %{}, tenant: workspace.id, actor: actor)
    |> Ash.update(tenant: workspace.id, actor: actor)
  end
end
