defmodule Cgc2046.Events.EventSlugTest do
  @moduledoc """
  E-5 #50 slug 约束：自动生成、单段格式校验、显式合法 slug 保留（Event/Course 双覆盖）。
  """

  use Cgc2046.DataCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.{Course, Event}

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
end
