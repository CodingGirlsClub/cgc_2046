defmodule Cgc2046.Curriculum.CourseRevisionTest do
  @moduledoc """
  CourseRevision 资源测试（role-agent-journeys-v2 S6，R29/R38）：

  - 不可变纪律：无 update/destroy action（唯一写入口 = 发布步的 :create）
  - `(course_id, number)` identity 唯一：撞号 → Invalid 报错；跨课程同号并存
  - number 下限约束（≥1）
  - policy：workspace 成员可读、outsider 读置空、平台管理员跨租户可读；
    成员可 create（发布步实为 authorize?: false 系统效应，资源层门槛兜底）
  """
  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Curriculum.CourseRevision
  alias Cgc2046.EventsFixtures, as: EventFixtures

  defp content_fixture do
    %{
      "goals" => ["能写简单程序"],
      "issues" => [
        %{
          "id" => "py-first-program",
          "kind" => "handwork",
          "title" => "写你的第一个程序",
          "story" => %{
            "as_a" => "学员",
            "given" => [],
            "goal" => "独立写问候程序",
            "materials" => [],
            "checklist" => [%{"id" => "c1", "text" => "程序能运行"}]
          },
          "objectives" => [
            %{
              "id" => "obj-hello",
              "title" => "能独立运行问候程序",
              "rubric" => [%{"id" => "r1", "text" => "程序能运行并输出问候"}]
            }
          ]
        }
      ]
    }
  end

  defp create_revision(workspace, course, number, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    attrs = %{
      course_id: course.id,
      number: number,
      content: content_fixture(),
      published_at: DateTime.utc_now()
    }

    changeset = Ash.Changeset.for_create(CourseRevision, :create, attrs, tenant: workspace.id)

    case actor do
      nil -> Ash.create(changeset, tenant: workspace.id, authorize?: false)
      actor -> Ash.create(changeset, tenant: workspace.id, actor: actor)
    end
  end

  describe "不可变纪律（R29）" do
    test "资源无 update/destroy action（只 create + read）" do
      actions = Ash.Resource.Info.actions(CourseRevision) |> Enum.map(& &1.name)

      assert :create in actions
      assert :read in actions
      refute :update in actions
      refute :destroy in actions
      assert Ash.Resource.Info.action(CourseRevision, :update) == nil
      assert Ash.Resource.Info.action(CourseRevision, :destroy) == nil
    end
  end

  describe "(course_id, number) 唯一与编号约束" do
    test "同课程撞号 → Invalid 报错；不同课程同号可并存" do
      admin = Fixtures.platform_admin("s6-cr-uniq")
      workspace = Fixtures.create_workspace(admin)
      course_a = EventFixtures.create_course(workspace, admin, %{title: "课程 A"})
      course_b = EventFixtures.create_course(workspace, admin, %{title: "课程 B"})

      assert {:ok, first} = create_revision(workspace, course_a, 1)
      assert first.number == 1
      assert first.workspace_id == workspace.id
      assert first.content == content_fixture()

      # 同 (course_id, number) 撞 identity 唯一索引
      assert {:error, %Ash.Error.Invalid{} = err} = create_revision(workspace, course_a, 1)
      assert Exception.message(err) =~ "has already been taken"

      # 不同课程同号合法（per-course 编号空间）
      assert {:ok, _} = create_revision(workspace, course_b, 1)
    end

    test "number < 1 → 约束报错" do
      admin = Fixtures.platform_admin("s6-cr-min")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{})

      assert {:error, %Ash.Error.Invalid{} = err} = create_revision(workspace, course, 0)
      assert Exception.message(err) =~ "number"
    end
  end

  describe "policy" do
    test "成员可读可建；outsider 读置空、建被拒；平台管理员跨租户可读" do
      admin = Fixtures.platform_admin("s6-cr-pol")
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("s6-cr-pol-member")
      Fixtures.add_member(workspace, member, [:tutor])
      outsider = Fixtures.register_user("s6-cr-pol-outsider")
      platform_admin = Fixtures.platform_admin("s6-cr-pol-padmin")
      course = EventFixtures.create_course(workspace, admin, %{})

      assert {:ok, revision} = create_revision(workspace, course, 1, actor: member)

      # 成员可读（租户内）
      assert {:ok, [%{id: revision_id}]} =
               Ash.read(CourseRevision, tenant: workspace.id, actor: member)

      assert revision_id == revision.id

      # outsider（他租户/无成员资格）读置空、建被拒
      assert {:ok, []} = Ash.read(CourseRevision, tenant: workspace.id, actor: outsider)

      assert {:error, %Ash.Error.Forbidden{}} =
               create_revision(workspace, course, 2, actor: outsider)

      # 平台管理员跨租户可读
      assert {:ok, [%{id: ^revision_id}]} =
               Ash.read(CourseRevision, tenant: workspace.id, actor: platform_admin)
    end
  end
end
