defmodule Cgc2046.Learning.AttemptTest do
  @moduledoc """
  Attempt 资源测试(S8,R42/R44/R48):

  - 不可变账本面:仅 create+read 两个 action,无 updated_at;默认值
    (rubric_results [] / agent_meta %{})与 confidence 0..1 约束;
  - 读面(R48):学员本人(run input_snapshot 锚定,JSONB exists 下推)∪
    本工作台 tutor/owner/admin;outsider 与**平台管理员**(非成员)读不到;
  - 写面:仅学员本人(ActorIsAttemptLearner;tutor/他人学员/租户错配均拒)。
  """
  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Curriculum.CourseRevision
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Learning.Attempt
  alias Cgc2046.Workflows.{WorkflowDefinition, WorkflowRun}

  # --- 布景 -----------------------------------------------------------------

  defp learning_ctx(prefix) do
    admin = Fixtures.platform_admin(prefix)
    workspace = Fixtures.create_workspace(admin)
    course = EventFixtures.create_course(workspace, admin, %{title: "课程"})
    learner = Fixtures.register_user("#{prefix}-learner")
    enrollment = enroll(course, learner)
    definition = create_learning_definition(workspace, admin)
    revision = publish_revision(workspace, course)
    run = create_run(workspace, definition, enrollment, learner, course, revision)

    %{
      admin: admin,
      workspace: workspace,
      course: course,
      learner: learner,
      enrollment: enrollment,
      revision: revision,
      run: run
    }
  end

  defp enroll(course, learner) do
    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{course_id: course.id, user_id: learner.id})
      |> Ash.create(tenant: course.workspace_id, actor: learner)

    enrollment
  end

  defp create_learning_definition(workspace, actor) do
    {:ok, defn} =
      WorkflowDefinition
      |> Ash.Changeset.for_create(
        :create,
        %{name: "学习 workflow", type: :learning, input_schema: %{}, node_def: %{"steps" => []}},
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

  defp publish_revision(workspace, course) do
    {:ok, revision} =
      CourseRevision
      |> Ash.Changeset.for_create(
        :create,
        %{
          course_id: course.id,
          number: 1,
          content: %{"goals" => [], "issues" => []},
          published_at: DateTime.utc_now()
        },
        tenant: workspace.id
      )
      |> Ash.create(tenant: workspace.id, authorize?: false)

    revision
  end

  defp create_run(workspace, definition, enrollment, learner, course, revision) do
    WorkflowRun
    |> Ash.Changeset.for_create(
      :create,
      %{
        definition_id: definition.id,
        definition_version: definition.version,
        input_snapshot: %{
          "key" => Cgc2046.Learning.Runs.instance_key(enrollment.id, revision.id),
          "enrollment_id" => enrollment.id,
          "user_id" => learner.id,
          "course_id" => course.id,
          "course_revision_id" => revision.id
        }
      },
      tenant: workspace.id,
      authorize?: false
    )
    |> Ash.create!(tenant: workspace.id, authorize?: false)
  end

  defp attempt_attrs(ctx, overrides) do
    Map.merge(
      %{
        learning_run_id: ctx.run.id,
        course_revision_id: ctx.revision.id,
        objective_id: "obj-run",
        evidence: "实机跑通,输出正确",
        passed: true,
        rationale: "证据可复核,标准达成",
        confidence: 0.9
      },
      overrides
    )
  end

  defp create_attempt(ctx, overrides, opts) do
    tenant = Keyword.get(opts, :tenant, ctx.workspace.id)
    actor = Keyword.get(opts, :actor)
    changeset_opts = [tenant: tenant] ++ if actor, do: [actor: actor], else: [authorize?: false]
    action_opts = [tenant: tenant] ++ if actor, do: [actor: actor], else: [authorize?: false]

    Attempt
    |> Ash.Changeset.for_create(:create, attempt_attrs(ctx, overrides), changeset_opts)
    |> Ash.create(action_opts)
  end

  defp create_attempt!(ctx, overrides \\ %{}) do
    {:ok, attempt} = create_attempt(ctx, overrides, [])
    attempt
  end

  # --- 账本面 ---------------------------------------------------------------

  test "create 落库字段;rubric_results/agent_meta 默认值;只有 created_at(无 updated_at)" do
    ctx = learning_ctx("la-create")

    attempt =
      create_attempt!(ctx, %{
        rubric_results: [%{"criterion_id" => "r1", "met" => true}],
        agent_meta: %{"client" => "test"}
      })

    assert attempt.workspace_id == ctx.workspace.id
    assert attempt.learning_run_id == ctx.run.id
    assert attempt.course_revision_id == ctx.revision.id
    assert attempt.objective_id == "obj-run"
    assert attempt.evidence == "实机跑通,输出正确"
    assert attempt.rubric_results == [%{"criterion_id" => "r1", "met" => true}]
    assert attempt.passed == true
    assert attempt.rationale == "证据可复核,标准达成"
    assert attempt.confidence == 0.9
    assert attempt.agent_meta == %{"client" => "test"}
    assert %DateTime{} = attempt.created_at

    defaulted = create_attempt!(ctx, %{objective_id: "obj-explain"})
    assert defaulted.rubric_results == []
    assert defaulted.agent_meta == %{}
  end

  test "action 面仅 create+read(R44 不可变:无 update/destroy);无 updated_at 属性" do
    names = Attempt |> Ash.Resource.Info.actions() |> Enum.map(& &1.name)

    assert Enum.sort(names) == [:create, :read]
    assert Ash.Resource.Info.attribute(Attempt, :updated_at) == nil
  end

  test "confidence 约束 0..1:越界拒绝,边界放行" do
    ctx = learning_ctx("la-confidence")

    assert {:error, %Ash.Error.Invalid{}} = create_attempt(ctx, %{confidence: -0.1}, [])
    assert {:error, %Ash.Error.Invalid{}} = create_attempt(ctx, %{confidence: 1.1}, [])

    assert {:ok, _} = create_attempt(ctx, %{confidence: 0.0}, [])
    assert {:ok, _} = create_attempt(ctx, %{confidence: 1.0, objective_id: "obj-x"}, [])
  end

  # --- 读面(R48) -------------------------------------------------------------

  test "读面:学员本人 ∪ tutor/owner/admin 放行;outsider / 匿名 / 平台管理员(非成员)读不到" do
    ctx = learning_ctx("la-read")
    attempt = create_attempt!(ctx)
    attempt_id = attempt.id

    tutor = Fixtures.register_user("la-read-tutor")
    Fixtures.add_member(ctx.workspace, tutor, [:tutor])
    outsider = Fixtures.register_user("la-read-outsider")
    platform_admin = Fixtures.platform_admin("la-read-platform")

    # 学员本人(exists(learning_run, input_snapshot["user_id"]) JSONB 下推)
    assert [%{id: ^attempt_id}] =
             Ash.read!(Attempt, actor: ctx.learner, tenant: ctx.workspace.id)

    # 本工作台 tutor / owner
    assert [%{id: ^attempt_id}] =
             Ash.read!(Attempt, actor: tutor, tenant: ctx.workspace.id)

    assert [%{id: ^attempt_id}] =
             Ash.read!(Attempt, actor: ctx.admin, tenant: ctx.workspace.id)

    # outsider / 匿名 → 空(filter 排除,不报错)
    assert [] = Ash.read!(Attempt, actor: outsider, tenant: ctx.workspace.id)
    assert [] = Ash.read!(Attempt, tenant: ctx.workspace.id)

    # R48:平台管理员(非本工作台成员)刻意无证据读面
    assert platform_admin.is_platform_admin == true
    assert [] = Ash.read!(Attempt, actor: platform_admin, tenant: ctx.workspace.id)
  end

  # --- 写面(仅学员本人) --------------------------------------------------------

  test "写面:学员本人放行;tutor / 他人学员 / 租户错配均 Forbidden" do
    ctx = learning_ctx("la-write")

    tutor = Fixtures.register_user("la-write-tutor")
    Fixtures.add_member(ctx.workspace, tutor, [:tutor])
    other_learner = Fixtures.register_user("la-write-other")

    assert {:ok, _} = create_attempt(ctx, %{}, actor: ctx.learner)

    assert {:error, %Ash.Error.Forbidden{}} = create_attempt(ctx, %{}, actor: tutor)
    assert {:error, %Ash.Error.Forbidden{}} = create_attempt(ctx, %{}, actor: other_learner)

    # 租户错配:run 不属于该租户 → fail-closed
    other_admin = Fixtures.platform_admin("la-write-ws2")
    other_workspace = Fixtures.create_workspace(other_admin)

    assert {:error, %Ash.Error.Forbidden{}} =
             create_attempt(ctx, %{}, actor: ctx.learner, tenant: other_workspace.id)
  end
end
