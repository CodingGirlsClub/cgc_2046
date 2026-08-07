defmodule Cgc2046.Workflows.TeachingLearningTest do
  @moduledoc """
  #39 教研 workflow 实例化 + sub_workflow 递归执行验收测试（阶段 6）。

  覆盖：

  1. 教研定义复用多实例：一个 research WorkflowDefinition 实例化多个 Event，
     各自独立 WorkflowRun，facts 不串
  2. 子 workflow 嵌套：父定义 sub_workflow 步骤递归执行子定义，facts 嵌套
  3. Event launch 发信号：launch action → status=open + event.launched 信号已发
  4. 幂等实例化：同一 Event 重复 launch → 同一 run
  5. sub_workflow 无 sub_definition_id 透传（向后兼容阶段 3 stub 行为）
  """

  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Events.Event
  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.WorkflowRun
  alias Cgc2046.Workflows.ResearchInstantiator
  alias Cgc2046.Workflows.StepHandlerRegistry
  alias Cgc2046.Workflows.TestActions
  alias AshAuthentication.Info, as: AuthInfo

  setup do
    # 注册测试 step handlers（ADR-0003 两阶段初始化）
    StepHandlerRegistry.register(TestActions.Uppercase)
    StepHandlerRegistry.register(TestActions.AppendExclamation)
    StepHandlerRegistry.register(TestActions.AlwaysFail)
    :ok
  end

  @admin_email "tl-admin@example.com"
  @password "sup3r-secret-password"

  defp password_strategy, do: AuthInfo.strategy!(User, :password)

  defp register_user(email) do
    strategy = password_strategy()

    assert {:ok, user} =
             AshAuthentication.Strategy.action(strategy, :register, %{
               email: email,
               password: @password
             })

    user
  end

  defp platform_admin(email \\ @admin_email) do
    user = register_user(email)

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE users SET is_platform_admin = true WHERE id = $1",
        [Ecto.UUID.dump!(user.id)]
      )

    Ash.get!(User, user.id, actor: user, authorize?: false, domain: Cgc2046.GlobalApi)
  end

  defp create_workspace(admin) do
    slug = "tl-ws-#{System.unique_integer([:positive])}"

    assert {:ok, workspace} =
             Workspace
             |> Ash.Changeset.for_create(:create, %{slug: slug, name: "Teaching Learning WS"})
             |> Ash.create(actor: admin)

    workspace
  end

  defp create_definition(workspace, actor, attrs \\ %{}) do
    defaults = %{
      name: "教研 workflow",
      type: :research,
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
    defaults = %{title: "教研活动", research_requirements: %{"audience" => "kids"}}

    Event
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs),
      tenant: workspace.id,
      actor: actor
    )
    |> Ash.create(tenant: workspace.id, actor: actor)
  end

  # 教研定义：uppercase → (manual approval) → append_exclamation
  defp research_node_def do
    %{
      "steps" => [
        %{
          "id" => "uppercase",
          "type" => "auto",
          "action" => "Elixir.Cgc2046.Workflows.TestActions.Uppercase"
        },
        %{"id" => "approval", "type" => "manual"},
        %{
          "id" => "append_exclamation",
          "type" => "auto",
          "action" => "Elixir.Cgc2046.Workflows.TestActions.AppendExclamation"
        }
      ]
    }
  end

  # 子定义：uppercase → append_exclamation（纯 auto，嵌套执行用）
  defp child_node_def do
    %{
      "steps" => [
        %{
          "id" => "uppercase",
          "type" => "auto",
          "action" => "Elixir.Cgc2046.Workflows.TestActions.Uppercase"
        },
        %{
          "id" => "append_exclamation",
          "type" => "auto",
          "action" => "Elixir.Cgc2046.Workflows.TestActions.AppendExclamation"
        }
      ]
    }
  end

  # 父定义：sub_workflow（sub_definition_id → 子定义）。子 workflow facts 作为
  # 本步骤产物（facts["sub"] 嵌套），验收只断言嵌套产物（计划 §Verification 2）。
  defp parent_node_def(child_defn) do
    %{
      "steps" => [
        %{
          "id" => "sub",
          "type" => "sub_workflow",
          "sub_definition_id" => child_defn.id
        }
      ]
    }
  end

  describe "教研定义复用多实例（#39 验收）" do
    test "一个 research 定义实例化多个 Event，各自独立 run，facts 不串" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: research_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)

      {:ok, event_1} = create_event(workspace, admin, %{title: "活动一"})
      {:ok, event_2} = create_event(workspace, admin, %{title: "活动二"})

      # 各自实例化 → 独立 run，均 waiting（执行到人工步骤）
      assert {:ok, run_1} =
               ResearchInstantiator.launch(
                 workspace.id,
                 published.id,
                 %{
                   "event_id" => event_1.id,
                   "title" => event_1.title,
                   "research_requirements" => event_1.research_requirements,
                   "text" => "hi"
                 },
                 :event
               )

      assert {:ok, run_2} =
               ResearchInstantiator.launch(
                 workspace.id,
                 published.id,
                 %{
                   "event_id" => event_2.id,
                   "title" => event_2.title,
                   "research_requirements" => event_2.research_requirements,
                   "text" => "hi"
                 },
                 :event
               )

      assert run_1.id != run_2.id
      assert run_1.status == :waiting
      assert run_2.status == :waiting
      assert run_1.input_snapshot["key"] == "event_#{event_1.id}"
      assert run_2.input_snapshot["key"] == "event_#{event_2.id}"
      assert run_1.facts["uppercase"] == %{"text" => "HI"}
      assert run_2.facts["uppercase"] == %{"text" => "HI"}

      # 各自放行 → 各自 succeeded，facts 独立
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
      assert done_1.facts["append_exclamation"] == %{"text" => "HI!"}
      assert done_2.facts["append_exclamation"] == %{"text" => "HI!"}
      assert done_1.facts["key"] == nil
      assert done_2.facts["key"] == nil
    end
  end

  describe "子 workflow 嵌套（#39 验收）" do
    test "父定义 sub_workflow 步骤递归执行子定义，facts 嵌套" do
      admin = platform_admin()
      workspace = create_workspace(admin)

      # 子定义（纯 auto）publish
      {:ok, child} = create_definition(workspace, admin, %{node_def: child_node_def()})
      {:ok, child_published} = publish_definition(child, workspace, admin)

      # 父定义（sub_workflow → uppercase）publish
      {:ok, parent} =
        create_definition(workspace, admin, %{
          name: "父教研 workflow",
          node_def: parent_node_def(child_published)
        })

      {:ok, parent_published} = publish_definition(parent, workspace, admin)

      {:ok, event} = create_event(workspace, admin)

      assert {:ok, run} =
               ResearchInstantiator.launch(
                 workspace.id,
                 parent_published.id,
                 %{
                   "event_id" => event.id,
                   "title" => event.title,
                   "research_requirements" => event.research_requirements,
                   "text" => "hi"
                 },
                 :event
               )

      assert run.status == :succeeded

      # 子 workflow facts 作为父 step 的 fact value（嵌套）
      assert run.facts["sub"] == %{
               "uppercase" => %{"text" => "HI"},
               "append_exclamation" => %{"text" => "HI!"}
             }
    end

    test "子 workflow 失败 → 父 run failed（#3 回归）" do
      admin = platform_admin()
      workspace = create_workspace(admin)

      # 子定义含 AlwaysFail（auto 步骤失败）
      {:ok, child} =
        create_definition(workspace, admin, %{
          node_def: %{
            "steps" => [
              %{
                "id" => "boom",
                "type" => "auto",
                "action" => "Elixir.Cgc2046.Workflows.TestActions.AlwaysFail"
              }
            ]
          }
        })

      {:ok, child_published} = publish_definition(child, workspace, admin)

      # 父定义（sub_workflow → 失败子定义）publish
      {:ok, parent} =
        create_definition(workspace, admin, %{
          name: "父教研 workflow（子失败）",
          node_def: parent_node_def(child_published)
        })

      {:ok, parent_published} = publish_definition(parent, workspace, admin)

      {:ok, event} = create_event(workspace, admin)

      # buggy 代码：子 workflow 的 {:error, :sub_workflow_failed} 被 runic 当作
      # 普通 fact 值，父 run 标 succeeded 且错误 tuple 嵌入 facts（#3）。
      # 修复后：子失败 → 父 run failed。
      assert {:ok, run} =
               ResearchInstantiator.launch(
                 workspace.id,
                 parent_published.id,
                 %{
                   "event_id" => event.id,
                   "title" => event.title,
                   "research_requirements" => event.research_requirements,
                   "text" => "hi"
                 },
                 :event
               )

      assert run.status == :failed
      refute is_nil(run.finished_at)
    end
  end

  describe "Event launch 发信号（#39 验收）" do
    test "launch action → status=open + event.launched 信号已发" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, event} = create_event(workspace, admin)

      # 订阅 event.launched 信号（验证 launch action 发布）
      parent = self()

      assert {:ok, _sub_id} =
               Cgc2046.Workflows.JidoAdapter.subscribe(
                 "event.launched",
                 fn signal -> send(parent, {:launched, signal.data}) end,
                 nil
               )

      {:ok, launched} =
        event
        |> Ash.Changeset.for_update(:launch, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert launched.status == :open

      assert_receive {:launched, %{"event_id" => event_id, "title" => title}}, 1_000
      assert event_id == event.id
      assert title == event.title
    end

    test "非 draft 状态不可 launch" do
      admin = platform_admin()
      workspace = create_workspace(admin)
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
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, event} = create_event(workspace, admin)

      parent = self()

      assert {:ok, _sub_id} =
               Cgc2046.Workflows.JidoAdapter.subscribe(
                 "event.launched",
                 fn signal -> send(parent, {:launched, signal.data}) end,
                 nil
               )

      # 构建 changeset——buggy 代码在 change 回调（for_update 阶段，事务开始前）
      # 发布信号，订阅方读到未提交的 draft 状态，ensure_launched 守卫静默丢弃
      # 实例化（#1 TOCTOU）。修复后：for_update 阶段不得发布信号。
      changeset = Ash.Changeset.for_update(event, :launch, %{}, actor: admin)

      # 2s 窗口：buggy 代码在 for_update 发布 → 订阅方转发 → refute 失败（红）
      refute_receive {:launched, _}, 2_000

      {:ok, launched} = Ash.update(changeset, tenant: workspace.id, actor: admin)
      assert launched.status == :open

      # 提交后信号到达（订阅方此时读到已提交的 open 状态，实例化不被丢弃）
      assert_receive {:launched, %{"event_id" => event_id, "title" => title}}, 1_000
      assert event_id == event.id
      assert title == event.title
    end
  end

  describe "幂等实例化（#39 验收）" do
    test "同一 Event 重复 launch → 返回同一 run（不重复创建）" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: research_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, event} = create_event(workspace, admin)

      input = %{
        "event_id" => event.id,
        "title" => event.title,
        "research_requirements" => event.research_requirements,
        "text" => "hi"
      }

      assert {:ok, run_1} = ResearchInstantiator.launch(workspace.id, published.id, input, :event)
      assert {:ok, run_2} = ResearchInstantiator.launch(workspace.id, published.id, input, :event)

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

      assert {:ok, run_3} = ResearchInstantiator.launch(workspace.id, published.id, input, :event)
      assert run_3.id != run_1.id
    end
  end

  describe "异步信号状态守卫（孤儿 run 防护）" do
    test "draft event 信号不创建 run" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: research_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, event} = create_event(workspace, admin)

      # 白盒驱动异步路径（apply 私有函数；测试进程在沙箱内可查 DB，而真实订阅
      # 进程不在沙箱——异步投递本身不测，见计划假设）。draft 实体 → 守卫拦截。
      assert :ok =
               apply(ResearchInstantiator, :instantiate_from_signal, [
                 event.id,
                 :event,
                 %{"event_id" => event.id, "title" => event.title}
               ])

      runs =
        WorkflowRun
        |> Ash.Query.for_read(:read)
        |> Ash.read!(tenant: workspace.id, actor: admin)

      assert runs == []
    end

    test "open event 信号创建 run（守卫不误伤）" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: research_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
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
               apply(ResearchInstantiator, :instantiate_from_signal, [
                 event.id,
                 :event,
                 %{"event_id" => event.id, "title" => event.title}
               ])

      runs =
        WorkflowRun
        |> Ash.Query.for_read(:read)
        |> Ash.read!(tenant: workspace.id, actor: admin)

      assert length(runs) == 1
    end

    test "research_enabled=false 不实例化（#6 门控）" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: research_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, event} = create_event(workspace, admin, %{research_enabled: false})

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE events SET status = 'open' WHERE id = $1",
          [Ecto.UUID.dump!(event.id)]
        )

      assert :ok =
               apply(ResearchInstantiator, :instantiate_from_signal, [
                 event.id,
                 :event,
                 %{"event_id" => event.id, "title" => event.title}
               ])

      runs =
        WorkflowRun
        |> Ash.Query.for_read(:read)
        |> Ash.read!(tenant: workspace.id, actor: admin)

      assert runs == []
    end

    test "实例化后回写 workflow_run_id（#14 产物引用链）" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: research_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, event} = create_event(workspace, admin)

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE events SET status = 'open' WHERE id = $1",
          [Ecto.UUID.dump!(event.id)]
        )

      assert :ok =
               apply(ResearchInstantiator, :instantiate_from_signal, [
                 event.id,
                 :event,
                 %{"event_id" => event.id, "title" => event.title}
               ])

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
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, event} = create_event(workspace, admin)

      {:ok, launched} =
        event
        |> Ash.Changeset.for_update(:launch, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert launched.status == :open

      # 工作台无任何 published 教研定义 → fetch_research_definition 返回 nil，
      # 不得 nil-deref raise，也不得创建 run（best-effort 跳过）。
      assert :ok =
               apply(ResearchInstantiator, :instantiate_from_signal, [
                 launched.id,
                 :event,
                 %{"event_id" => launched.id, "title" => launched.title}
               ])

      runs =
        WorkflowRun
        |> Ash.Query.for_read(:read)
        |> Ash.read!(tenant: workspace.id, actor: admin)

      assert runs == []
    end

    test "多个 published 教研定义时取最新（inserted_at desc）" do
      admin = platform_admin()
      workspace = create_workspace(admin)

      {:ok, def_a} =
        create_definition(workspace, admin, %{name: "教研 A", node_def: research_node_def()})

      {:ok, pub_a} = publish_definition(def_a, workspace, admin)

      {:ok, def_b} =
        create_definition(workspace, admin, %{name: "教研 B", node_def: research_node_def()})

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
               apply(ResearchInstantiator, :instantiate_from_signal, [
                 event.id,
                 :event,
                 %{"event_id" => event.id, "title" => event.title}
               ])

      runs =
        WorkflowRun
        |> Ash.Query.for_read(:read)
        |> Ash.read!(tenant: workspace.id, actor: admin)

      assert length(runs) == 1
      assert hd(runs).definition_id == pub_b.id
      refute hd(runs).definition_id == pub_a.id
    end
  end

  describe "sub_workflow 无 sub_definition_id 透传（向后兼容）" do
    test "step 无 sub_definition_id → 透传 data，不报错" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: research_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, event} = create_event(workspace, admin)

      # 直接经 Engine 跑含无 sub_definition_id 的 sub_workflow 步骤的 node_def
      node_def = %{
        "steps" => [
          %{"id" => "sub", "type" => "sub_workflow", "next" => ["uppercase"]},
          %{
            "id" => "uppercase",
            "type" => "auto",
            "action" => "Elixir.Cgc2046.Workflows.TestActions.Uppercase"
          }
        ]
      }

      assert {:ok, facts, _workflow} =
               Cgc2046.Workflows.Engine.run(node_def, %{"text" => "hi"})

      assert facts["sub"] == %{"text" => "hi"}
      assert facts["uppercase"] == %{text: "HI"}
    end
  end
end
