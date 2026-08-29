defmodule Cgc2046.Learning.LearningProgressWorkerTest do
  @moduledoc """
  LearningProgressWorker 完成判定测试(S8 重写:R39/AE10)。

  - 必修 objective 全 ever_mastered(qualifying attempt)→ run succeeded;
    部分掌握 → 保持 running;零 attempt → running
  - run 未绑定 revision(存量 nil 宽限)→ 不判完成
  - attempt 补全后下一轮扫描完成(worker 兜底收敛;submit 工具即时判定
    的覆盖在 learning_loop_tools_test.exs)
  """
  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  use Oban.Testing, repo: Cgc2046.Repo
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Curriculum.CourseRevision
  alias Cgc2046.Learning.{Attempt, LearningProgressWorker}
  alias Cgc2046.Workflows.{WorkflowDefinition, WorkflowRun}

  # 两必修 objective(同 issue),各配单条 rubric
  defp content_fixture do
    %{
      "goals" => ["能写程序"],
      "issues" => [
        %{
          "id" => "py-first-program",
          "kind" => "handwork",
          "title" => "写你的第一个程序",
          "story" => %{"as_a" => "学员", "given" => [], "goal" => "独立写问候程序"},
          "objectives" => [
            %{
              "id" => "obj-run",
              "title" => "能运行问候程序",
              "required" => true,
              "prereq_ids" => [],
              "rubric" => [%{"id" => "r1", "text" => "程序能运行"}]
            },
            %{
              "id" => "obj-explain",
              "title" => "能讲懂代码",
              "required" => true,
              "prereq_ids" => [],
              "rubric" => [%{"id" => "r1", "text" => "能逐行讲清"}]
            }
          ]
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

  # 发布 revision 并绑定为课程当前版本;返回 revision
  defp publish_revision(workspace, course) do
    {:ok, revision} =
      CourseRevision
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
    |> Ash.Changeset.for_update(:bind_current_revision, %{current_revision_id: revision.id},
      tenant: workspace.id
    )
    |> Ash.update!(tenant: workspace.id, authorize?: false)

    revision
  end

  # 学习 run:create → start(与 instantiator 产出的 running 态同形状);
  # revision 绑定经 input_snapshot(ADR-0011 L6——引擎表零域列,v2 无列)
  defp create_running_run(workspace, definition, enrollment, learner, course, revision) do
    WorkflowRun
    |> Ash.Changeset.for_create(
      :create,
      %{
        definition_id: definition.id,
        definition_version: definition.version,
        input_snapshot: %{
          "key" => Cgc2046.Learning.Runs.instance_key(enrollment.id, revision && revision.id),
          "enrollment_id" => enrollment.id,
          "user_id" => learner.id,
          "course_id" => course.id,
          "title" => course.title,
          "course_revision_id" => revision && revision.id
        }
      },
      tenant: workspace.id,
      authorize?: false
    )
    |> Ash.create!(tenant: workspace.id, authorize?: false)
    |> Ash.Changeset.for_update(:start, %{}, tenant: workspace.id, authorize?: false)
    |> Ash.update!(tenant: workspace.id, authorize?: false)
  end

  # qualifying attempt(passed + confidence 0.9 + rubric 精确覆盖且 met)
  defp submit_attempt(workspace, run, revision, objective_id) do
    Attempt
    |> Ash.Changeset.for_create(
      :create,
      %{
        learning_run_id: run.id,
        course_revision_id: revision.id,
        objective_id: objective_id,
        evidence: "实机跑通,输出正确",
        rubric_results: [%{"criterion_id" => "r1", "met" => true}],
        passed: true,
        rationale: "证据可复核,标准达成",
        confidence: 0.9
      },
      tenant: workspace.id,
      authorize?: false
    )
    |> Ash.create!(tenant: workspace.id, authorize?: false)
  end

  defp fetch_run(run_id, workspace_id) do
    Ash.get!(WorkflowRun, run_id, tenant: workspace_id, authorize?: false)
  end

  test "必修全 ever_mastered → succeeded;部分掌握 → 仍 running;零 attempt → running" do
    admin = Fixtures.platform_admin("lpw-s8")
    workspace = Fixtures.create_workspace(admin)
    published = create_learning_definition(workspace, admin)

    course = EventFixtures.create_course(workspace, admin, %{title: "课程"})
    revision = publish_revision(workspace, course)

    finisher = Fixtures.register_user("lpw-s8-finisher")
    partial = Fixtures.register_user("lpw-s8-partial")
    fresh = Fixtures.register_user("lpw-s8-fresh")

    enrollment_f = enroll(course, finisher)
    enrollment_p = enroll(course, partial)
    enrollment_x = enroll(course, fresh)

    run_f = create_running_run(workspace, published, enrollment_f, finisher, course, revision)
    run_p = create_running_run(workspace, published, enrollment_p, partial, course, revision)
    run_x = create_running_run(workspace, published, enrollment_x, fresh, course, revision)

    submit_attempt(workspace, run_f, revision, "obj-run")
    submit_attempt(workspace, run_f, revision, "obj-explain")
    submit_attempt(workspace, run_p, revision, "obj-run")

    assert :ok = perform_job(LearningProgressWorker, %{})

    assert fetch_run(run_f.id, workspace.id).status == :succeeded
    assert fetch_run(run_p.id, workspace.id).status == :running
    assert fetch_run(run_x.id, workspace.id).status == :running
  end

  test "run 未绑定 revision(存量 nil 宽限)→ 不判完成" do
    admin = Fixtures.platform_admin("lpw-s8-norev")
    workspace = Fixtures.create_workspace(admin)
    published = create_learning_definition(workspace, admin)

    course = EventFixtures.create_course(workspace, admin, %{title: "无版本课"})
    learner = Fixtures.register_user("lpw-s8-norev-learner")
    enrollment = enroll(course, learner)

    run = create_running_run(workspace, published, enrollment, learner, course, nil)

    assert :ok = perform_job(LearningProgressWorker, %{})
    assert fetch_run(run.id, workspace.id).status == :running
  end

  test "attempt 补全后下一轮扫描完成(兜底收敛)" do
    admin = Fixtures.platform_admin("lpw-s8-f3")
    workspace = Fixtures.create_workspace(admin)
    published = create_learning_definition(workspace, admin)

    course = EventFixtures.create_course(workspace, admin, %{title: "课程"})
    revision = publish_revision(workspace, course)
    learner = Fixtures.register_user("lpw-s8-f3-learner")
    enrollment = enroll(course, learner)
    run = create_running_run(workspace, published, enrollment, learner, course, revision)

    # 第一拍:部分掌握,保持 running
    submit_attempt(workspace, run, revision, "obj-run")
    assert :ok = perform_job(LearningProgressWorker, %{})
    assert fetch_run(run.id, workspace.id).status == :running

    # 第二拍:补全 → succeeded(完成由 attempt 落账驱动,至多一个 cron 周期延迟)
    submit_attempt(workspace, run, revision, "obj-explain")
    assert :ok = perform_job(LearningProgressWorker, %{})
    reloaded = fetch_run(run.id, workspace.id)
    assert reloaded.status == :succeeded
    refute is_nil(reloaded.finished_at)
  end
end
