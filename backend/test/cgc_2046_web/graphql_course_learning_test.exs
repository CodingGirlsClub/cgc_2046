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
          },
          "objectives" => [
            %{
              "id" => "obj-explain",
              "title" => "能讲懂变量绑定",
              "required" => true,
              "prereq_ids" => ["obj-run"],
              "rubric" => [%{"id" => "r1", "text" => "能解释绑定与读出"}]
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

  defp enroll(course, learner) do
    {:ok, enrollment} =
      Cgc2046.Admission.Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{course_id: course.id, user_id: learner.id})
      |> Ash.create(tenant: course.workspace_id, actor: learner)

    enrollment
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
        courseId title slug staleRevision revisionNumber
        objectives { id title required mastery everMastered locked attemptCount
          missingPrereqIds { id title } }
        nextAction { kind objectiveId reason }
        progress { masteredRequired totalRequired complete }
      }
    }
    """
  end

  defp my_runs_query do
    """
    query {
      myLearningRuns {
        runId targetTitle status staleRevision courseId
        progress { masteredRequired totalRequired complete }
        nextAction { kind objectiveId reason }
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
              hd(content_fixture()["issues"])
              |> Map.take(["id", "kind", "title", "story", "objectives"]),
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

  describe "myLearningRuns 字段切换(KD8→S8 objective 口径)" do
    test "objective 进度返回正确;issue 口径旧字段在 SDL 不存在" do
      admin = Fixtures.platform_admin("u7-runs")
      workspace = Fixtures.create_workspace(admin)

      course =
        EventFixtures.create_course(workspace, admin, %{title: "课程", slug: "python-intro"})

      learner = Fixtures.register_user("u7-runs-learner")
      enrollment = enroll(course, learner)

      # S8:发布 revision（run 锚定它）——goals 供 progress;objectives 供掌握
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

      {:ok, run} =
        Cgc2046.Workflows.WorkflowRun
        |> Ash.Changeset.for_create(
          :create,
          %{
            definition_id: published.id,
            definition_version: published.version,
            input_snapshot: %{
              "key" => Cgc2046.Learning.Runs.instance_key(enrollment.id, revision.id),
              "enrollment_id" => enrollment.id,
              "user_id" => learner.id,
              "course_id" => course.id,
              "course_revision_id" => revision.id
            }
          },
          tenant: workspace.id,
          actor: admin
        )
        |> Ash.create(tenant: workspace.id, actor: admin)

      run
      |> Ash.Changeset.for_update(:start, %{}, tenant: workspace.id, authorize?: false)
      |> Ash.update!(tenant: workspace.id, authorize?: false)

      response = graphql(my_runs_query(), sign_in_token(learner))

      assert %{"data" => %{"myLearningRuns" => [row]}} = response
      assert row["runId"] == run.id
      assert row["staleRevision"] == false
      assert row["courseId"] == course.id
      assert row["progress"]["masteredRequired"] == 0
      assert row["progress"]["totalRequired"] == 2
      assert row["progress"]["complete"] == false
      # next_action = 内容序首个必修（unassessed 且已解锁）
      assert row["nextAction"]["kind"] == "next_required"
      assert row["nextAction"]["objectiveId"] == "obj-run"

      # KD8→S8:issue 口径旧字段不进 SDL
      sdl = File.read!("priv/graphql/schema.graphql")

      my_learning_run_block =
        Regex.run(~r/type MyLearningRun \{[^}]*\}/s, sdl) |> List.first()

      assert my_learning_run_block =~ "staleRevision"
      assert my_learning_run_block =~ "progress"
      assert my_learning_run_block =~ "nextAction"
      refute my_learning_run_block =~ "doneIssues"
      refute my_learning_run_block =~ "currentIssueKey"
      refute my_learning_run_block =~ "currentIssueTitle"
    end
  end

  describe "课程学习详情(R11 抽屉数据→S8 objective 口径)" do
    test "本人有 attempts:掌握投影 + 先修锁 + next_action" do
      admin = Fixtures.platform_admin("u7-detail")
      workspace = Fixtures.create_workspace(admin)

      course =
        EventFixtures.create_course(workspace, admin, %{title: "课程", slug: "python-intro"})

      learner = Fixtures.register_user("u7-detail-learner")
      enrollment = enroll(course, learner)

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
              "key" => Cgc2046.Learning.Runs.instance_key(enrollment.id, revision.id),
              "enrollment_id" => enrollment.id,
              "user_id" => learner.id,
              "course_id" => course.id,
              "course_revision_id" => revision.id
            }
          },
          tenant: workspace.id,
          actor: admin
        )
        |> Ash.create(tenant: workspace.id, actor: admin)

      run
      |> Ash.Changeset.for_update(:start, %{}, tenant: workspace.id, authorize?: false)
      |> Ash.update!(tenant: workspace.id, authorize?: false)

      # 一条 qualifying attempt:obj-run mastered(obj-explain 仍锁)
      {:ok, _} =
        Cgc2046.Learning.Attempt
        |> Ash.Changeset.for_create(
          :create,
          %{
            learning_run_id: run.id,
            course_revision_id: revision.id,
            objective_id: "obj-run",
            evidence: "跑通了",
            rubric_results: [%{"criterion_id" => "r1", "met" => true}],
            passed: true,
            rationale: "证据可复核",
            confidence: 0.9
          },
          tenant: workspace.id,
          authorize?: false
        )
        |> Ash.create(tenant: workspace.id, authorize?: false)

      response = graphql(detail_query(course.id), sign_in_token(learner))

      assert %{"data" => %{"courseLearningDetail" => detail}} = response
      assert detail["courseId"] == course.id
      assert detail["staleRevision"] == false
      assert detail["revisionNumber"] == 1

      [obj_run, obj_explain] = detail["objectives"]
      assert obj_run["mastery"] == "mastered"
      assert obj_run["everMastered"] == true
      assert obj_run["attemptCount"] == 1
      assert obj_run["locked"] == false

      assert obj_explain["mastery"] == "unassessed"
      # obj-run 已 ever_mastered → 先修满足,已解锁(R41:解锁看 ever_mastered 粘性)
      assert obj_explain["locked"] == false
      assert obj_explain["missingPrereqIds"] == []

      assert detail["progress"]["masteredRequired"] == 1
      assert detail["progress"]["totalRequired"] == 2
      assert detail["progress"]["complete"] == false
      assert detail["nextAction"]["objectiveId"] == "obj-explain"
      assert detail["nextAction"]["kind"] == "next_required"
    end

    test "本人无 attempts:全 unassessed;未报名非成员 → null" do
      admin = Fixtures.platform_admin("u7-detail-empty")
      workspace = Fixtures.create_workspace(admin)

      course =
        EventFixtures.create_course(workspace, admin, %{title: "课程", slug: "python-intro"})

      learner = Fixtures.register_user("u7-detail-empty-learner")
      enroll(course, learner)
      save_content(workspace, admin, course)

      response = graphql(detail_query(course.id), sign_in_token(learner))

      assert %{"data" => %{"courseLearningDetail" => detail}} = response
      assert Enum.all?(detail["objectives"], &(&1["mastery"] == "unassessed"))
      assert detail["progress"]["complete"] == false

      # 未报名非成员 → null(不泄存在性)
      outsider = Fixtures.register_user("u7-detail-outsider")
      response2 = graphql(detail_query(course.id), sign_in_token(outsider))
      assert %{"data" => %{"courseLearningDetail" => nil}} = response2
    end
  end
end
