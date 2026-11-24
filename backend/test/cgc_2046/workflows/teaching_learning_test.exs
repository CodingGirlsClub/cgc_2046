defmodule Cgc2046.Workflows.TeachingLearningTest do
  @moduledoc """
  #39 教研 workflow 实例化验收测试（阶段 6）。

  覆盖：

  1. 教研定义复用多实例：一个 curriculum WorkflowDefinition 实例化多个 Event，
     各自独立 WorkflowRun，facts 不串
  2. Event launch 发信号：launch action → status=open + event.launched 信号已发
  3. 幂等实例化：同一 Event 重复 launch → 同一 run
  """

  use Cgc2046Web.ConnCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Event
  alias Cgc2046.Workflows.SignalPublishWorker
  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.WorkflowRun
  alias Cgc2046.Curriculum.Instantiator
  alias Cgc2046.Workflows.SignalSubscriber

  defp create_definition(workspace, actor, attrs) do
    defaults = %{
      name: "教研 workflow（测试布景）",
      type: :curriculum,
      input_schema: %{"text" => "string"},
      node_def: %{steps: ["outline_design", "content_review"]},
      approval_timeout: 604_800
    }

    WorkflowDefinition
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs),
      tenant: workspace.id,
      actor: actor
    )
    |> Ash.create(tenant: workspace.id, actor: actor)
  end

  defp publish_definition(defn, workspace, actor) do
    defn
    |> Ash.Changeset.for_update(:publish, %{}, actor: actor)
    |> Ash.update(tenant: workspace.id, actor: actor)
  end

  defp create_event(workspace, actor, attrs \\ %{}) do
    defaults = %{title: "教研活动", curriculum_requirements: %{"audience" => "kids"}}

    Event
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs),
      tenant: workspace.id,
      actor: actor
    )
    |> Ash.create(tenant: workspace.id, actor: actor)
  end

  # 布置而非被测对象：直调 launch/4 的用例要求实体已 launch（open）——
  # launch 动作会触发异步信号订阅，测试不走该路径，直接写库置位
  # （EventsFixtures.force_open 同款）。
  defp force_open_event(%Event{} = event) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE events SET status = 'open' WHERE id = $1",
        [Ecto.UUID.dump!(event.id)]
      )

    Ash.get!(Event, event.id, authorize?: false)
  end

  # 生产侧信号经 SignalPublishWorker 事务内 outbox 入队（plan 2026-08-14-003 Q6）；
  # manual 测试模式下同步执行该 job，驱动 worker → 真实总线投递全链路。
  # 锚定 event_id——套件内并发类测试真实提交的残留 job 不影响匹配。
  defp perform_enqueued_signal(signal_type, event_id) do
    [job] =
      [worker: SignalPublishWorker]
      |> all_enqueued()
      |> Enum.filter(
        &(&1.args["signal_type"] == signal_type &&
            get_in(&1.args, ["data", "event_id"]) == event_id)
      )

    perform_job(SignalPublishWorker, job.args)
  end

  # 教研定义：纯 manual 门控
  defp curriculum_node_def do
    %{
      "steps" => [
        %{"id" => "approval", "type" => "manual"}
      ]
    }
  end

  describe "教研定义复用多实例（#39 验收）" do
    test "一个 curriculum 定义实例化多个 Event，各自独立 run，facts 不串" do
      admin = Fixtures.platform_admin("tl")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: curriculum_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)

      event_1 = force_open_event(create_event(workspace, admin, %{title: "活动一"}) |> elem(1))
      event_2 = force_open_event(create_event(workspace, admin, %{title: "活动二"}) |> elem(1))

      # 各自实例化 → 独立 run，均 waiting（等待人工门控）
      assert {:ok, run_1} =
               Instantiator.launch(
                 workspace.id,
                 published.id,
                 %{
                   "event_id" => event_1.id,
                   "title" => event_1.title,
                   "research_requirements" => event_1.curriculum_requirements,
                   "text" => "hi"
                 }
               )

      assert {:ok, run_2} =
               Instantiator.launch(
                 workspace.id,
                 published.id,
                 %{
                   "event_id" => event_2.id,
                   "title" => event_2.title,
                   "research_requirements" => event_2.curriculum_requirements,
                   "text" => "hi"
                 }
               )

      assert run_1.id != run_2.id
      assert run_1.status == :waiting
      assert run_2.status == :waiting
      assert run_1.input_snapshot["key"] == "event_#{event_1.id}"
      assert run_2.input_snapshot["key"] == "event_#{event_2.id}"

      # 写入各自独立的 MCP facts，再分别放行 → 各自 succeeded，facts 不串
      {:ok, run_1} =
        run_1
        |> Ash.Changeset.for_update(
          :update_facts_for_mcp,
          %{facts: %{"approval" => %{"event" => "one"}}},
          actor: admin
        )
        |> Ash.update(tenant: workspace.id, actor: admin)

      {:ok, run_2} =
        run_2
        |> Ash.Changeset.for_update(
          :update_facts_for_mcp,
          %{facts: %{"approval" => %{"event" => "two"}}},
          actor: admin
        )
        |> Ash.update(tenant: workspace.id, actor: admin)

      {:ok, done_1} =
        run_1
        |> Ash.Changeset.for_update(
          :resume_signal,
          %{signal_type: "workflow.approval", payload: %{approved_by: "u1"}},
          actor: admin
        )
        |> Ash.update(tenant: workspace.id, actor: admin)

      {:ok, done_2} =
        run_2
        |> Ash.Changeset.for_update(
          :resume_signal,
          %{signal_type: "workflow.approval", payload: %{approved_by: "u1"}},
          actor: admin
        )
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert done_1.status == :succeeded
      assert done_2.status == :succeeded
      assert done_1.facts["approval"] == %{"event" => "one"}
      assert done_2.facts["approval"] == %{"event" => "two"}
      assert done_1.facts["key"] == nil
      assert done_2.facts["key"] == nil
    end
  end

  describe "Event launch 发信号（#39 验收）" do
    test "launch action → status=open + event.launched 信号已发" do
      admin = Fixtures.platform_admin("tl")
      workspace = Fixtures.create_workspace(admin)
      {:ok, event} = create_event(workspace, admin)

      # 订阅 event.launched 信号（验证 launch action 发布）
      parent = self()

      assert {:ok, _sub_id, _monitor_ref, _forwarder_pid} =
               Cgc2046.Workflows.JidoAdapter.subscribe("event.launched", fn _type, data ->
                 send(parent, {:launched, data})
               end)

      {:ok, launched} =
        event
        |> Ash.Changeset.for_update(:launch, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert launched.status == :open

      # 事务内 outbox（plan 2026-08-14-003 Q6）：job 与 open 终态同事务入队；
      # 同步执行 job 驱动 worker → 真实总线投递全链路
      assert_enqueued(
        worker: SignalPublishWorker,
        args: %{
          "signal_type" => "event.launched",
          "data" => %{"event_id" => event.id, "title" => event.title}
        }
      )

      assert :ok = perform_enqueued_signal("event.launched", event.id)

      assert_receive {:launched, %{"event_id" => event_id, "title" => title}}, 1_000
      assert event_id == event.id
      assert title == event.title
    end

    test "非 draft 状态不可 launch" do
      admin = Fixtures.platform_admin("tl")
      workspace = Fixtures.create_workspace(admin)
      {:ok, event} = create_event(workspace, admin)

      {:ok, launched} =
        event
        |> Ash.Changeset.for_update(:launch, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert launched.status == :open

      assert {:error, %Ash.Error.Invalid{}} =
               launched
               |> Ash.Changeset.for_update(:launch, %{}, actor: admin)
               |> Ash.update(tenant: workspace.id, actor: admin)
    end

    test "launch 信号在事务提交后发布（#1 TOCTOU 回归）" do
      admin = Fixtures.platform_admin("tl")
      workspace = Fixtures.create_workspace(admin)
      {:ok, event} = create_event(workspace, admin)

      parent = self()

      assert {:ok, _sub_id, _monitor_ref, _forwarder_pid} =
               Cgc2046.Workflows.JidoAdapter.subscribe("event.launched", fn _type, data ->
                 send(parent, {:launched, data})
               end)

      # 构建 changeset——buggy 代码在 change 回调（for_update 阶段，事务开始前）
      # 发布信号，订阅方读到未提交的 draft 状态，ensure_launched 守卫静默丢弃
      # 实例化（#1 TOCTOU）。修复后（SignalEmitter 事务内 outbox）：for_update
      # 阶段既不得发布也不得入队。
      changeset = Ash.Changeset.for_update(event, :launch, %{}, actor: admin)

      refute_enqueued(
        worker: SignalPublishWorker,
        args: %{"signal_type" => "event.launched", "data" => %{"event_id" => event.id}}
      )

      # 2s 窗口：buggy 代码在 for_update 发布 → 订阅方转发 → refute 失败（红）
      refute_receive {:launched, _}, 2_000

      {:ok, launched} = Ash.update(changeset, tenant: workspace.id, actor: admin)
      assert launched.status == :open

      # 提交后 job 已入队；执行后信号到达（订阅方此时读到已提交的 open 状态，
      # 实例化不被丢弃）
      assert_enqueued(
        worker: SignalPublishWorker,
        args: %{"signal_type" => "event.launched", "data" => %{"event_id" => event.id}}
      )

      assert :ok = perform_enqueued_signal("event.launched", event.id)

      assert_receive {:launched, %{"event_id" => event_id, "title" => title}}, 1_000
      assert event_id == event.id
      assert title == event.title
    end
  end

  describe "幂等实例化（#39 验收）" do
    test "同一 Event 重复 launch → 返回同一 run（不重复创建）" do
      admin = Fixtures.platform_admin("tl")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: curriculum_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      event = force_open_event(create_event(workspace, admin) |> elem(1))

      input = %{
        "event_id" => event.id,
        "title" => event.title,
        "research_requirements" => event.curriculum_requirements,
        "text" => "hi"
      }

      assert {:ok, run_1} = Instantiator.launch(workspace.id, published.id, input)
      assert {:ok, run_2} = Instantiator.launch(workspace.id, published.id, input)

      assert run_1.id == run_2.id

      # 终态后可重新实例化（新 run）
      {:ok, done} =
        run_1
        |> Ash.Changeset.for_update(
          :resume_signal,
          %{signal_type: "workflow.approval", payload: %{approved_by: "u1"}},
          actor: admin
        )
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert done.status == :succeeded

      assert {:ok, run_3} = Instantiator.launch(workspace.id, published.id, input)
      assert run_3.id != run_1.id
    end
  end

  describe "异步信号状态守卫（孤儿 run 防护）" do
    test "draft event 信号不创建 run" do
      admin = Fixtures.platform_admin("tl")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: curriculum_node_def()})
      {:ok, _published} = publish_definition(defn, workspace, admin)
      {:ok, event} = create_event(workspace, admin)

      # 白盒驱动异步路径（apply 私有函数；测试进程在沙箱内可查 DB，而真实订阅
      # 进程不在沙箱——异步投递本身不测，见计划假设）。draft 实体 → 守卫拦截。
      assert :ok =
               SignalSubscriber.deliver(Instantiator, %{
                 type: "event.launched",
                 data: %{"event_id" => event.id, "title" => event.title}
               })

      runs =
        WorkflowRun
        |> Ash.Query.for_read(:read)
        |> Ash.read!(tenant: workspace.id, actor: admin)

      assert runs == []
    end

    test "open event 信号创建 run（守卫不误伤）" do
      admin = Fixtures.platform_admin("tl")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: curriculum_node_def()})
      {:ok, _published} = publish_definition(defn, workspace, admin)
      {:ok, event} = create_event(workspace, admin)

      # 直接置 open（不走 launch action——launch 现在会在事务提交后发信号触发
      # 生产订阅进程，与白盒调用竞态；#1 修复后生产路径已生效，白盒测试只测
      # 守卫逻辑本身）。
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE events SET status = 'open' WHERE id = $1",
          [Ecto.UUID.dump!(event.id)]
        )

      assert :ok =
               SignalSubscriber.deliver(Instantiator, %{
                 type: "event.launched",
                 data: %{"event_id" => event.id, "title" => event.title}
               })

      runs =
        WorkflowRun
        |> Ash.Query.for_read(:read)
        |> Ash.read!(tenant: workspace.id, actor: admin)

      assert length(runs) == 1
    end

    test "curriculum_enabled=false 不实例化（#6 门控）" do
      admin = Fixtures.platform_admin("tl")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: curriculum_node_def()})
      {:ok, _published} = publish_definition(defn, workspace, admin)
      {:ok, event} = create_event(workspace, admin, %{curriculum_enabled: false})

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE events SET status = 'open' WHERE id = $1",
          [Ecto.UUID.dump!(event.id)]
        )

      assert :ok =
               SignalSubscriber.deliver(Instantiator, %{
                 type: "event.launched",
                 data: %{"event_id" => event.id, "title" => event.title}
               })

      runs =
        WorkflowRun
        |> Ash.Query.for_read(:read)
        |> Ash.read!(tenant: workspace.id, actor: admin)

      assert runs == []
    end

    test "实例化后回写 workflow_run_id（#14 产物引用链）" do
      admin = Fixtures.platform_admin("tl")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: curriculum_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, event} = create_event(workspace, admin)

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE events SET status = 'open' WHERE id = $1",
          [Ecto.UUID.dump!(event.id)]
        )

      assert :ok =
               SignalSubscriber.deliver(Instantiator, %{
                 type: "event.launched",
                 data: %{"event_id" => event.id, "title" => event.title}
               })

      # 实体 workflow_run_id 已回写（非 nil 且指向真实 run）
      updated =
        Ash.get!(Event, event.id, tenant: workspace.id, actor: admin, authorize?: false)

      assert updated.workflow_run_id != nil

      run =
        Ash.get!(WorkflowRun, updated.workflow_run_id, tenant: workspace.id, authorize?: false)

      assert run.definition_id == published.id
    end
  end

  describe "异步路径教研定义选择（确定性）" do
    test "无 published 教研定义时跳过实例化（不 raise、不建 run）" do
      admin = Fixtures.platform_admin("tl")
      workspace = Fixtures.create_workspace(admin)

      # #348 后新 workspace 恒 seed published 定义——异常态(无定义)布景直删
      Cgc2046.Repo.query!("DELETE FROM workflow_definitions WHERE workspace_id = $1", [
        Ecto.UUID.dump!(workspace.id)
      ])

      {:ok, event} = create_event(workspace, admin)

      {:ok, launched} =
        event
        |> Ash.Changeset.for_update(:launch, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert launched.status == :open

      # 工作台无任何 published 教研定义 → fetch_curriculum_definition 返回 nil，
      # 不得 nil-deref raise，也不得创建 run（best-effort 跳过）。
      assert :ok =
               SignalSubscriber.deliver(Instantiator, %{
                 type: "event.launched",
                 data: %{"event_id" => launched.id, "title" => launched.title}
               })

      runs =
        WorkflowRun
        |> Ash.Query.for_read(:read)
        |> Ash.read!(tenant: workspace.id, actor: admin)

      assert runs == []
    end

    test "多个 published 教研定义时取最新（inserted_at desc）" do
      admin = Fixtures.platform_admin("tl")
      workspace = Fixtures.create_workspace(admin)

      {:ok, def_a} =
        create_definition(workspace, admin, %{name: "教研 A", node_def: curriculum_node_def()})

      {:ok, pub_a} = publish_definition(def_a, workspace, admin)

      {:ok, def_b} =
        create_definition(workspace, admin, %{name: "教研 B", node_def: curriculum_node_def()})

      {:ok, pub_b} = publish_definition(def_b, workspace, admin)

      {:ok, event} = create_event(workspace, admin)

      # 直接置 open（不走 launch action——launch 现在会在事务提交后发信号触发
      # 生产订阅进程，与白盒调用竞态；#1 修复后生产路径已生效，白盒测试只测
      # 定义选择逻辑本身）。
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE events SET status = 'open' WHERE id = $1",
          [Ecto.UUID.dump!(event.id)]
        )

      assert :ok =
               SignalSubscriber.deliver(Instantiator, %{
                 type: "event.launched",
                 data: %{"event_id" => event.id, "title" => event.title}
               })

      runs =
        WorkflowRun
        |> Ash.Query.for_read(:read)
        |> Ash.read!(tenant: workspace.id, actor: admin)

      assert length(runs) == 1
      assert hd(runs).definition_id == pub_b.id
      refute hd(runs).definition_id == pub_a.id
    end
  end
end
