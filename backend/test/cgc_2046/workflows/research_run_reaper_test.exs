defmodule Cgc2046.Workflows.ResearchRunReaperTest do
  @moduledoc """
  E-9 #124 教研 run 回收测试：event.ended 信号 → 停该实体的非终态教研 run。

  测试直接调 handle_signal/1（信号总线异步投递在 POC 已验证，测试不覆盖
  异步路径——同 ResearchInstantiator 纪律）。信号 map 用 atom key :data
  （与 ResearchInstantiator.handle_signal 的解析约定一致）。实例化走
  ResearchInstantiator.launch/4 真实路径，验证 instance key 约定
  （input_snapshot["key"] = "event_\#{id}"）。
  """

  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures

  alias Cgc2046.Workflows.{
    ResearchInstantiator,
    ResearchRunReaper,
    WorkflowDefinition,
    WorkflowRun
  }

  defp create_definition(workspace, actor) do
    WorkflowDefinition
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "教研回收测试-#{System.unique_integer([:positive])}",
        type: :research,
        input_schema: %{"text" => "string"},
        node_def: %{"steps" => [%{"id" => "approval", "type" => "manual"}]},
        approval_timeout: 604_800
      },
      tenant: workspace.id
    )
    |> Ash.create!(tenant: workspace.id, actor: actor)
    |> then(fn defn ->
      defn
      |> Ash.Changeset.for_update(:publish, %{}, tenant: workspace.id, actor: actor)
      |> Ash.update!(tenant: workspace.id, actor: actor)
    end)
  end

  defp launch_research_run(workspace, actor, entity, entity_type) do
    defn = create_definition(workspace, actor)
    key_field = "#{entity_type}_id"

    {:ok, run} =
      ResearchInstantiator.launch(
        workspace.id,
        defn.id,
        %{key_field => entity.id, "title" => entity.title, "research_requirements" => %{}},
        entity_type
      )

    run
  end

  test "event.ended → waiting 教研 run 被 cancel（含 instance key 约定验证）" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin)

    # manual-only 定义 → start_run 直达 waiting（无需 StepHandlerRegistry）
    run = launch_research_run(workspace, admin, event, :event)
    assert run.status == :waiting

    assert :ok = ResearchRunReaper.handle_signal(%{data: %{"event_id" => event.id}})

    reloaded = Ash.get!(WorkflowRun, run.id, authorize?: false)
    assert reloaded.status == :cancelled
    refute is_nil(reloaded.finished_at)
  end

  test "course.ended 同样回收；其他实体的 run 不受影响" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    course = EventFixtures.create_course(workspace, admin)
    other_event = EventFixtures.create_event(workspace, admin)

    course_run = launch_research_run(workspace, admin, course, :course)
    other_run = launch_research_run(workspace, admin, other_event, :event)

    assert :ok = ResearchRunReaper.handle_signal(%{data: %{"course_id" => course.id}})

    assert Ash.get!(WorkflowRun, course_run.id, authorize?: false).status == :cancelled
    assert Ash.get!(WorkflowRun, other_run.id, authorize?: false).status == :waiting
  end

  test "终态 run 不动；重复信号幂等" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin)

    # 手动构造 succeeded run（create → start → complete）
    defn = create_definition(workspace, admin)

    succeeded =
      WorkflowRun
      |> Ash.Changeset.for_create(
        :create,
        %{
          definition_id: defn.id,
          definition_version: defn.version,
          input_snapshot: %{"key" => "event_#{event.id}"}
        },
        tenant: workspace.id,
        authorize?: false
      )
      |> Ash.create!(tenant: workspace.id, authorize?: false)
      |> then(fn run ->
        run
        |> Ash.Changeset.for_update(:start, %{}, tenant: workspace.id, authorize?: false)
        |> Ash.update!(tenant: workspace.id, authorize?: false)
      end)
      |> then(fn run ->
        run
        |> Ash.Changeset.for_update(:complete, %{}, tenant: workspace.id, authorize?: false)
        |> Ash.update!(tenant: workspace.id, authorize?: false)
      end)

    assert succeeded.status == :succeeded

    assert :ok = ResearchRunReaper.handle_signal(%{data: %{"event_id" => event.id}})
    assert :ok = ResearchRunReaper.handle_signal(%{data: %{"event_id" => event.id}})

    assert Ash.get!(WorkflowRun, succeeded.id, authorize?: false).status == :succeeded
  end

  test "无 entity id 的信号与异常输入不崩溃" do
    assert :ok = ResearchRunReaper.handle_signal(%{data: %{}})
    assert :ok = ResearchRunReaper.handle_signal(%{data: %{"event_id" => nil}})
  end
end
