defmodule Cgc2046.Courses.U6CoursePipelineTest do
  @moduledoc """
  U6(切片 H, #180/R14):curriculum_enabled 删列与消费方收紧。

  - course.launched 不再实例化教研 run(S6 event-only——课程教研由
    course_preparation prep run 承担,Instantiator 订阅收窄)
  - open 课程无 published course_preparation 定义 → 规则④命中(AE4);
    :course_preparation 定义不命中、仅 :curriculum 定义仍命中(S6 类型分家);
    Event curriculum_enabled=false 仍合法不命中(:curriculum 定义)
  - Readiness course 教研项无条件检查(不看开关)
  """

  use Cgc2046.DataCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Offering.Readiness
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Reconciliation.ReconciliationScanWorker

  alias Cgc2046.Curriculum.Instantiator

  alias Cgc2046.Workflows.{
    SignalSubscriber,
    WorkflowDefinition,
    WorkflowRun
  }

  require Ash.Query

  defp create_curriculum_definition(workspace, actor, type \\ :curriculum) do
    {:ok, defn} =
      WorkflowDefinition
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "教研 #{Ecto.UUID.generate()}",
          type: type,
          input_schema: %{},
          node_def: %{"steps" => [%{"id" => "produce_issue_deck", "type" => "manual"}]}
        },
        tenant: workspace.id,
        actor: actor
      )
      |> Ash.create(tenant: workspace.id, actor: actor)

    defn
    |> Ash.Changeset.for_update(:publish, %{}, actor: actor)
    |> Ash.update!(tenant: workspace.id, actor: actor)
  end

  defp launch_signal(course) do
    :ok =
      SignalSubscriber.deliver(Instantiator, %{
        type: "course.launched",
        data: %{"course_id" => course.id, "title" => course.title}
      })
  end

  defp curriculum_runs(workspace_id, course) do
    WorkflowRun
    |> Ash.Query.filter(input_snapshot["key"] == ^"course_#{course.id}")
    |> Ash.read!(authorize?: false, tenant: workspace_id)
  end

  defp findings(rule) do
    Cgc2046.Reconciliation.Finding
    |> Ash.Query.filter(rule == ^rule)
    |> Ash.read!(authorize?: false)
  end

  describe "course.launched 不再实例化(S6 event-only)" do
    test "信号投递后不创建教研 run(课程教研走 course_preparation prep run)" do
      admin = Fixtures.platform_admin("u6-launch")
      workspace = Fixtures.create_workspace(admin)
      create_curriculum_definition(workspace, admin)
      course = EventFixtures.create_course(workspace, admin, %{title: "课程"})

      # Instantiator patterns 已去 course.launched:deliver 落 fallback(警告
      # 日志),不再为 course key 实例化教研 run
      assert :ok = launch_signal(course)

      assert [] = curriculum_runs(workspace.id, course)
    end
  end

  describe "规则④ course 无条件 / Event 保留过滤(U6, AE4)" do
    test "open 课程无 published 定义 → 命中(真孤儿)" do
      admin = Fixtures.platform_admin("u6-r4")
      workspace = Fixtures.create_workspace(admin)
      EventFixtures.create_course(workspace, admin, %{title: "孤儿课程"})

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert [finding] = findings(:open_entity_without_research_definition)
      assert finding.entity_type == :course
      assert finding.detail["title"] == "孤儿课程"
    end

    test "工作台有 published :course_preparation 定义 → 不命中(S6 Course 侧口径)" do
      admin = Fixtures.platform_admin("u6-r4-def")
      workspace = Fixtures.create_workspace(admin)
      create_curriculum_definition(workspace, admin, :course_preparation)
      EventFixtures.create_course(workspace, admin, %{title: "有定义课程"})

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert [] = findings(:open_entity_without_research_definition)
    end

    test "仅有 :curriculum 定义 → course 仍命中(S6 定义类型分家),Event 不受影响" do
      admin = Fixtures.platform_admin("u6-r4-split")
      workspace = Fixtures.create_workspace(admin)

      # :curriculum 定义只豁免 Event 侧;course 侧孤儿判定认 :course_preparation
      create_curriculum_definition(workspace, admin, :curriculum)
      course = EventFixtures.create_course(workspace, admin, %{title: "仅课程定义"})
      EventFixtures.create_event(workspace, admin, %{curriculum_enabled: true})

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      [finding] = findings(:open_entity_without_research_definition)
      assert finding.entity_type == :course
      assert finding.entity_id == course.id
    end

    test "Event curriculum_enabled=false 仍合法不命中(event-only 退出通道)" do
      admin = Fixtures.platform_admin("u6-r4-event")
      workspace = Fixtures.create_workspace(admin)
      EventFixtures.create_event(workspace, admin, %{curriculum_enabled: false})

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:open_entity_without_research_definition)
    end
  end

  describe "Readiness course 教研项无条件(U6)" do
    test "course 无 published 定义 → curriculum_definition 项 not ok(不看开关)" do
      admin = Fixtures.platform_admin("u6-ready")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{title: "课程"})

      result = Readiness.evaluate(course)

      curriculum_item = Enum.find(result.items, &(&1.key == "curriculum_definition"))
      refute curriculum_item.ok
      refute result.ready

      # 有定义 → ok(无条件检查的正向)。S5 起 course 教研项查
      # :course_preparation 定义(prep run 实例化源),event 仍 :curriculum
      create_curriculum_definition(workspace, admin, :course_preparation)

      result2 = Readiness.evaluate(course)
      curriculum_item2 = Enum.find(result2.items, &(&1.key == "curriculum_definition"))
      assert curriculum_item2.ok
    end
  end
end
