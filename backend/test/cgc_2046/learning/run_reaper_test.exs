defmodule Cgc2046.Learning.RunReaperTest do
  @moduledoc """
  学习 run 回收（offering 取消级联）测试：

  - event/course.ended + 实体 cancelled → 该 offering 非终态 learning run 被 cancel
  - closed（正常结束）不动——学员可继续学习已有内容
  - 终态 run 不动；重复信号幂等（claim 只登记一次）
  - 非 learning 型 run 不受影响（与 Curriculum.Reaper 互不越界）
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Learning.RunReaper

  alias Cgc2046.Workflows.{
    SignalIdempotency,
    SignalSubscriber,
    Step,
    WorkflowDefinition,
    WorkflowRun
  }

  defp create_learning_definition(workspace, actor) do
    definition =
      WorkflowDefinition
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "学习回收测试-#{System.unique_integer([:positive])}",
          type: :learning,
          input_schema: %{},
          node_def: %{"steps" => [%{"id" => "outline", "type" => "manual"}]}
        },
        tenant: workspace.id,
        actor: actor
      )
      |> Ash.create!(tenant: workspace.id, actor: actor)
      |> then(fn defn ->
        defn
        |> Ash.Changeset.for_update(:publish, %{}, actor: actor)
        |> Ash.update!(tenant: workspace.id, actor: actor)
      end)

    Step
    |> Ash.Changeset.for_create(
      :create,
      %{definition_id: definition.id, step_key: "outline", title: "outline 标题", type: :manual},
      tenant: workspace.id,
      actor: actor
    )
    |> Ash.create!(tenant: workspace.id, actor: actor)

    definition
  end

  defp create_running_learning_run(workspace, definition, enrollment) do
    WorkflowRun
    |> Ash.Changeset.for_create(
      :create,
      %{
        definition_id: definition.id,
        definition_version: definition.version,
        input_snapshot: %{"enrollment_id" => enrollment.id, "user_id" => enrollment.user_id}
      },
      tenant: workspace.id,
      authorize?: false
    )
    |> Ash.create!(tenant: workspace.id, authorize?: false)
    |> then(&Ash.Changeset.for_update(&1, :start, %{}, authorize?: false))
    |> Ash.update!(tenant: workspace.id, authorize?: false)
  end

  defp create_course_enrollment(workspace, course, learner) do
    Enrollment
    |> Ash.Changeset.for_create(
      :create_enrollment,
      %{course_id: course.id, user_id: learner.id},
      tenant: workspace.id,
      actor: learner
    )
    |> Ash.create!(tenant: workspace.id, actor: learner)
  end

  defp create_event_enrollment(workspace, event, learner) do
    Enrollment
    |> Ash.Changeset.for_create(
      :create_enrollment,
      %{event_id: event.id, user_id: learner.id},
      tenant: workspace.id,
      actor: learner
    )
    |> Ash.create!(tenant: workspace.id, actor: learner)
  end

  defp cancel_offering!(offering, workspace, actor) do
    offering
    |> Ash.Changeset.for_update(:cancel, %{}, tenant: workspace.id, actor: actor)
    |> Ash.update!(tenant: workspace.id, actor: actor)
  end

  defp claim_rows, do: SignalIdempotency |> Ash.read!(authorize?: false) |> length()

  # 生产者 payload 形状（SignalEmitter 注入 idempotency_key = "<type>:<record_id>"）
  defp ended_signal(entity, type) do
    id_key = if type == "event.ended", do: "event_id", else: "course_id"

    SignalSubscriber.deliver(RunReaper, %{
      type: type,
      data: %{id_key => entity.id, "idempotency_key" => type <> ":" <> entity.id}
    })
  end

  test "event.ended + 已取消 event → 旗下 learning run 被 cancel" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    learner = Fixtures.register_user("reaper-learner")
    event = EventFixtures.create_event(workspace, admin)
    enrollment = create_event_enrollment(workspace, event, learner)
    definition = create_learning_definition(workspace, admin)
    run = create_running_learning_run(workspace, definition, enrollment)
    assert run.status == :running

    cancel_offering!(event, workspace, admin)

    assert :ok = ended_signal(event, "event.ended")

    reloaded = Ash.get!(WorkflowRun, run.id, authorize?: false)
    assert reloaded.status == :cancelled
    refute is_nil(reloaded.finished_at)
    assert claim_rows() == 1
  end

  test "course.ended + 已取消 course → 旗下 learning run 被 cancel" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    learner = Fixtures.register_user("reaper-course-learner")
    course = EventFixtures.create_course(workspace, admin)
    enrollment = create_course_enrollment(workspace, course, learner)
    definition = create_learning_definition(workspace, admin)
    run = create_running_learning_run(workspace, definition, enrollment)

    cancel_offering!(course, workspace, admin)

    assert :ok = ended_signal(course, "course.ended")

    reloaded = Ash.get!(WorkflowRun, run.id, authorize?: false)
    assert reloaded.status == :cancelled
    refute is_nil(reloaded.finished_at)
  end

  test "closed（正常结束）不回收：run 保持原状态" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    learner = Fixtures.register_user("reaper-closed-learner")
    event = EventFixtures.create_event(workspace, admin)
    enrollment = create_event_enrollment(workspace, event, learner)
    definition = create_learning_definition(workspace, admin)
    run = create_running_learning_run(workspace, definition, enrollment)

    event
    |> Ash.Changeset.for_update(:close, %{}, tenant: workspace.id, actor: admin)
    |> Ash.update!(tenant: workspace.id, actor: admin)

    assert :ok = ended_signal(event, "event.ended")

    reloaded = Ash.get!(WorkflowRun, run.id, authorize?: false)
    assert reloaded.status == :running
  end

  test "终态 run 不动；重复信号幂等且 claim 只登记一次" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    learner = Fixtures.register_user("reaper-idem-learner")
    event = EventFixtures.create_event(workspace, admin)
    enrollment = create_event_enrollment(workspace, event, learner)
    definition = create_learning_definition(workspace, admin)

    succeeded_run =
      create_running_learning_run(workspace, definition, enrollment)
      |> then(
        &(Ash.Changeset.for_update(&1, :complete, %{facts: %{"outline" => %{"ok" => true}}},
            authorize?: false
          )
          |> Ash.update!(tenant: workspace.id, authorize?: false))
      )

    running_run = create_running_learning_run(workspace, definition, enrollment)

    cancel_offering!(event, workspace, admin)

    before = claim_rows()
    assert :ok = ended_signal(event, "event.ended")
    assert :ok = ended_signal(event, "event.ended")

    assert Ash.get!(WorkflowRun, succeeded_run.id, authorize?: false).status == :succeeded
    assert Ash.get!(WorkflowRun, running_run.id, authorize?: false).status == :cancelled
    assert claim_rows() == before + 1
  end

  test "非 learning 型 run 不受影响（与 Curriculum.Reaper 互不越界）" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    learner = Fixtures.register_user("reaper-negative-learner")
    event = EventFixtures.create_event(workspace, admin)
    enrollment = create_event_enrollment(workspace, event, learner)

    curriculum_definition =
      WorkflowDefinition
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "教研回收负向-#{System.unique_integer([:positive])}",
          type: :curriculum,
          input_schema: %{},
          node_def: %{"steps" => [%{"id" => "approval", "type" => "manual"}]}
        },
        tenant: workspace.id,
        actor: admin
      )
      |> Ash.create!(tenant: workspace.id, actor: admin)
      |> then(fn defn ->
        defn
        |> Ash.Changeset.for_update(:publish, %{}, actor: admin)
        |> Ash.update!(tenant: workspace.id, actor: admin)
      end)

    # 同学员锚下的 curriculum 型 run（学习回收不得触碰）
    curriculum_run =
      WorkflowRun
      |> Ash.Changeset.for_create(
        :create,
        %{
          definition_id: curriculum_definition.id,
          definition_version: curriculum_definition.version,
          input_snapshot: %{"enrollment_id" => enrollment.id, "user_id" => learner.id}
        },
        tenant: workspace.id,
        authorize?: false
      )
      |> Ash.create!(tenant: workspace.id, authorize?: false)
      |> then(&Ash.Changeset.for_update(&1, :start, %{}, authorize?: false))
      |> Ash.update!(tenant: workspace.id, authorize?: false)

    cancel_offering!(event, workspace, admin)

    assert :ok = ended_signal(event, "event.ended")

    assert Ash.get!(WorkflowRun, curriculum_run.id, authorize?: false).status == :running
  end

  test "无 entity id 的信号不崩溃" do
    assert :ok =
             SignalSubscriber.deliver(RunReaper, %{
               type: "event.ended",
               data: %{"idempotency_key" => "event.ended:#{Ecto.UUID.generate()}"}
             })
  end
end
