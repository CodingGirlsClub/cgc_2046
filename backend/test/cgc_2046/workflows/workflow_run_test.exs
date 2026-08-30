defmodule Cgc2046.Workflows.WorkflowRunTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures

  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.WorkflowRun
  alias Cgc2046.Workflows.Engine
  alias Cgc2046.Workflows.JidoAdapter
  alias Cgc2046.Workflows.StepHandlerRegistry
  alias Cgc2046.Workflows.TestActions

  require Ash.Query

  setup do
    # 注册测试 step handlers（ADR-0003 两阶段初始化：引擎只执行显式注册的模块）
    StepHandlerRegistry.register(TestActions.Uppercase)
    StepHandlerRegistry.register(TestActions.AppendExclamation)
    StepHandlerRegistry.register(TestActions.AlwaysFail)
    :ok
  end

  defp create_definition(workspace, actor, attrs \\ %{}) do
    defaults = %{
      name: "教研 workflow（测试布景）",
      type: :curriculum,
      input_schema: %{"topic" => "string"},
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

  defp create_run(workspace, actor, defn, attrs \\ %{}) do
    defaults = %{
      definition_id: defn.id,
      definition_version: defn.version,
      input_snapshot: %{"topic" => "t1"}
    }

    WorkflowRun
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs),
      tenant: workspace.id,
      actor: actor
    )
    |> Ash.create(tenant: workspace.id, actor: actor)
  end

  # 双自动步骤链：uppercase → append_exclamation
  defp auto_node_def do
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

  # 自动步骤 + 人工步骤门控：uppercase → (manual approval) → append_exclamation
  defp gated_node_def do
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

  describe "state machine" do
    test "create defaults to status=pending, version=1, facts=%{}" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)

      {:ok, run} = create_run(workspace, admin, published)

      assert run.status == :pending
      assert run.version == 1
      assert run.facts == %{}
      assert run.definition_id == published.id
      assert run.definition_version == published.version
      assert run.partition_id == workspace.id
      assert run.input_snapshot == %{"topic" => "t1"}
      assert is_nil(run.started_at)
      assert is_nil(run.finished_at)
    end

    test "partition_id forced to workspace_id (ADR-0002 决策 6)" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)

      # partition_id 不接受调用方传入（不在 accept 列表），由 tenant 强制
      assert {:error, %Ash.Error.Invalid{}} =
               WorkflowRun
               |> Ash.Changeset.for_create(:create, %{
                 definition_id: published.id,
                 definition_version: published.version,
                 input_snapshot: %{"topic" => "t1"},
                 partition_id: Ecto.UUID.generate()
               })
               |> Ash.create(tenant: workspace.id, actor: admin)

      {:ok, run} = create_run(workspace, admin, published)
      assert run.partition_id == workspace.id
    end

    # /check SC2-004：跨租户 definition_id 必须被拒（对照 new_version 的归属守卫）
    test "create rejects cross-tenant definition_id (SC2-004)" do
      admin = Fixtures.platform_admin("wfrun-admin")
      ws_a = Fixtures.create_workspace(admin)
      ws_b = Fixtures.create_workspace(admin)

      {:ok, defn_a} = create_definition(ws_a, admin)
      {:ok, published_a} = publish_definition(defn_a, ws_a, admin)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               WorkflowRun
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   definition_id: published_a.id,
                   definition_version: published_a.version,
                   input_snapshot: %{"topic" => "t1"}
                 },
                 tenant: ws_b.id
               )
               |> Ash.create(tenant: ws_b.id, actor: admin)

      # 跨租户读被 tenant 作用域拒绝 → not found；若作用域失效则 workspace 归属守卫兜底
      assert Enum.any?(errors, fn e ->
               msg = Exception.message(e)
               msg =~ "not found" or msg =~ "belongs to a different workspace"
             end)
    end

    # /check SC2-004：definition_version 必须与 definition_id 行的 version 一致（防矛盾/伪造）
    test "create rejects mismatched definition_version (SC2-004)" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               WorkflowRun
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   definition_id: published.id,
                   definition_version: 999,
                   input_snapshot: %{"topic" => "t1"}
                 },
                 tenant: workspace.id
               )
               |> Ash.create(tenant: workspace.id, actor: admin)

      assert Enum.any?(errors, &(Exception.message(&1) =~ "got definition_version"))
    end

    # /check SC2-005：状态流转 action 不接受 input_snapshot/definition_version（D-A2 快照）
    test "start rejects input_snapshot/definition_version rebinding (SC2-005)" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published)

      assert {:error, %Ash.Error.Invalid{}} =
               run
               |> Ash.Changeset.for_update(:start, %{
                 input_snapshot: %{"evil" => true},
                 definition_version: 999
               })
               |> Ash.update(tenant: workspace.id, actor: admin)
    end

    test "pending → running → waiting → running → succeeded" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published)

      {:ok, running} =
        run
        |> Ash.Changeset.for_update(:start, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert running.status == :running
      assert running.version == 2
      refute is_nil(running.started_at)

      {:ok, waiting} =
        running
        |> Ash.Changeset.for_update(:wait, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert waiting.status == :waiting

      {:ok, resumed} =
        waiting
        |> Ash.Changeset.for_update(:resume, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert resumed.status == :running

      {:ok, succeeded} =
        resumed
        |> Ash.Changeset.for_update(:complete, %{facts: %{"uppercase" => %{text: "T1"}}},
          actor: admin
        )
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert succeeded.status == :succeeded
      assert succeeded.facts == %{"uppercase" => %{"text" => "T1"}}
      refute is_nil(succeeded.finished_at)
    end

    test "running → failed" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published)

      {:ok, running} =
        run
        |> Ash.Changeset.for_update(:start, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      {:ok, failed} =
        running
        |> Ash.Changeset.for_update(:fail, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert failed.status == :failed
      refute is_nil(failed.finished_at)
    end

    test "pending → cancelled" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published)

      {:ok, cancelled} =
        run
        |> Ash.Changeset.for_update(:cancel, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert cancelled.status == :cancelled
    end

    test "waiting → expired" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published)

      {:ok, running} =
        run
        |> Ash.Changeset.for_update(:start, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      {:ok, waiting} =
        running
        |> Ash.Changeset.for_update(:wait, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      {:ok, expired} =
        waiting
        |> Ash.Changeset.for_update(:expire, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert expired.status == :expired
    end

    test "invalid transitions rejected" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published)

      # pending 不能 complete / fail / wait
      assert {:error, _} =
               run
               |> Ash.Changeset.for_update(:complete, %{}, actor: admin)
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert {:error, _} =
               run
               |> Ash.Changeset.for_update(:fail, %{}, actor: admin)
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert {:error, _} =
               run
               |> Ash.Changeset.for_update(:wait, %{}, actor: admin)
               |> Ash.update(tenant: workspace.id, actor: admin)

      # 终态不可再流转
      {:ok, cancelled} =
        run
        |> Ash.Changeset.for_update(:cancel, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert {:error, _} =
               cancelled
               |> Ash.Changeset.for_update(:start, %{}, actor: admin)
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert {:error, _} =
               cancelled
               |> Ash.Changeset.for_update(:expire, %{}, actor: admin)
               |> Ash.update(tenant: workspace.id, actor: admin)
    end
  end

  describe "engine execution" do
    test "auto steps produce facts, run completes" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: auto_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published, %{input_snapshot: %{"text" => "hi"}})

      {:ok, running} =
        run
        |> Ash.Changeset.for_update(:start, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert {:ok, facts, _workflow} = Engine.run(published.node_def, running.input_snapshot)

      assert facts["uppercase"] == %{text: "HI"}
      assert facts["append_exclamation"] == %{text: "HI!"}

      {:ok, succeeded} =
        running
        |> Ash.Changeset.for_update(:complete, %{facts: facts}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert succeeded.status == :succeeded
      assert succeeded.facts["append_exclamation"] == %{"text" => "HI!"}
    end

    test "manual step gates downstream until signal (waiting → resume → complete)" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: gated_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published, %{input_snapshot: %{"text" => "hi"}})

      {:ok, running} =
        run
        |> Ash.Changeset.for_update(:start, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      # 执行到人工步骤 → waiting，上游 facts 已产出
      assert {:waiting, facts, workflow} = Engine.run(published.node_def, running.input_snapshot)
      assert facts["uppercase"] == %{text: "HI"}
      refute Map.has_key?(facts, "append_exclamation")

      {:ok, waiting} =
        running
        |> Ash.Changeset.for_update(:wait, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      # 信号放行 → 下游继续（#7：Engine.feed_signal/2 已删，零生产调用者；
      # 直接经 JidoAdapter 验证内存 workflow 的信号门控）
      assert {:ok, wf2} =
               JidoAdapter.feed_signal(workflow, %{
                 "signal_type" => "workflow.approval",
                 "approved_by" => "u1"
               })

      assert JidoAdapter.run_status(wf2) == :succeeded
      assert JidoAdapter.list_run_facts(wf2)["append_exclamation"] == %{text: "HI!"}

      facts2 = JidoAdapter.list_run_facts(wf2)

      {:ok, resumed} =
        waiting
        |> Ash.Changeset.for_update(:resume, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      {:ok, succeeded} =
        resumed
        |> Ash.Changeset.for_update(:complete, %{facts: facts2}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert succeeded.status == :succeeded
    end

    test "failing step returns {:error, :step_failed}" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)

      node_def = %{
        "steps" => [
          %{
            "id" => "always_fail",
            "type" => "auto",
            "action" => "Elixir.Cgc2046.Workflows.TestActions.AlwaysFail"
          }
        ]
      }

      {:ok, defn} = create_definition(workspace, admin, %{node_def: node_def})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published)

      {:ok, running} =
        run
        |> Ash.Changeset.for_update(:start, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert {:error, :step_failed} = Engine.run(published.node_def, running.input_snapshot)

      {:ok, failed} =
        running
        |> Ash.Changeset.for_update(:fail, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert failed.status == :failed
    end
  end

  describe "tenant isolation" do
    test "cross-workspace run not visible" do
      admin = Fixtures.platform_admin("wfrun-admin")
      ws_a = Fixtures.create_workspace(admin)
      ws_b = Fixtures.create_workspace(admin)

      {:ok, defn_a} = create_definition(ws_a, admin)
      {:ok, published_a} = publish_definition(defn_a, ws_a, admin)
      {:ok, _run_a} = create_run(ws_a, admin, published_a)

      results =
        WorkflowRun
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(definition_id == ^published_a.id)
        |> Ash.read!(tenant: ws_b.id, actor: admin)

      assert results == []
    end

    test "non-member non-platform-admin cannot read run (H3)" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published)
      outsider = Fixtures.register_user("wfrun-outsider")

      assert {:error, _} =
               Ash.get(WorkflowRun, run.id, tenant: workspace.id, actor: outsider)
    end
  end

  describe "optimistic lock" do
    test "concurrent update on stale version rejected" do
      admin = Fixtures.platform_admin("wfrun-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin)
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published)

      # 两个并发方都基于 version=1 的 run 做 start
      {:ok, _} =
        run
        |> Ash.Changeset.for_update(:start, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      # 第二个 start 基于过期版本 → StaleRecord
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               run
               |> Ash.Changeset.for_update(:start, %{}, actor: admin)
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
    end
  end
end
