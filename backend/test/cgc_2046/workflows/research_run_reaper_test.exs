defmodule Cgc2046.Workflows.ResearchRunReaperTest do
  @moduledoc """
  E-9 #124 教研 run 回收测试：event.ended 信号 → 停该实体的非终态教研 run。

  测试直接调 SignalSubscriber.deliver/2（与生产 forwarder 同码；信号总线异步
  投递在 POC 已验证，测试不覆盖异步路径）。实例化走
  ResearchInstantiator.launch/4 真实路径，验证 instance key 约定
  （input_snapshot["key"] = "event_\#{id}"）。
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures

  alias Cgc2046.Workflows.{
    ResearchInstantiator,
    ResearchRunReaper,
    SignalIdempotency,
    SignalSubscriber,
    WorkflowDefinition,
    WorkflowRun
  }

  defp create_definition(workspace, actor, type \\ :research) do
    WorkflowDefinition
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "回收测试-#{type}-#{System.unique_integer([:positive])}",
        type: type,
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

  defp claim_rows, do: SignalIdempotency |> Ash.read!(authorize?: false) |> length()

  # 生产者 payload 形状（SignalEmitter 注入 idempotency_key = "<type>:<record_id>"）
  defp ended_signal(entity, type \\ "event.ended") do
    id_key = if type == "event.ended", do: "event_id", else: "course_id"

    SignalSubscriber.deliver(ResearchRunReaper, %{
      type: type,
      data: %{id_key => entity.id, "idempotency_key" => type <> ":" <> entity.id}
    })
  end

  test "event.ended → waiting 教研 run 被 cancel（含 instance key 约定验证）" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin)

    # manual-only 定义 → start_run 直达 waiting（无需 StepHandlerRegistry）
    run = launch_research_run(workspace, admin, event, :event)
    assert run.status == :waiting

    assert :ok = ended_signal(event)

    reloaded = Ash.get!(WorkflowRun, run.id, authorize?: false)
    assert reloaded.status == :cancelled
    refute is_nil(reloaded.finished_at)
    # 全部成功 → claim 登记一行
    assert claim_rows() == 1
  end

  test "course.ended 同样回收；其他实体的 run 不受影响" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    course = EventFixtures.create_course(workspace, admin)
    other_event = EventFixtures.create_event(workspace, admin)

    course_run = launch_research_run(workspace, admin, course, :course)
    other_run = launch_research_run(workspace, admin, other_event, :event)

    assert :ok = ended_signal(course, "course.ended")

    assert Ash.get!(WorkflowRun, course_run.id, authorize?: false).status == :cancelled
    assert Ash.get!(WorkflowRun, other_run.id, authorize?: false).status == :waiting
  end

  test "终态 run 不动；重复信号幂等且 claim 只登记一次" do
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

    assert :ok = ended_signal(event)
    assert :ok = ended_signal(event)

    assert Ash.get!(WorkflowRun, succeeded.id, authorize?: false).status == :succeeded
    # 唯一索引：两次投递只登记一行
    assert claim_rows() == 1
  end

  test "无可回收 run 时仍登记 claim（0 次取消 = 全部成功语义，阻断后续重复投递）" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin)

    assert :ok = ended_signal(event)
    assert :ok = ended_signal(event)

    assert claim_rows() == 1
  end

  test "非 research run 同 instance key 不受影响（BLOCKING 5 负向）" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin)

    learning_defn = create_definition(workspace, admin, :learning)

    learning_run =
      WorkflowRun
      |> Ash.Changeset.for_create(
        :create,
        %{
          definition_id: learning_defn.id,
          definition_version: learning_defn.version,
          input_snapshot: %{"key" => "event_#{event.id}"}
        },
        tenant: workspace.id,
        authorize?: false
      )
      |> Ash.create!(tenant: workspace.id, authorize?: false)

    assert learning_run.status == :pending

    assert :ok = ended_signal(event)

    assert Ash.get!(WorkflowRun, learning_run.id, authorize?: false).status == :pending
  end

  test "无 entity id 的信号不崩溃；缺幂等键的信号被丢弃" do
    # 有消费键、无 entity id → catch-all 分支跳过，不崩溃
    assert :ok =
             SignalSubscriber.deliver(ResearchRunReaper, %{
               type: "event.ended",
               data: %{"event_id" => nil, "idempotency_key" => "event.ended:no-entity"}
             })

    # 缺 idempotency_key = 生产者契约违约 → 丢弃（不执行副作用、不 crash）
    assert {:error, :missing_idempotency_key} =
             SignalSubscriber.deliver(ResearchRunReaper, %{
               type: "event.ended",
               data: %{}
             })
  end
end
