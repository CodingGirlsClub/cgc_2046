defmodule Cgc2046.Courses.U6CoursePipelineTest do
  @moduledoc """
  U6(切片 H, #180/R14):research_enabled 删列与消费方收紧。

  - course launch 恒实例化教研 run(原 false 跳过分支删除后的行为)
  - open 课程无 published 定义 → 规则④命中(AE4);有定义不命中;
    Event research_enabled=false 仍合法不命中
  - Readiness course 教研项无条件检查(不看开关)
  """

  use Cgc2046.DataCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Courses.Course
  alias Cgc2046.Offering.Readiness
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Workers.ReconciliationScanWorker

  alias Cgc2046.Workflows.{
    ResearchInstantiator,
    SignalSubscriber,
    WorkflowDefinition,
    WorkflowRun
  }

  require Ash.Query

  defp create_research_definition(workspace, actor) do
    {:ok, defn} =
      WorkflowDefinition
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "教研 #{Ecto.UUID.generate()}",
          type: :research,
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
      SignalSubscriber.deliver(ResearchInstantiator, %{
        type: "course.launched",
        data: %{"course_id" => course.id, "title" => course.title}
      })
  end

  defp research_runs(workspace_id, course) do
    WorkflowRun
    |> Ash.Query.filter(input_snapshot["key"] == ^"course_#{course.id}")
    |> Ash.read!(authorize?: false, tenant: workspace_id)
  end

  defp findings(rule) do
    Cgc2046.Reconciliation.Finding
    |> Ash.Query.filter(rule == ^rule)
    |> Ash.read!(authorize?: false)
  end

  describe "course launch 恒实例化(U6)" do
    test "published 定义存在 → 教研 run 创建(无 research_enabled 概念)" do
      admin = Fixtures.platform_admin("u6-launch")
      workspace = Fixtures.create_workspace(admin)
      create_research_definition(workspace, admin)
      course = EventFixtures.create_course(workspace, admin, %{title: "课程"})

      launch_signal(course)

      # 异步路径:轮询等待实例化(常驻订阅方可能抢先,幂等殊途同归)
      wait_until(fn -> length(research_runs(workspace.id, course)) == 1 end)

      [run] = research_runs(workspace.id, course)
      assert run.status in [:waiting, :running]
      assert course.workflow_run_id == nil || course.workflow_run_id == run.id
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

    test "工作台有 published 定义 → 不命中" do
      admin = Fixtures.platform_admin("u6-r4-def")
      workspace = Fixtures.create_workspace(admin)
      create_research_definition(workspace, admin)
      EventFixtures.create_course(workspace, admin, %{title: "有定义课程"})

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:open_entity_without_research_definition)
    end

    test "Event research_enabled=false 仍合法不命中(event-only 退出通道)" do
      admin = Fixtures.platform_admin("u6-r4-event")
      workspace = Fixtures.create_workspace(admin)
      EventFixtures.create_event(workspace, admin, %{research_enabled: false})

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:open_entity_without_research_definition)
    end
  end

  describe "Readiness course 教研项无条件(U6)" do
    test "course 无 published 定义 → research_definition 项 not ok(不看开关)" do
      admin = Fixtures.platform_admin("u6-ready")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{title: "课程"})

      result = Readiness.evaluate(course)

      research_item = Enum.find(result.items, &(&1.key == "research_definition"))
      refute research_item.ok
      refute result.ready

      # 有定义 → ok(无条件检查的正向)
      create_research_definition(workspace, admin)

      result2 = Readiness.evaluate(course)
      research_item2 = Enum.find(result2.items, &(&1.key == "research_definition"))
      assert research_item2.ok
    end
  end

  defp wait_until(fun, attempts \\ 40)
  defp wait_until(fun, 0), do: fun.()

  defp wait_until(fun, attempts) do
    if fun.(), do: :ok
    Process.sleep(25)
    wait_until(fun, attempts - 1)
  end
end
