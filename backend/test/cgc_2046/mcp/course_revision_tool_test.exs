defmodule Cgc2046.Mcp.CourseRevisionToolTest do
  @moduledoc """
  get_course_revision 工具测试（role-agent-journeys-v2 S6，R29/R38；
  直接调 execute/2，course_prep_tools_test 同款模式）。

  授权三段（deferred 族工具层判定）：

  - workspace 成员 → 任意版本（缺省 = 最新，显式可取旧版本）；
  - 本人 confirmed enrollment（学员）→ 仅最新 published 版本，旧版本 forbidden；
  - outsider → forbidden 且 ToolCallLog 落行。

  发布布景直接建 CourseRevision（发布链路本身由 course_prep_tools_test
  「发布生成 CourseRevision」describe 覆盖）。
  """
  use Cgc2046.DataCase, async: true

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Curriculum.CourseRevision
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Mcp.ToolCallLog
  alias Cgc2046.Mcp.Tools.GetCourseRevision
  require Ash.Query

  defp frame_for(user), do: Frame.new(current_user: user)

  defp decode({:reply, response, _frame}) do
    [content] = response.content
    Jason.decode!(content["text"])
  end

  defp content_fixture(tag) do
    %{
      "goals" => ["目标 #{tag}"],
      "issues" => [
        %{
          "id" => "issue-1",
          "kind" => "handwork",
          "title" => "卡 #{tag}",
          "story" => %{
            "as_a" => "学员",
            "given" => [],
            "goal" => "目标 #{tag}",
            "materials" => [],
            "checklist" => [%{"id" => "c1", "text" => "项 #{tag}"}]
          },
          "objectives" => [
            %{
              "id" => "obj-#{tag}",
              "title" => "单元 #{tag}",
              "rubric" => [%{"id" => "r1", "text" => "达标 #{tag}"}]
            }
          ]
        }
      ]
    }
  end

  defp create_revision!(workspace, course, number, tag) do
    CourseRevision
    |> Ash.Changeset.for_create(
      :create,
      %{
        course_id: course.id,
        number: number,
        content: content_fixture(tag),
        published_at: DateTime.utc_now()
      },
      tenant: workspace.id
    )
    |> Ash.create!(tenant: workspace.id, authorize?: false)
  end

  # 学员：报名并确认（open 策略免费课程 create 即 confirmed；否则走 confirm）
  defp confirmed_learner(workspace, course, prefix) do
    learner = Fixtures.register_user(prefix)

    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{course_id: course.id, user_id: learner.id})
      |> Ash.create(tenant: workspace.id, actor: learner)

    if enrollment.status == :confirmed do
      learner
    else
      {:ok, _} =
        enrollment
        |> Ash.Changeset.for_update(:confirm_enrollment, %{})
        |> Ash.update(tenant: workspace.id, actor: Fixtures.platform_admin("#{prefix}-confirmer"))

      learner
    end
  end

  defp call(user, workspace, course, extra \\ %{}) do
    GetCourseRevision.execute(
      Map.merge(%{"workspace_id" => workspace.id, "course_id" => course.id}, extra),
      frame_for(user)
    )
  end

  describe "成员读面" do
    test "缺省 = 最新版本；显式 revision_number 可取旧版本；响应为快照原样投影" do
      owner = Fixtures.platform_admin("s6-crt-owner")
      workspace = Fixtures.create_workspace(owner)
      member = Fixtures.register_user("s6-crt-member")
      Fixtures.add_member(workspace, member, [:tutor])
      course = EventFixtures.create_course(workspace, owner, %{title: "版本课"})

      _v1 = create_revision!(workspace, course, 1, "v1")
      _v2 = create_revision!(workspace, course, 2, "v2")

      # 缺省 → 最新（v2）：content 原样投影（objectives 嵌于 issue，不注入展示 key）
      assert {:reply, _, _} = reply = call(member, workspace, course)
      latest = decode(reply)
      assert latest["course_id"] == course.id
      assert latest["revision_number"] == 2
      assert latest["goals"] == ["目标 v2"]
      assert [issue] = latest["issues"]
      assert issue["id"] == "issue-1"
      assert [%{"id" => "obj-v2"}] = issue["objectives"]
      refute Map.has_key?(issue, "key")
      assert is_binary(latest["published_at"])

      # 显式旧版本
      assert {:reply, _, _} = reply = call(member, workspace, course, %{"revision_number" => 1})
      assert decode(reply)["goals"] == ["目标 v1"]

      # 显式不存在的版本号
      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               call(member, workspace, course, %{"revision_number" => 9})

      assert msg =~ "course revision 9 not found"
    end

    test "从未发布过的课程 → 无已发布版本的明确错误（不回退草稿）" do
      owner = Fixtures.platform_admin("s6-crt-none")
      workspace = Fixtures.create_workspace(owner)
      course = EventFixtures.create_course(workspace, owner, %{})

      assert {:error, %Anubis.MCP.Error{message: msg}, _} = call(owner, workspace, course)
      assert msg =~ "no published revision for course #{course.id}"
    end
  end

  describe "学员读面（confirmed enrollment 仅最新版本）" do
    test "缺省与显式最新号放行；显式旧版本 forbidden" do
      owner = Fixtures.platform_admin("s6-crt-lrn")
      workspace = Fixtures.create_workspace(owner)
      course = EventFixtures.create_course(workspace, owner, %{})
      learner = confirmed_learner(workspace, course, "s6-crt-learner")

      _v1 = create_revision!(workspace, course, 1, "v1")
      _v2 = create_revision!(workspace, course, 2, "v2")

      # 缺省 → 最新
      assert {:reply, _, _} = reply = call(learner, workspace, course)
      assert decode(reply)["revision_number"] == 2

      # 显式最新号 → 放行
      assert {:reply, _, _} = reply = call(learner, workspace, course, %{"revision_number" => 2})
      assert decode(reply)["revision_number"] == 2

      # 显式旧版本 → forbidden
      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               call(learner, workspace, course, %{"revision_number" => 1})

      assert msg =~ "forbidden: enrolled learners can only read the latest published revision"
    end
  end

  describe "outsider 与审计" do
    test "outsider → forbidden 且 ToolCallLog 落 forbidden 行；成员成功读落成功行" do
      owner = Fixtures.platform_admin("s6-crt-out")
      workspace = Fixtures.create_workspace(owner)
      member = Fixtures.register_user("s6-crt-out-member")
      Fixtures.add_member(workspace, member, [])
      outsider = Fixtures.register_user("s6-crt-out-outsider")
      course = EventFixtures.create_course(workspace, owner, %{})

      _v1 = create_revision!(workspace, course, 1, "v1")

      assert {:error, %Anubis.MCP.Error{message: msg}, _} = call(outsider, workspace, course)
      assert msg =~ "forbidden: workspace member or enrolled learner required"

      outsider_logs =
        ToolCallLog
        |> Ash.Query.filter(user_id == ^outsider.id and tool == "get_course_revision")
        |> Ash.read!(authorize?: false)

      assert [%{result_status: :forbidden}] = outsider_logs

      assert {:reply, _, _} = call(member, workspace, course)

      member_logs =
        ToolCallLog
        |> Ash.Query.filter(user_id == ^member.id and tool == "get_course_revision")
        |> Ash.read!(authorize?: false)

      assert [%{result_status: :ok}] = member_logs
    end
  end
end
