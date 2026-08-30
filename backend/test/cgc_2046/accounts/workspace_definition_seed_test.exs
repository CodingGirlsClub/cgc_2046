defmodule Cgc2046.Accounts.WorkspaceDefinitionSeedTest do
  @moduledoc """
  #348（UAT 缺陷 P1）：新建 workspace 自动 seed 三份协议定义
  （curriculum / learning / course_preparation，published）——
  教研链（PrepInstantiator）与学习 run（Runs.fetch_learning_definition）
  对新租户即刻可用。

  三条建台路径全覆盖（都汇聚 `Workspace :create` after_action）：
  - 域动作直建（Fixtures.create_workspace）
  - MCP admin_create_workspace 工具（确认流两段）
  - workspace_application 审批（admin_approve_workspace_application）

  集成链钉死（不手工造定义即证明）：新 workspace → create_course →
  PrepInstantiator.handle 实例化（无 definition_not_found）→ 学员
  start_learning_run 成功启动。
  """
  use Cgc2046.DataCase, async: true

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Curriculum.PrepInstantiator
  alias Cgc2046.Learning.Runs
  alias Cgc2046.Mcp.Tools.{AdminApproveWorkspaceApplication, CreateCourse, ConfirmOperation}
  alias Cgc2046.Mcp.Tools.{AdminCreateWorkspace, StartLearningRun}
  alias Cgc2046.Workflows.WorkflowDefinition

  require Ash.Query

  defp frame_for(user), do: Frame.new(current_user: user)

  defp published_definitions(workspace_id) do
    WorkflowDefinition
    |> Ash.Query.filter(status == :published)
    |> Ash.read!(authorize?: false, tenant: workspace_id)
  end

  defp assert_seeded_definitions(workspace_id) do
    defs = published_definitions(workspace_id)

    by_type = Map.new(defs, &{&1.type, &1})

    assert Map.keys(by_type) |> Enum.sort() == [:course_preparation, :curriculum, :learning]

    curriculum = by_type.curriculum
    assert curriculum.name == "教研 workflow"

    assert curriculum.node_def == %{
             "steps" => [%{"id" => "produce_issue_deck", "type" => "manual"}]
           }

    learning = by_type.learning
    assert learning.name == "学习 workflow"
    assert learning.node_def == %{"steps" => [%{"id" => "learning_loop", "type" => "manual"}]}

    prep = by_type.course_preparation
    assert prep.name == "课程教研 workflow"
    assert prep.node_def == %{"steps" => [%{"id" => "course_preparation", "type" => "manual"}]}

    # 消费面读取口径命中（tenant + published + version desc）
    assert {:ok, %WorkflowDefinition{type: :course_preparation}} =
             PrepInstantiator.fetch_prep_definition(workspace_id)

    assert {:ok, %WorkflowDefinition{type: :learning}} =
             Runs.fetch_learning_definition(workspace_id)
  end

  describe "域动作直建路径" do
    test "create 后三定义 published + 消费面可取；教研/学习闭环即用（#348 集成链）" do
      admin = Fixtures.platform_admin("ws-seed-direct")
      workspace = Fixtures.create_workspace(admin, %{slug: "ws-seed-direct", name: "直建台"})
      assert_seeded_definitions(workspace.id)

      # create_course → course.created 同款信号驱动 PrepInstantiator：
      # 修复前此处 fetch_prep_definition 落空（definition_not_found）
      learner = Fixtures.register_user("ws-seed-direct-learner")
      course = create_course_via_tool(admin, workspace)

      # handle 为信号路径语义（best-effort :ok）；产物经 course 引用链断言——
      # 修复前 fetch_prep_definition 落空 → 走 error 分支，workflow_run_id 恒 nil
      assert :ok =
               PrepInstantiator.handle("course.created", %{
                 "course_id" => course.id,
                 "title" => course.title
               })

      reloaded = reload_course(course)
      assert reloaded.workflow_run_id != nil

      run =
        Cgc2046.Workflows.WorkflowRun
        |> Ash.Query.filter(id == ^reloaded.workflow_run_id)
        |> Ash.read_one!(authorize?: false, tenant: workspace.id)

      assert run.workspace_id == workspace.id

      # 学员链布景:draft → open(状态机无直达公开 action,布景直写——
      # EventFixtures.force_open 同惯例;教研门禁语义由 prep 测试族单独覆盖)
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE courses SET status = 'open' WHERE id = $1",
          [Ecto.UUID.dump!(course.id)]
        )

      # 学员 run：发布 revision + 绑定 + confirmed enrollment 后 start_learning_run
      publish_revision(workspace, course)
      enroll_and_confirm(workspace, course, learner)

      assert {:reply, _, _} =
               reply =
               StartLearningRun.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(learner)
               )

      [content] = reply |> elem(1) |> Map.get(:content)
      payload = Jason.decode!(content["text"])
      assert payload["created"] == true
      assert is_binary(payload["run_id"])
    end
  end

  describe "admin_create_workspace 工具路径（确认流）" do
    test "confirm 建台后三定义就位" do
      admin = Fixtures.platform_admin("ws-seed-tool")
      owner = Fixtures.register_user("ws-seed-tool-owner")

      {:reply, _, _} =
        reply =
        AdminCreateWorkspace.execute(
          %{"name" => "工具建台", "slug" => "ws-seed-tool", "owner_user_id" => owner.id},
          frame_for(admin)
        )

      [content] = reply |> elem(1) |> Map.get(:content)
      %{"pending_id" => pending_id} = Jason.decode!(content["text"])

      {:reply, _, _} =
        ConfirmOperation.execute(%{"pending_id" => pending_id}, frame_for(admin))

      workspace = workspace_by_slug("ws-seed-tool")
      assert workspace != nil
      assert_seeded_definitions(workspace.id)
    end
  end

  describe "workspace_application 审批路径" do
    test "approve 建台后三定义就位" do
      admin = Fixtures.platform_admin("ws-seed-approve")
      applicant = Fixtures.register_user("ws-seed-approve-applicant")
      application = create_workspace_application(applicant, %{name: "审批建台"})

      {:reply, _, _} =
        reply =
        AdminApproveWorkspaceApplication.execute(
          %{"application_id" => application.id},
          frame_for(admin)
        )

      [content] = reply |> elem(1) |> Map.get(:content)
      %{"pending_id" => pending_id} = Jason.decode!(content["text"])

      {:reply, _, _} =
        ConfirmOperation.execute(%{"pending_id" => pending_id}, frame_for(admin))

      # approve 不回写 application.workspace_id（slug 即锚,治理 log 记 workspace_id）
      workspace = workspace_by_slug("ws-seed-approve-ws")
      assert workspace != nil
      assert_seeded_definitions(workspace.id)
    end
  end

  # --- helpers -------------------------------------------------------------------

  defp create_course_via_tool(admin, workspace) do
    {:reply, _, _} =
      reply =
      CreateCourse.execute(
        %{"workspace_id" => workspace.id, "title" => "直建台课程"},
        frame_for(admin)
      )

    [content] = reply |> elem(1) |> Map.get(:content)
    %{"course_id" => course_id} = Jason.decode!(content["text"])

    Cgc2046.Courses.Course
    |> Ash.Query.filter(id == ^course_id)
    |> Ash.read_one!(authorize?: false, tenant: workspace.id)
  end

  defp reload_course(course) do
    Cgc2046.Courses.Course
    |> Ash.Query.filter(id == ^course.id)
    |> Ash.read_one!(authorize?: false, tenant: course.workspace_id)
  end

  defp publish_revision(workspace, course) do
    content = %{
      "goals" => ["能写程序"],
      "issues" => [
        %{
          "id" => "ws-seed-issue",
          "kind" => "handwork",
          "title" => "第一个程序",
          "story" => %{"as_a" => "学员", "given" => [], "goal" => "独立写程序"},
          "objectives" => [
            %{
              "id" => "obj-seed",
              "title" => "能运行程序",
              "required" => true,
              "prereq_ids" => [],
              "rubric" => [%{"id" => "r1", "text" => "程序能运行"}]
            }
          ]
        }
      ]
    }

    {:ok, revision} =
      Cgc2046.Curriculum.CourseRevision
      |> Ash.Changeset.for_create(
        :create,
        %{course_id: course.id, number: 1, content: content, published_at: DateTime.utc_now()},
        tenant: workspace.id
      )
      |> Ash.create(tenant: workspace.id, authorize?: false)

    course
    |> Ash.Changeset.for_update(:bind_current_revision, %{current_revision_id: revision.id},
      tenant: workspace.id
    )
    |> Ash.update!(tenant: workspace.id, authorize?: false)

    revision
  end

  # 学员 confirmed enrollment（start_learning_run 六步链第一环）
  defp enroll_and_confirm(workspace, course, learner) do
    {:ok, enrollment} =
      Cgc2046.Admission.Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{course_id: course.id, user_id: learner.id})
      |> Ash.create(tenant: workspace.id, actor: learner)

    # create_course 工具缺省 enrollment_policy=open:报名即 confirmed(无需审批)
    assert enrollment.status == :confirmed
  end

  defp create_workspace_application(user, attrs) do
    changes =
      Map.merge(
        %{applicant_id: user.id, name: "审批建台", slug: "ws-seed-approve-ws", purpose: "测试申请"},
        attrs
      )

    {:ok, application} =
      Cgc2046.Accounts.WorkspaceApplication
      |> Ash.Changeset.for_create(:create, changes)
      |> Ash.create(actor: user)

    application
  end

  defp workspace_by_slug(slug) do
    Cgc2046.Accounts.Workspace
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.read_one!(authorize?: false)
  end
end
