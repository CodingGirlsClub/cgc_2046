defmodule Cgc2046.Workflows.HumanStepTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.WorkflowRun
  alias Cgc2046.Workflows.SignalLog

  defp create_definition(workspace, actor, attrs) do
    defaults = %{
      name: "人工步骤 workflow",
      type: :curriculum,
      input_schema: %{"topic" => "string"},
      node_def: %{"steps" => [%{"id" => "approval", "type" => "manual"}]},
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

  defp create_run(workspace, actor, defn, attrs) do
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

  # 单人工步骤门控：manual approval
  defp gated_node_def do
    %{
      "steps" => [
        %{"id" => "approval", "type" => "manual"}
      ]
    }
  end

  # 双人工步骤：manual a1 → manual a2
  defp double_gate_node_def do
    %{
      "steps" => [
        %{"id" => "a1", "type" => "manual"},
        %{"id" => "a2", "type" => "manual"}
      ]
    }
  end

  describe "信号放行与恢复（#37 验收）" do
    test "start_run → waiting → resume_signal → succeeded" do
      admin = Fixtures.platform_admin("hstep-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: gated_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published, %{input_snapshot: %{"text" => "hi"}})

      {:ok, waiting} =
        run
        |> Ash.Changeset.for_update(:start_run, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert waiting.status == :waiting
      assert waiting.facts == %{}

      {:ok, succeeded} =
        waiting
        |> Ash.Changeset.for_update(
          :resume_signal,
          %{
            signal_type: "workflow.approval",
            payload: %{approved_by: "u1"}
          },
          actor: admin
        )
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert succeeded.status == :succeeded
      refute is_nil(succeeded.finished_at)
    end

    test "resume_signal 写 SignalLog 审计记录" do
      admin = Fixtures.platform_admin("hstep-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: gated_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published, %{input_snapshot: %{"text" => "hi"}})

      {:ok, waiting} =
        run
        |> Ash.Changeset.for_update(:start_run, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      {:ok, _succeeded} =
        waiting
        |> Ash.Changeset.for_update(
          :resume_signal,
          %{
            signal_type: "workflow.approval",
            payload: %{approved_by: "u1"}
          },
          actor: admin
        )
        |> Ash.update(tenant: workspace.id, actor: admin)

      logs =
        SignalLog
        |> Ash.Query.for_read(:read)
        |> Ash.read!(tenant: workspace.id, actor: admin)

      assert length(logs) == 1
      log = hd(logs)
      assert log.run_id == run.id
      assert log.signal_type == "workflow.approval"
      assert log.payload == %{"approved_by" => "u1"}
      assert log.actor_id == admin.id
      refute is_nil(log.received_at)
    end

    test "start_run 前 resume_signal 被拒（非 waiting 状态）" do
      admin = Fixtures.platform_admin("hstep-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: gated_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published, %{input_snapshot: %{"text" => "hi"}})

      assert {:error, %Ash.Error.Invalid{}} =
               run
               |> Ash.Changeset.for_update(:resume_signal, %{signal_type: "workflow.approval"},
                 actor: admin
               )
               |> Ash.update(tenant: workspace.id, actor: admin)
    end

    test "错误信号保持 waiting，随后发正确信号仍可放行" do
      admin = Fixtures.platform_admin("hstep-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: gated_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published, %{input_snapshot: %{"text" => "hi"}})

      {:ok, waiting} =
        run
        |> Ash.Changeset.for_update(:start_run, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      # 错误信号类型（不匹配门控）→ 仍 waiting
      {:ok, still_waiting} =
        waiting
        |> Ash.Changeset.for_update(:resume_signal, %{signal_type: "workflow.other_step"},
          actor: admin
        )
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert still_waiting.status == :waiting

      # 再发正确信号 → 成功放行
      {:ok, succeeded} =
        still_waiting
        |> Ash.Changeset.for_update(:resume_signal, %{signal_type: "workflow.approval"},
          actor: admin
        )
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert succeeded.status == :succeeded
      refute is_nil(succeeded.finished_at)
    end

    test "waiting 分支支持 cancel / complete / fail 终态流转" do
      admin = Fixtures.platform_admin("hstep-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: gated_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)

      for {action, expected_status} <- [
            {:cancel, :cancelled},
            {:complete, :succeeded},
            {:fail, :failed}
          ] do
        {:ok, run} = create_run(workspace, admin, published, %{})

        {:ok, waiting} =
          run
          |> Ash.Changeset.for_update(:start_run, %{}, actor: admin)
          |> Ash.update(tenant: workspace.id, actor: admin)

        assert {:ok, terminal} =
                 waiting
                 |> Ash.Changeset.for_update(action, %{}, actor: admin)
                 |> Ash.update(tenant: workspace.id, actor: admin)

        assert terminal.status == expected_status
        refute is_nil(terminal.finished_at)
      end
    end

    test "resume_signal 保留既有 persisted facts（如 MCP 写入产物）" do
      admin = Fixtures.platform_admin("hstep-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: double_gate_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published, %{})

      {:ok, waiting} =
        run
        |> Ash.Changeset.for_update(:start_run, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      {:ok, with_facts} =
        waiting
        |> Ash.Changeset.for_update(
          :update_facts_for_mcp,
          %{facts: %{"a1" => %{"draft" => "v1"}}},
          actor: admin
        )
        |> Ash.update(tenant: workspace.id, actor: admin)

      {:ok, waiting2} =
        with_facts
        |> Ash.Changeset.for_update(:resume_signal, %{signal_type: "workflow.a1"}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert waiting2.status == :waiting
      assert waiting2.facts == %{"a1" => %{"draft" => "v1"}}

      {:ok, succeeded} =
        waiting2
        |> Ash.Changeset.for_update(:resume_signal, %{signal_type: "workflow.a2"}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert succeeded.status == :succeeded
      assert succeeded.facts == %{"a1" => %{"draft" => "v1"}}
    end
  end

  describe "多信号顺序门控" do
    test "双人工步骤依次放行，不丢不重" do
      admin = Fixtures.platform_admin("hstep-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: double_gate_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published, %{input_snapshot: %{"text" => "hi"}})

      {:ok, waiting} =
        run
        |> Ash.Changeset.for_update(:start_run, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert waiting.status == :waiting

      # 第一个信号放行 a1 → 仍 waiting（a2 未放行）
      {:ok, waiting2} =
        waiting
        |> Ash.Changeset.for_update(
          :resume_signal,
          %{
            signal_type: "workflow.a1",
            payload: %{approved_by: "u1"}
          },
          actor: admin
        )
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert waiting2.status == :waiting

      # 第二个信号放行 a2 → succeeded
      {:ok, succeeded} =
        waiting2
        |> Ash.Changeset.for_update(
          :resume_signal,
          %{
            signal_type: "workflow.a2",
            payload: %{approved_by: "u2"}
          },
          actor: admin
        )
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert succeeded.status == :succeeded
      refute is_nil(succeeded.finished_at)
    end

    test "错序信号先发 a2 不跳过 a1，需按 a1 → a2 依次放行" do
      admin = Fixtures.platform_admin("hstep-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: double_gate_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published, %{})

      {:ok, waiting} =
        run
        |> Ash.Changeset.for_update(:start_run, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      # 先发 workflow.a2（此时还在等 a1）→ 保持 waiting，不跳过 a1
      {:ok, still_waiting_1} =
        waiting
        |> Ash.Changeset.for_update(:resume_signal, %{signal_type: "workflow.a2"}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert still_waiting_1.status == :waiting

      # 再发 workflow.a1 → 放行 a1，仍等 a2（先前的 a2 未提前消费）
      {:ok, still_waiting_2} =
        still_waiting_1
        |> Ash.Changeset.for_update(:resume_signal, %{signal_type: "workflow.a1"}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert still_waiting_2.status == :waiting

      # 最后发 workflow.a2 → 放行完成
      {:ok, succeeded} =
        still_waiting_2
        |> Ash.Changeset.for_update(:resume_signal, %{signal_type: "workflow.a2"}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert succeeded.status == :succeeded
    end
  end

  describe "deadline expire" do
    test "waiting → expire（人工触发，状态流转验证）" do
      admin = Fixtures.platform_admin("hstep-admin")
      workspace = Fixtures.create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: gated_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published, %{input_snapshot: %{"text" => "hi"}})

      {:ok, waiting} =
        run
        |> Ash.Changeset.for_update(:start_run, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert waiting.status == :waiting

      {:ok, expired} =
        waiting
        |> Ash.Changeset.for_update(:expire, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert expired.status == :expired
      refute is_nil(expired.finished_at)
    end
  end
end
