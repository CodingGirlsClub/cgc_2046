defmodule Cgc2046Web.GraphqlCourseLearningTest do
  @moduledoc """
  U7(切片 H, #180)GraphQL 面三件:

  - 匿名课程地图:public+open 可见 / workspace-only+draft 不可见 /
    响应无 checklist 字段(R10)
  - myLearningRuns 新字段返回正确;旧字段不存在(schema 断言,KD8)
  - 学习详情:本人有/无记录两形状;越权(他人视角)不可构造(恒 actor)
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Learning.LearningRecord

  require Ash.Query

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
            "materials" => [%{"title" => "Python 教程", "ref" => "https://ex.io"}],
            "checklist" => [
              %{"id" => "c1", "text" => "程序能运行并正确输出"},
              %{"id" => "c2", "text" => "能讲懂代码"}
            ]
          }
        },
        %{
          "id" => "py-vars",
          "kind" => "thoughtwork",
          "title" => "变量与数据",
          "story" => %{
            "as_a" => "学员",
            "given" => ["py-first"],
            "goal" => "理解变量绑定",
            "materials" => [],
            "checklist" => [%{"id" => "c1", "text" => "能解释绑定与读出"}]
          }
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

  defp enroll(course, learner) do
    {:ok, enrollment} =
      Cgc2046.Admission.Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{course_id: course.id, user_id: learner.id})
      |> Ash.create(tenant: course.workspace_id, actor: learner)

    enrollment
  end

  defp save_record(workspace, learner, course, issue_id, item_id) do
    LearningRecord
    |> Ash.Changeset.for_create(
      :upsert_record,
      %{
        course_id: course.id,
        user_id: learner.id,
        issue_id: issue_id,
        item_id: item_id,
        done: true,
        evidence: "跑通了",
        recorded_at: DateTime.utc_now()
      },
      tenant: workspace.id,
      actor: learner
    )
    |> Ash.create!(tenant: workspace.id, actor: learner)
  end

  defp course_map_query(slug) do
    """
    query {
      courseMap(slug: "#{slug}") {
        courseId title slug
        issues { key title kind goal }
      }
    }
    """
  end

  defp detail_query(course_id) do
    """
    query {
      courseLearningDetail(courseId: "#{course_id}") {
        courseId title slug goals
        progress { doneIssues totalIssues currentIssueTitle currentIssueKey }
        issues { key id title kind status
          story { as_a goal given materials { title ref }
            checklist { id text done evidence } } }
      }
    }
    """
  end

  defp my_runs_query do
    """
    query {
      myLearningRuns {
        runId targetTitle status
        doneIssues totalIssues currentIssueTitle currentIssueKey courseId
      }
    }
    """
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

  describe "匿名课程地图(R10)" do
    test "public+open 可见:issue key/title/kind/goal;响应无 checklist 字段" do
      admin = Fixtures.platform_admin("u7-map")
      workspace = Fixtures.create_workspace(admin)

      course =
        EventFixtures.create_course(workspace, admin, %{title: "Python 入门", slug: "python-intro"})

      save_content(workspace, admin, course)

      response = graphql(course_map_query(course.slug), nil)

      assert %{"data" => %{"courseMap" => course_data}} = response
      map = course_data["issues"]

      assert length(map) == 2
      first = Enum.at(map, 0)
      assert first["key"] == "PYTH-01"
      assert first["title"] == "第一个程序"
      assert first["kind"] == "handwork"
      assert first["goal"] == "独立写问候程序"
      assert Enum.at(map, 1)["key"] == "PYTH-02"

      # R10:不露 checklist(响应全文不得出现)
      refute Jason.encode!(response) =~ "checklist"
      refute Jason.encode!(response) =~ "程序能运行并正确输出"
    end

    test "无内容课程:issueMap 为空数组(不报错)" do
      admin = Fixtures.platform_admin("u7-map-empty")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{title: "空课"})

      response = graphql(course_map_query(course.slug), nil)
      assert %{"data" => %{"courseMap" => %{"issues" => []}}} = response
    end

    test "S6 已发布读 published 版:草稿后续编辑不影响公开面;未发布回退草稿" do
      admin = Fixtures.platform_admin("s6-map-pub")
      workspace = Fixtures.create_workspace(admin)

      course =
        EventFixtures.create_course(workspace, admin, %{title: "发布课", slug: "pub-map"})

      save_content(workspace, admin, course)

      # 发布 revision 1（content = 发布时点草稿快照）+ 绑定 current_revision_id
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

      # 发布后草稿被改（次周期修订中）——公开面不得读到
      draft = %{
        content_fixture()
        | "issues" => [
            put_in(
              hd(content_fixture()["issues"]) |> Map.take(["id", "kind", "title", "story"]),
              ["story", "goal"],
              "次周期修订中的新目标"
            )
            | tl(content_fixture()["issues"])
          ]
      }

      Cgc2046.Curriculum.Output
      |> Ash.Changeset.for_create(
        :upsert_content,
        %{
          key: Cgc2046.Curriculum.Output.course_key(course.id),
          kind: :issues,
          data: draft,
          submitted_by: admin.id,
          base_version: 1
        },
        tenant: workspace.id,
        actor: admin
      )
      |> Ash.create!(tenant: workspace.id, actor: admin)

      response = graphql(course_map_query(course.slug), nil)

      assert %{"data" => %{"courseMap" => course_data}} = response
      assert [first | _] = course_data["issues"]
      assert first["goal"] == "独立写问候程序"
      refute Jason.encode!(response) =~ "次周期修订中的新目标"
    end

    test "workspace-only / draft 不可见(404 语义)" do
      admin = Fixtures.platform_admin("u7-map-ws")
      workspace = Fixtures.create_workspace(admin)

      ws_only =
        EventFixtures.create_course(workspace, admin, %{visibility: :workspace, title: "内部课"})

      draft =
        Cgc2046.Courses.Course
        |> Ash.Changeset.for_create(
          :create,
          %{title: "草稿课", workspace_id: workspace.id},
          tenant: workspace.id,
          actor: admin
        )
        |> Ash.create!(tenant: workspace.id, actor: admin)

      for course <- [ws_only, draft] do
        assert %{"data" => %{"courseMap" => nil}} =
                 graphql(course_map_query(course.slug), nil)
      end
    end

    test "S6-03 内部发布指针不进公共 SDL(currentRevisionId 全部声明面缺席)" do
      # courseMap 是 S6 唯一的公共 GraphQL 需求(内容源切换,输出形状零变化)；
      # current_revision_id 是内部发布指针(public?: false),不得生成
      # output field / filter / sort 任何声明面——防公共契约意外扩张回归
      sdl = File.read!("priv/graphql/schema.graphql")

      refute sdl =~ "currentRevisionId"
      refute sdl =~ "CourseFilterCurrentRevisionId"
      refute sdl =~ "CURRENT_REVISION_ID"

      # courseMap 输出形状(S6 切内容源后)不变:仍只投 course_id/title/slug/goals/issues
      course_map_block = Regex.run(~r/type CourseMap \{[^}]*\}/s, sdl) |> List.first()
      assert course_map_block =~ "courseId"
      refute course_map_block =~ "currentRevisionId"
    end
  end

  describe "myLearningRuns 字段切换(KD8)" do
    test "新字段返回正确;旧字段在 SDL 不存在" do
      admin = Fixtures.platform_admin("u7-runs")
      workspace = Fixtures.create_workspace(admin)

      course =
        EventFixtures.create_course(workspace, admin, %{title: "课程", slug: "python-intro"})

      learner = Fixtures.register_user("u7-runs-learner")
      enrollment = enroll(course, learner)
      save_content(workspace, admin, course)

      # 造一个 running 学习 run 锚定 enrollment
      {:ok, defn} =
        Cgc2046.Workflows.WorkflowDefinition
        |> Ash.Changeset.for_create(
          :create,
          %{name: "学习", type: :learning, input_schema: %{}, node_def: %{"steps" => []}},
          tenant: workspace.id,
          actor: admin
        )
        |> Ash.create(tenant: workspace.id, actor: admin)

      {:ok, published} =
        defn
        |> Ash.Changeset.for_update(:publish, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      {:ok, run} =
        Cgc2046.Workflows.WorkflowRun
        |> Ash.Changeset.for_create(
          :create,
          %{
            definition_id: published.id,
            definition_version: published.version,
            input_snapshot: %{
              "key" => "enrollment_#{enrollment.id}",
              "enrollment_id" => enrollment.id,
              "user_id" => learner.id,
              "course_id" => course.id
            }
          },
          tenant: workspace.id,
          actor: admin
        )
        |> Ash.create(tenant: workspace.id, actor: admin)

      run
      |> Ash.Changeset.for_update(:start, %{}, tenant: workspace.id, authorize?: false)
      |> Ash.update!(tenant: workspace.id, authorize?: false)

      # 一条 done 记录:issue1 部分完成
      save_record(workspace, learner, course, "py-first", "c1")

      response = graphql(my_runs_query(), sign_in_token(learner))

      assert %{"data" => %{"myLearningRuns" => [row]}} = response
      assert row["runId"] == run.id
      assert row["doneIssues"] == 0
      assert row["totalIssues"] == 2
      assert row["currentIssueTitle"] == "第一个程序"
      assert row["currentIssueKey"] == "PYTH-01"
      assert row["courseId"] == course.id

      # KD8:旧字段不进 SDL(schema 断言)
      sdl = File.read!("priv/graphql/schema.graphql")

      my_learning_run_block =
        Regex.run(~r/type MyLearningRun \{[^}]*\}/s, sdl) |> List.first()

      assert my_learning_run_block =~ "doneIssues"
      assert my_learning_run_block =~ "currentIssueKey"
      refute my_learning_run_block =~ "completedManualSteps"
      refute my_learning_run_block =~ "totalManualSteps"
      refute my_learning_run_block =~ "currentStepTitle"
    end
  end

  describe "课程学习详情(R11 抽屉数据)" do
    test "本人有记录:三态 + checklist 合成 + progress" do
      admin = Fixtures.platform_admin("u7-detail")
      workspace = Fixtures.create_workspace(admin)

      course =
        EventFixtures.create_course(workspace, admin, %{title: "课程", slug: "python-intro"})

      learner = Fixtures.register_user("u7-detail-learner")
      enroll(course, learner)
      save_content(workspace, admin, course)

      # issue1 全 done(c1+c2)、issue2 无记录
      save_record(workspace, learner, course, "py-first", "c1")
      save_record(workspace, learner, course, "py-first", "c2")

      response = graphql(detail_query(course.id), sign_in_token(learner))

      assert %{"data" => %{"courseLearningDetail" => detail}} = response

      assert detail["courseId"] == course.id
      assert detail["goals"] == ["能写程序"]

      [issue1, issue2] = detail["issues"]
      assert issue1["key"] == "PYTH-01"
      assert issue1["status"] == "done"

      checklist1 = issue1["story"]["checklist"]
      assert length(checklist1) == 2
      assert Enum.all?(checklist1, & &1["done"])
      assert Enum.any?(checklist1, &(&1["evidence"] == "跑通了"))

      assert issue2["key"] == "PYTH-02"
      assert issue2["status"] == "todo"
      assert Enum.all?(issue2["story"]["checklist"], &(!&1["done"]))

      assert detail["progress"]["doneIssues"] == 1
      assert detail["progress"]["totalIssues"] == 2
      assert detail["progress"]["currentIssueTitle"] == "变量与数据"
      assert detail["progress"]["currentIssueKey"] == "PYTH-02"
    end

    test "本人无记录:全 Todo 形状" do
      admin = Fixtures.platform_admin("u7-detail-empty")
      workspace = Fixtures.create_workspace(admin)

      course =
        EventFixtures.create_course(workspace, admin, %{title: "课程", slug: "python-intro"})

      learner = Fixtures.register_user("u7-detail-empty-learner")
      enroll(course, learner)
      save_content(workspace, admin, course)

      response = graphql(detail_query(course.id), sign_in_token(learner))

      assert %{"data" => %{"courseLearningDetail" => detail}} = response
      assert Enum.all?(detail["issues"], &(&1["status"] == "todo"))
      assert detail["progress"]["doneIssues"] == 0
      assert detail["progress"]["currentIssueKey"] == "PYTH-01"
    end

    test "未报名非成员 → null;查询无他人视角参数(恒 actor)" do
      admin = Fixtures.platform_admin("u7-detail-deny")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{title: "课程"})
      save_content(workspace, admin, course)

      outsider = Fixtures.register_user("u7-detail-outsider")

      assert %{"data" => %{"courseLearningDetail" => nil}} =
               graphql(detail_query(course.id), sign_in_token(outsider))

      # 查询 schema 无 userId 参数(恒 actor,他人视角不可构造)
      sdl = File.read!("priv/graphql/schema.graphql")
      assert sdl =~ "courseLearningDetail(courseId: ID!)"
    end
  end
end
