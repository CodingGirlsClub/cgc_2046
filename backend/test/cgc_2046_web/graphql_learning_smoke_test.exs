defmodule Cgc2046Web.GraphqlLearningSmokeTest do
  @moduledoc """
  #844 零命中字段补测（阶段 A camelCase 检索零命中的两个查询）：最小冒烟，
  走真实 /api/graphql 入口、断言具体返回字段——钉住字段在 SDL 面存在且
  resolver 接线工作，为 Learning 域搬迁提供回归锚点。

  独立文件（不改既有 graphql_course_learning_test.exs）：helper 按该文件
  同款写法自持，避免与并行 worktree 活动竞争同一 tracked 文件。
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures

  defp content_fixture do
    %{
      "goals" => ["能写程序"],
      "issues" => [
        %{
          "id" => "py-first",
          "kind" => "handwork",
          "title" => "第一个程序",
          "story" => %{
            "as_a" => "学员",
            "given" => ["无"],
            "goal" => "独立写问候程序",
            "materials" => [%{"kind" => "web", "title" => "Python 教程", "url" => "https://ex.io"}],
            "checklist" => [
              %{"id" => "c1", "text" => "程序能运行并正确输出"},
              %{"id" => "c2", "text" => "能讲懂代码"}
            ]
          },
          "objectives" => [
            %{
              "id" => "obj-run",
              "title" => "能运行问候程序",
              "required" => true,
              "prereq_ids" => [],
              "rubric" => [%{"id" => "r1", "text" => "程序能运行"}]
            }
          ]
        }
      ]
    }
  end

  defp save_content(workspace, actor, course) do
    Cgc2046.Curriculum.Output
    |> Ash.Changeset.for_create(
      :upsert_content,
      %{
        key: Cgc2046.Curriculum.Output.course_key(course.id),
        kind: :issues,
        data: content_fixture(),
        submitted_by: actor.id,
        base_version: 0
      },
      tenant: workspace.id,
      actor: actor
    )
    |> Ash.create!(tenant: workspace.id, actor: actor)
  end

  # courseContent 读面要求 published revision（发布时点快照 + 绑定指针），
  # 造法同 graphql_course_learning_test.exs 的 S6 已发布用例。
  defp publish_revision(workspace, course) do
    {:ok, revision} =
      Cgc2046.Curriculum.CourseRevision
      |> Ash.Changeset.for_create(
        :create,
        %{
          course_id: course.id,
          number: 1,
          content: content_fixture(),
          published_at: DateTime.utc_now()
        },
        tenant: workspace.id
      )
      |> Ash.create(tenant: workspace.id, authorize?: false)

    course
    |> Ash.Changeset.for_update(
      :bind_current_revision,
      %{current_revision_id: revision.id},
      tenant: workspace.id
    )
    |> Ash.update!(tenant: workspace.id, authorize?: false)
  end

  defp enroll(course, learner) do
    {:ok, _enrollment} =
      Cgc2046.Admission.Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{course_id: course.id, user_id: learner.id})
      |> Ash.create(tenant: course.workspace_id, actor: learner)

    :ok
  end

  defp sign_in_token(user) do
    mutation = """
    mutation {
      signIn(login: "#{user.email}", password: "#{Fixtures.password()}") { id }
    }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => mutation})

    assert %{"data" => %{"signIn" => %{"id" => _}}} = json_response(conn, 200)
    conn.resp_cookies["cgc_token"].value
  end

  defp graphql(query, token) do
    conn =
      if token do
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
      else
        build_conn()
      end

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end

  describe "courseContent 已发布内容（#844 零命中补测）" do
    defp course_content_query(course_id) do
      """
      query {
        courseContent(courseId: "#{course_id}") {
          courseId title description revisionNumber publishedAt content
        }
      }
      """
    end

    test "报名学员得内容：courseId/title 具体值，content JSON 含 goals" do
      admin = Fixtures.platform_admin("cc-content")
      workspace = Fixtures.create_workspace(admin)
      course = EventsFixtures.create_course(workspace, admin, %{title: "内容课程"})
      save_content(workspace, admin, course)
      publish_revision(workspace, course)

      learner = Fixtures.register_user("cc-content-learner")
      Fixtures.add_member(workspace, learner, [:learner])
      enroll(course, learner)

      response = graphql(course_content_query(course.id), sign_in_token(learner))

      assert %{"data" => %{"courseContent" => content}} = response
      assert content["courseId"] == course.id
      assert content["title"] == "内容课程"
      assert content["revisionNumber"] == 1
      assert %{"goals" => ["能写程序"]} = Jason.decode!(content["content"])
    end

    test "匿名 → null（不落 unauthorized）" do
      admin = Fixtures.platform_admin("cc-anon")
      workspace = Fixtures.create_workspace(admin)
      course = EventsFixtures.create_course(workspace, admin, %{title: "匿名内容课程"})
      save_content(workspace, admin, course)
      publish_revision(workspace, course)

      response = graphql(course_content_query(course.id), nil)
      assert %{"data" => %{"courseContent" => nil}} = response
    end
  end

  describe "courseLearningAnalytics 学习聚合（#844 零命中补测）" do
    defp analytics_query(course_id) do
      """
      query {
        courseLearningAnalytics(courseId: "#{course_id}") {
          runStats { totalRuns activeRuns completedRuns completionRate }
          objectives { objectiveId title required mastered developing needsReview unassessed }
          dropOff { staleRunCount }
          generatedAt
        }
      }
      """
    end

    test "staff（owner）得聚合：runStats 计数 + objectives 列表 + dropOff + generatedAt" do
      admin = Fixtures.platform_admin("ca-owner")
      workspace = Fixtures.create_workspace(admin)
      course = EventsFixtures.create_course(workspace, admin, %{title: "聚合课程"})
      save_content(workspace, admin, course)

      response = graphql(analytics_query(course.id), sign_in_token(admin))

      assert %{"data" => %{"courseLearningAnalytics" => analytics}} = response

      assert %{"totalRuns" => total, "activeRuns" => _, "completedRuns" => _} =
               analytics["runStats"]

      assert is_integer(total)
      assert is_list(analytics["objectives"])
      assert %{"staleRunCount" => stale} = analytics["dropOff"]
      assert is_integer(stale)
      assert is_binary(analytics["generatedAt"])
    end

    test "非 staff（已报名 learner）→ null（不含 learner evidence 面）" do
      admin = Fixtures.platform_admin("ca-learner")
      workspace = Fixtures.create_workspace(admin)
      course = EventsFixtures.create_course(workspace, admin, %{title: "学员聚合课程"})

      learner = Fixtures.register_user("ca-learner-user")
      Fixtures.add_member(workspace, learner, [:learner])
      enroll(course, learner)

      response = graphql(analytics_query(course.id), sign_in_token(learner))
      assert %{"data" => %{"courseLearningAnalytics" => nil}} = response
    end
  end
end
