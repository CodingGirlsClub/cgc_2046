defmodule Cgc2046.Learning.LearningProgressWorkerTest do
  @moduledoc """
  LearningProgressWorker 完成判定升级测试(切片 H U4, #180)。

  - 全部 issue Done → run succeeded;部分 Done → 保持 running
  - 无内容课程(无 Curriculum.Output)→ 不判完成
  - 记录更新后下一轮扫描完成(F3 集成)
  """
  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  use Oban.Testing, repo: Cgc2046.Repo
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Learning.LearningRecord
  alias Cgc2046.Learning.LearningProgressWorker
  alias Cgc2046.Workflows.{WorkflowDefinition, WorkflowRun}

  require Ash.Query

  @issue_id "py-first-program"

  defp content_fixture do
    %{
      "goals" => ["能写程序"],
      "issues" => [
        %{
          "id" => @issue_id,
          "kind" => "handwork",
          "title" => "写你的第一个程序",
          "story" => %{
            "as_a" => "学员",
            "given" => [],
            "goal" => "独立写问候程序",
            "materials" => [],
            "checklist" => [
              %{"id" => "c1", "text" => "程序能运行并正确输出"},
              %{"id" => "c2", "text" => "能讲懂代码"}
            ]
          }
        }
      ]
    }
  end

  defp create_learning_definition(workspace, actor) do
    {:ok, defn} =
      WorkflowDefinition
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "学习 workflow",
          type: :learning,
          input_schema: %{},
          node_def: %{"steps" => [%{"id" => "learning_loop", "type" => "manual"}]}
        },
        tenant: workspace.id,
        actor: actor
      )
      |> Ash.create(tenant: workspace.id, actor: actor)

    {:ok, published} =
      defn
      |> Ash.Changeset.for_update(:publish, %{}, actor: actor)
      |> Ash.update(tenant: workspace.id, actor: actor)

    published
  end

  defp enroll(course, learner) do
    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{course_id: course.id, user_id: learner.id})
      |> Ash.create(tenant: course.workspace_id, actor: learner)

    enrollment
  end

  # 学习 run:create → start(与 instantiator 产出的 running 态同形状)
  defp create_running_run(workspace, definition, enrollment, learner, course) do
    WorkflowRun
    |> Ash.Changeset.for_create(
      :create,
      %{
        definition_id: definition.id,
        definition_version: definition.version,
        input_snapshot: %{
          "key" => "enrollment_#{enrollment.id}",
          "enrollment_id" => enrollment.id,
          "user_id" => learner.id,
          "course_id" => course.id,
          "title" => course.title
        }
      },
      tenant: workspace.id,
      authorize?: false
    )
    |> Ash.create!(tenant: workspace.id, authorize?: false)
    |> Ash.Changeset.for_update(:start, %{}, tenant: workspace.id, authorize?: false)
    |> Ash.update!(tenant: workspace.id, authorize?: false)
  end

  defp save_content(workspace, actor, course) do
    Cgc2046.Curriculum.Output
    |> Ash.Changeset.for_create(
      :upsert_content,
      %{
        key: Cgc2046.Curriculum.Output.course_key(course.id),
        kind: :issues,
        data: content_fixture(),
        submitted_by: actor.id
      },
      tenant: workspace.id,
      actor: actor
    )
    |> Ash.create!(tenant: workspace.id, actor: actor)
  end

  defp save_record(workspace, learner, course, item_id) do
    LearningRecord
    |> Ash.Changeset.for_create(
      :upsert_record,
      %{
        course_id: course.id,
        user_id: learner.id,
        issue_id: @issue_id,
        item_id: item_id,
        done: true,
        evidence: "ok",
        recorded_at: DateTime.utc_now()
      },
      tenant: workspace.id,
      actor: learner
    )
    |> Ash.create!(tenant: workspace.id, actor: learner)
  end

  defp fetch_run(run_id, workspace_id) do
    Ash.get!(WorkflowRun, run_id, tenant: workspace_id, authorize?: false)
  end

  test "全部 issue Done → succeeded;部分 Done → 仍 running;无记录 → Todo 全量" do
    admin = Fixtures.platform_admin("lpw-u4")
    workspace = Fixtures.create_workspace(admin)
    published = create_learning_definition(workspace, admin)

    course = EventFixtures.create_course(workspace, admin, %{title: "课程"})
    finisher = Fixtures.register_user("lpw-u4-finisher")
    partial = Fixtures.register_user("lpw-u4-partial")
    fresh = Fixtures.register_user("lpw-u4-fresh")

    enrollment_f = enroll(course, finisher)
    enrollment_p = enroll(course, partial)
    enrollment_x = enroll(course, fresh)

    run_f = create_running_run(workspace, published, enrollment_f, finisher, course)
    run_p = create_running_run(workspace, published, enrollment_p, partial, course)
    run_x = create_running_run(workspace, published, enrollment_x, fresh, course)

    save_content(workspace, admin, course)
    save_record(workspace, finisher, course, "c1")
    save_record(workspace, finisher, course, "c2")
    save_record(workspace, partial, course, "c1")

    assert :ok = perform_job(LearningProgressWorker, %{})

    assert fetch_run(run_f.id, workspace.id).status == :succeeded
    assert fetch_run(run_p.id, workspace.id).status == :running
    assert fetch_run(run_x.id, workspace.id).status == :running
  end

  test "无内容课程(无 Curriculum.Output)→ 不判完成" do
    admin = Fixtures.platform_admin("lpw-u4-nocontent")
    workspace = Fixtures.create_workspace(admin)
    published = create_learning_definition(workspace, admin)

    course = EventFixtures.create_course(workspace, admin, %{title: "无内容课"})
    learner = Fixtures.register_user("lpw-u4-nocontent-learner")
    enrollment = enroll(course, learner)

    run = create_running_run(workspace, published, enrollment, learner, course)

    # 有记录但无内容:分母不可知 → 不判完成
    save_record(workspace, learner, course, "c1")
    save_record(workspace, learner, course, "c2")

    assert :ok = perform_job(LearningProgressWorker, %{})
    assert fetch_run(run.id, workspace.id).status == :running
  end

  test "记录补全后下一轮扫描完成(F3 集成)" do
    admin = Fixtures.platform_admin("lpw-u4-f3")
    workspace = Fixtures.create_workspace(admin)
    published = create_learning_definition(workspace, admin)

    course = EventFixtures.create_course(workspace, admin, %{title: "课程"})
    learner = Fixtures.register_user("lpw-u4-f3-learner")
    enrollment = enroll(course, learner)
    run = create_running_run(workspace, published, enrollment, learner, course)
    save_content(workspace, admin, course)

    # 第一拍:部分 done,保持 running
    save_record(workspace, learner, course, "c1")
    assert :ok = perform_job(LearningProgressWorker, %{})
    assert fetch_run(run.id, workspace.id).status == :running

    # 第二拍:补全 → succeeded(完成由记录变更驱动,至多一个 cron 周期延迟)
    save_record(workspace, learner, course, "c2")
    assert :ok = perform_job(LearningProgressWorker, %{})
    reloaded = fetch_run(run.id, workspace.id)
    assert reloaded.status == :succeeded
    refute is_nil(reloaded.finished_at)
  end
end
