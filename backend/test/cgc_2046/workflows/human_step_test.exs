defmodule Cgc2046.Workflows.HumanStepTest do
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.WorkflowRun
  alias Cgc2046.Workflows.SignalLog
  alias Cgc2046.Workflows.Engine
  alias Cgc2046.Workflows.JidoAdapter
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

  @admin_email "hstep-admin@example.com"
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
    slug = "hstep-ws-#{System.unique_integer([:positive])}"

    assert {:ok, workspace} =
             Workspace
             |> Ash.Changeset.for_create(:create, %{slug: slug, name: "Human Step WS"})
             |> Ash.create(actor: admin)

    workspace
  end

  defp create_definition(workspace, actor, attrs \\ %{}) do
    defaults = %{
      name: "人工步骤 workflow",
      type: :research,
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

  # 双人工步骤：uppercase → (manual a1) → (manual a2) → append_exclamation
  defp double_gate_node_def do
    %{
      "steps" => [
        %{
          "id" => "uppercase",
          "type" => "auto",
          "action" => "Elixir.Cgc2046.Workflows.TestActions.Uppercase"
        },
        %{"id" => "a1", "type" => "manual"},
        %{"id" => "a2", "type" => "manual"},
        %{
          "id" => "append_exclamation",
          "type" => "auto",
          "action" => "Elixir.Cgc2046.Workflows.TestActions.AppendExclamation"
        }
      ]
    }
  end

  # 人工步骤间有 auto step：uppercase → (manual a1) → append_exclamation → (manual a2)
  defp gate_with_intermediate_auto_node_def do
    %{
      "steps" => [
        %{
          "id" => "uppercase",
          "type" => "auto",
          "action" => "Elixir.Cgc2046.Workflows.TestActions.Uppercase"
        },
        %{"id" => "a1", "type" => "manual"},
        %{
          "id" => "append_exclamation",
          "type" => "auto",
          "action" => "Elixir.Cgc2046.Workflows.TestActions.AppendExclamation"
        },
        %{"id" => "a2", "type" => "manual"}
      ]
    }
  end

  describe "信号放行与恢复（#37 验收）" do
    test "start_run → waiting → resume_signal → succeeded，facts 含下游产物" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: gated_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published, %{input_snapshot: %{"text" => "hi"}})

      # start_run：pending → waiting（执行到人工步骤，上游 facts 已产出并 hibernate）
      {:ok, waiting} =
        run
        |> Ash.Changeset.for_update(:start_run, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert waiting.status == :waiting
      assert waiting.facts["uppercase"] == %{"text" => "HI"}
      refute Map.has_key?(waiting.facts, "append_exclamation")

      # resume_signal：waiting → succeeded（信号放行，下游继续）
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
      assert succeeded.facts["append_exclamation"] == %{"text" => "HI!"}
      refute is_nil(succeeded.finished_at)
    end

    test "resume_signal 写 SignalLog 审计记录" do
      admin = platform_admin()
      workspace = create_workspace(admin)
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
      admin = platform_admin()
      workspace = create_workspace(admin)
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
  end

  describe "hibernate/thaw（Postgres storage）" do
    test "start_run 到 waiting 后 checkpoint 可 thaw 恢复（round-trip）" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: gated_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published, %{input_snapshot: %{"text" => "hi"}})

      {:ok, waiting} =
        run
        |> Ash.Changeset.for_update(:start_run, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert waiting.status == :waiting

      # start_run 已 hibernate（Postgres）→ 直接 thaw 恢复 workflow
      assert {:ok, restored} = JidoAdapter.thaw(run.id, run.partition_id)
      assert JidoAdapter.run_status(restored) == :waiting
      assert JidoAdapter.list_run_facts(restored)["uppercase"] == %{text: "HI"}

      # 恢复后信号放行仍正确
      assert {:ok, restored2} =
               JidoAdapter.feed_signal(restored, %{
                 "signal_type" => "workflow.approval",
                 "approved_by" => "u1"
               })

      assert JidoAdapter.run_status(restored2) == :succeeded
    end

    test "Engine.resume 恢复执行并删除 checkpoint（succeeded 后）" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: gated_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published, %{input_snapshot: %{"text" => "hi"}})

      {:ok, waiting} =
        run
        |> Ash.Changeset.for_update(:start_run, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert waiting.status == :waiting
      # checkpoint 存在
      assert {:ok, _} = JidoAdapter.thaw(run.id, run.partition_id)

      assert {:ok, facts, _workflow} =
               Engine.resume(run.id, run.partition_id, %{
                 "signal_type" => "workflow.approval",
                 "approved_by" => "u1"
               })

      assert facts["append_exclamation"] == %{text: "HI!"}

      # succeeded 后 checkpoint 已清理
      assert {:error, :not_found} = JidoAdapter.thaw(run.id, run.partition_id)
    end

    test "cancel 删除 checkpoint（#16：waiting → cancelled 不留 jido_checkpoints）" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: gated_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published, %{input_snapshot: %{"text" => "hi"}})

      {:ok, waiting} =
        run
        |> Ash.Changeset.for_update(:start_run, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert waiting.status == :waiting
      # checkpoint 存在
      assert {:ok, _} = JidoAdapter.thaw(run.id, run.partition_id)

      assert {:ok, cancelled} =
               waiting
               |> Ash.Changeset.for_update(:cancel, %{}, actor: admin)
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert cancelled.status == :cancelled

      # cancelled 后 checkpoint 已清理
      assert {:error, :not_found} = JidoAdapter.thaw(run.id, run.partition_id)
    end

    test "Engine.resume 不匹配信号时保持 waiting 并更新 checkpoint" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: gated_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published, %{input_snapshot: %{"text" => "hi"}})

      {:ok, waiting} =
        run
        |> Ash.Changeset.for_update(:start_run, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      # 错误信号类型（不匹配门控）→ 仍 waiting，checkpoint 保持
      assert {:waiting, _facts, _workflow} =
               Engine.resume(run.id, run.partition_id, %{
                 "signal_type" => "workflow.other_step"
               })

      assert {:ok, _} = JidoAdapter.thaw(run.id, run.partition_id)
    end

    test "thaw of unknown run returns :not_found（Postgres 隔离）" do
      assert {:error, :not_found} = JidoAdapter.thaw("no-such-run", "no-such-partition")
    end

    test "hibernate 失败时 run 标 failed 而非 waiting（#2 回归）" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: gated_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published, %{input_snapshot: %{"text" => "hi"}})

      # 模拟 checkpoint 写失败：drop jido_checkpoints 表（sandbox 事务内，测试结束回滚）。
      # buggy 代码吞掉 hibernate 失败 → run 标 waiting 但无 checkpoint，下次信号
      # thaw 死路，run 永久卡死。修复后：hibernate 失败 → run 标 failed。
      {:ok, _} = Ecto.Adapters.SQL.query(Cgc2046.Repo, "DROP TABLE jido_checkpoints")

      {:ok, failed} =
        run
        |> Ash.Changeset.for_update(:start_run, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert failed.status == :failed
      refute is_nil(failed.finished_at)

      # 无 checkpoint 残留（hibernate 未写入；表已 drop，thaw 报 storage_error）
      assert {:error, _} = JidoAdapter.thaw(run.id, run.partition_id)
    end
  end

  describe "多信号分批 feed（F1 死锁回归防护）" do
    test "双人工步骤依次放行，不丢不重" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      {:ok, defn} = create_definition(workspace, admin, %{node_def: double_gate_node_def()})
      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published, %{input_snapshot: %{"text" => "hi"}})

      {:ok, waiting} =
        run
        |> Ash.Changeset.for_update(:start_run, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert waiting.status == :waiting
      assert waiting.facts["uppercase"] == %{"text" => "HI"}

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
      refute Map.has_key?(waiting2.facts, "append_exclamation")

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
      assert succeeded.facts["append_exclamation"] == %{"text" => "HI!"}
    end

    test "waiting 分支更新中间 facts，信号 payload 进入下游上下文" do
      admin = platform_admin()
      workspace = create_workspace(admin)

      {:ok, defn} =
        create_definition(workspace, admin, %{node_def: gate_with_intermediate_auto_node_def()})

      {:ok, published} = publish_definition(defn, workspace, admin)
      {:ok, run} = create_run(workspace, admin, published, %{input_snapshot: %{"text" => "hi"}})

      {:ok, waiting} =
        run
        |> Ash.Changeset.for_update(:start_run, %{}, actor: admin)
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert waiting.status == :waiting
      assert waiting.facts["uppercase"] == %{"text" => "HI"}

      # 放行 a1 → 中间 auto step（append_exclamation）执行 → 仍 waiting（a2 未放行）
      {:ok, waiting2} =
        waiting
        |> Ash.Changeset.for_update(
          :resume_signal,
          %{
            signal_type: "workflow.a1",
            payload: %{approved_by: "u1", comment: "looks good"}
          },
          actor: admin
        )
        |> Ash.update(tenant: workspace.id, actor: admin)

      assert waiting2.status == :waiting
      # F1 修复：waiting 分支也写 facts（中间产物不丢）
      assert waiting2.facts["append_exclamation"] == %{"text" => "HI!"}

      # F2 修复：payload 进入 workflow 上下文（merge 折叠），checkpoint 可恢复
      assert {:ok, restored} = JidoAdapter.thaw(run.id, run.partition_id)
      assert JidoAdapter.run_status(restored) == :waiting

      # 放行 a2 → succeeded
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
      assert succeeded.facts["append_exclamation"] == %{"text" => "HI!"}
    end
  end

  describe "deadline expire" do
    test "waiting → expire（人工触发，状态流转验证）" do
      admin = platform_admin()
      workspace = create_workspace(admin)
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
