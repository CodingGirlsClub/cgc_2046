defmodule Cgc2046.Workflows.JidoAdapterTest do
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Workflows.JidoAdapter
  alias Cgc2046.Workflows.StepHandlerRegistry
  alias Cgc2046.Workflows.TestActions

  setup do
    # 注册测试 step handlers（ADR-0003 两阶段初始化：引擎只执行显式注册的模块）
    StepHandlerRegistry.register(TestActions.Uppercase)
    StepHandlerRegistry.register(TestActions.AppendExclamation)
    StepHandlerRegistry.register(TestActions.AlwaysFail)
    :ok
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

  describe "build_workflow" do
    test "builds linear DAG from node_def" do
      assert {:ok, workflow} = JidoAdapter.build_workflow(auto_node_def())
      assert JidoAdapter.run_status(workflow) == :succeeded
    end

    test "rejects empty steps" do
      assert {:error, :no_steps} = JidoAdapter.build_workflow(%{"steps" => []})
    end

    test "rejects unknown step type" do
      node_def = %{"steps" => [%{"id" => "x", "type" => "mystery"}]}
      assert {:error, {:unsupported_step_type, "mystery"}} = JidoAdapter.build_workflow(node_def)
    end

    # /check SC2-001：未注册的 action 模块（如 Jido.Tools.Files.WriteFile）必须被拒，
    # 杜绝租户用 node_def 让引擎执行任意模块
    test "rejects unregistered action module (SC2-001)" do
      node_def = %{
        "steps" => [
          %{"id" => "write", "type" => "auto", "action" => "Elixir.Jido.Tools.Files.WriteFile"}
        ]
      }

      assert {:error, {:build_workflow_failed, message}} = JidoAdapter.build_workflow(node_def)
      assert message =~ "not a registered step handler"
    end

    # /check SC2-002：非法 step id 必须被拒（原子表耗尽防护）
    test "rejects invalid step id (SC2-002)" do
      node_def = %{
        "steps" => [
          %{
            "id" => "Bad ID!",
            "type" => "auto",
            "action" => "Elixir.Cgc2046.Workflows.TestActions.Uppercase"
          }
        ]
      }

      assert {:error, {:build_workflow_failed, message}} = JidoAdapter.build_workflow(node_def)
      assert message =~ "invalid step id"
    end

    # #36：next 拓扑构建——next 声明顺序，与数组顺序无关
    test "builds next-driven topology independent of array order" do
      node_def = %{
        "steps" => [
          %{
            "id" => "append_exclamation",
            "type" => "auto",
            "action" => "Elixir.Cgc2046.Workflows.TestActions.AppendExclamation"
          },
          %{
            "id" => "uppercase",
            "type" => "auto",
            "action" => "Elixir.Cgc2046.Workflows.TestActions.Uppercase",
            "next" => ["append_exclamation"]
          }
        ]
      }

      assert {:ok, workflow} = JidoAdapter.build_workflow(node_def)
      assert {:ok, workflow} = JidoAdapter.react_until_satisfied(workflow, %{"text" => "hi"})
      assert JidoAdapter.run_status(workflow) == :succeeded

      facts = JidoAdapter.list_run_facts(workflow)
      assert facts["uppercase"] == %{text: "HI"}
      assert facts["append_exclamation"] == %{text: "HI!"}
    end

    # #36：next 引用不存在的 step → 构建失败
    test "rejects next referencing unknown step" do
      node_def = %{
        "steps" => [
          %{
            "id" => "uppercase",
            "type" => "auto",
            "action" => "Elixir.Cgc2046.Workflows.TestActions.Uppercase",
            "next" => ["ghost"]
          }
        ]
      }

      assert {:error, {:unknown_next, "ghost"}} = JidoAdapter.build_workflow(node_def)
    end

    # #36：gate 编译为 Condition 节点——条件满足放行下游
    test "compiles gate to condition node routing downstream" do
      node_def = %{
        "steps" => [
          %{
            "id" => "check",
            "type" => "gate",
            "condition" => %{"field" => "status", "equals" => "full"},
            "next" => ["uppercase"]
          },
          %{
            "id" => "uppercase",
            "type" => "auto",
            "action" => "Elixir.Cgc2046.Workflows.TestActions.Uppercase"
          }
        ]
      }

      assert {:ok, workflow} = JidoAdapter.build_workflow(node_def)

      assert {:ok, workflow} =
               JidoAdapter.react_until_satisfied(workflow, %{"status" => "full", "text" => "hi"})

      assert JidoAdapter.run_status(workflow) == :succeeded
      assert JidoAdapter.list_run_facts(workflow)["uppercase"] == %{text: "HI"}
    end

    # #36：sub_workflow v1 stub——透传输入，不报错
    test "compiles sub_workflow to pass-through stub" do
      node_def = %{"steps" => [%{"id" => "sub", "type" => "sub_workflow"}]}

      assert {:ok, workflow} = JidoAdapter.build_workflow(node_def)
      assert {:ok, workflow} = JidoAdapter.react_until_satisfied(workflow, %{"text" => "hi"})
      assert JidoAdapter.run_status(workflow) == :succeeded
      assert JidoAdapter.list_run_facts(workflow)["sub"] == %{"text" => "hi"}
    end
  end

  describe "react_until_satisfied (F1 死锁回归防护)" do
    test "multi-signal batched feed completes (Workflow 层 runner)" do
      assert {:ok, workflow} = JidoAdapter.build_workflow(gated_node_def())

      # feed1：输入 → 执行到人工门控挂起
      assert {:ok, workflow} = JidoAdapter.react_until_satisfied(workflow, %{"text" => "hi"})
      assert JidoAdapter.run_status(workflow) == :waiting
      assert JidoAdapter.list_run_facts(workflow)["uppercase"] == %{text: "HI"}

      # feed2：审批信号 → 门控放行 → 下游完成
      assert {:ok, workflow} =
               JidoAdapter.feed_signal(workflow, %{
                 "signal_type" => "workflow.approval",
                 "approved_by" => "u1"
               })

      assert JidoAdapter.run_status(workflow) == :succeeded
      assert JidoAdapter.list_run_facts(workflow)["append_exclamation"] == %{text: "HI!"}
    end

    test "wrong signal type does not release the gate" do
      assert {:ok, workflow} = JidoAdapter.build_workflow(gated_node_def())
      assert {:ok, workflow} = JidoAdapter.react_until_satisfied(workflow, %{"text" => "hi"})
      assert JidoAdapter.run_status(workflow) == :waiting

      # 错误信号类型 → 门控不匹配，仍 waiting
      assert {:ok, workflow} =
               JidoAdapter.feed_signal(workflow, %{
                 "signal_type" => "workflow.other",
                 "approved_by" => "u1"
               })

      assert JidoAdapter.run_status(workflow) == :waiting
      refute Map.has_key?(JidoAdapter.list_run_facts(workflow), "append_exclamation")
    end

    test "first step manual reports waiting (no prev fact yet)" do
      node_def = %{
        "steps" => [
          %{"id" => "approval", "type" => "manual"},
          %{
            "id" => "uppercase",
            "type" => "auto",
            "action" => "Elixir.Cgc2046.Workflows.TestActions.Uppercase"
          }
        ]
      }

      assert {:ok, workflow} = JidoAdapter.build_workflow(node_def)
      assert {:ok, workflow} = JidoAdapter.react_until_satisfied(workflow, %{"text" => "hi"})
      assert JidoAdapter.run_status(workflow) == :waiting

      # 首步 manual：输入在 root 被消费（不匹配门控），信号 payload 即下游输入
      assert {:ok, workflow} =
               JidoAdapter.feed_signal(workflow, %{
                 "signal_type" => "workflow.approval",
                 "text" => "hi"
               })

      assert JidoAdapter.run_status(workflow) == :succeeded
      assert JidoAdapter.list_run_facts(workflow)["uppercase"] == %{text: "HI"}
    end

    # /check SC2-009：两个连续 manual 门控必须各自等自己的信号（hash 碰撞修复回归）
    test "two sequential manual gates each wait for their own signal (SC2-009)" do
      node_def = %{
        "steps" => [
          %{"id" => "approval1", "type" => "manual"},
          %{"id" => "approval2", "type" => "manual"},
          %{
            "id" => "uppercase",
            "type" => "auto",
            "action" => "Elixir.Cgc2046.Workflows.TestActions.Uppercase"
          }
        ]
      }

      assert {:ok, workflow} = JidoAdapter.build_workflow(node_def)
      assert {:ok, workflow} = JidoAdapter.react_until_satisfied(workflow, %{"text" => "hi"})
      assert JidoAdapter.run_status(workflow) == :waiting

      # gate1 信号 → 仍 waiting（gate2 未放行）
      assert {:ok, workflow} =
               JidoAdapter.feed_signal(workflow, %{
                 "signal_type" => "workflow.approval1",
                 "text" => "hi"
               })

      assert JidoAdapter.run_status(workflow) == :waiting
      refute Map.has_key?(JidoAdapter.list_run_facts(workflow), "uppercase")

      # gate2 信号 → 放行完成
      assert {:ok, workflow} =
               JidoAdapter.feed_signal(workflow, %{
                 "signal_type" => "workflow.approval2",
                 "text" => "hi"
               })

      assert JidoAdapter.run_status(workflow) == :succeeded
      assert JidoAdapter.list_run_facts(workflow)["uppercase"] == %{text: "HI"}
    end

    # /check SC2-003：未知/畸形 signal_type 不造原子，无操作返回（仍 waiting）
    test "unknown signal_type is a no-op without atom creation (SC2-003)" do
      assert {:ok, workflow} = JidoAdapter.build_workflow(gated_node_def())
      assert {:ok, workflow} = JidoAdapter.react_until_satisfied(workflow, %{"text" => "hi"})

      before = :erlang.system_info(:atom_count)

      for i <- 1..1000 do
        assert {:ok, ^workflow} =
                 JidoAdapter.feed_signal(workflow, %{
                   "signal_type" => "workflow.unknown_#{i}",
                   "x" => 1
                 })
      end

      after_ = :erlang.system_info(:atom_count)
      # 原子增长与信号数无关（残余为 Jido 内部固定开销，非线性）
      assert after_ - before < 100
      assert JidoAdapter.run_status(workflow) == :waiting
    end

    # /check SC2-010：facts 不含门控内部组件（_signal_cond/_signal_step/_merge）
    test "facts exclude internal gate components (SC2-010)" do
      assert {:ok, workflow} = JidoAdapter.build_workflow(gated_node_def())
      assert {:ok, workflow} = JidoAdapter.react_until_satisfied(workflow, %{"text" => "hi"})

      assert {:ok, workflow} =
               JidoAdapter.feed_signal(workflow, %{
                 "signal_type" => "workflow.approval",
                 "approved_by" => "u1"
               })

      facts = JidoAdapter.list_run_facts(workflow)
      assert Map.keys(facts) |> Enum.sort() == ["append_exclamation", "uppercase"]
    end

    test "failing step marks run failed" do
      node_def = %{
        "steps" => [
          %{
            "id" => "always_fail",
            "type" => "auto",
            "action" => "Elixir.Cgc2046.Workflows.TestActions.AlwaysFail"
          }
        ]
      }

      assert {:ok, workflow} = JidoAdapter.build_workflow(node_def)
      assert {:ok, workflow} = JidoAdapter.react_until_satisfied(workflow, %{})
      assert JidoAdapter.run_status(workflow) == :failed
    end
  end

  describe "hibernate/thaw (Postgres storage)" do
    test "round-trips workflow snapshot" do
      assert {:ok, workflow} = JidoAdapter.build_workflow(gated_node_def())
      assert {:ok, workflow} = JidoAdapter.react_until_satisfied(workflow, %{"text" => "hi"})
      assert JidoAdapter.run_status(workflow) == :waiting

      run_id = "run-#{System.unique_integer([:positive])}"
      partition = "ws-#{System.unique_integer([:positive])}"

      assert :ok = JidoAdapter.hibernate(run_id, partition, workflow)

      assert {:ok, restored} = JidoAdapter.thaw(run_id, partition)
      assert JidoAdapter.run_status(restored) == :waiting
      assert JidoAdapter.list_run_facts(restored)["uppercase"] == %{text: "HI"}

      # 恢复后信号放行仍正确
      assert {:ok, restored} =
               JidoAdapter.feed_signal(restored, %{
                 "signal_type" => "workflow.approval",
                 "approved_by" => "u1"
               })

      assert JidoAdapter.run_status(restored) == :succeeded
    end

    test "thaw of unknown run returns :not_found" do
      assert {:error, :not_found} = JidoAdapter.thaw("no-such-run", "no-such-partition")
    end

    test "delete_checkpoint removes checkpoint" do
      assert {:ok, workflow} = JidoAdapter.build_workflow(gated_node_def())
      assert {:ok, workflow} = JidoAdapter.react_until_satisfied(workflow, %{"text" => "hi"})

      run_id = "run-del-#{System.unique_integer([:positive])}"
      partition = "ws-del-#{System.unique_integer([:positive])}"

      assert :ok = JidoAdapter.hibernate(run_id, partition, workflow)
      assert {:ok, _} = JidoAdapter.thaw(run_id, partition)

      assert :ok = JidoAdapter.delete_checkpoint(run_id, partition)
      assert {:error, :not_found} = JidoAdapter.thaw(run_id, partition)

      # 重复删除幂等
      assert :ok = JidoAdapter.delete_checkpoint(run_id, partition)
    end
  end

  describe "publish/subscribe" do
    test "subscriber receives published signal" do
      parent = self()
      partition = "ws-#{System.unique_integer([:positive])}"

      assert {:ok, _sub_id} =
               JidoAdapter.subscribe(
                 "workflow.run.*",
                 fn signal ->
                   send(parent, {:signal, signal.type, signal.data})
                 end,
                 partition
               )

      assert :ok = JidoAdapter.publish("workflow.run.completed", %{"run_id" => "r1"}, partition)

      assert_receive {:signal, "workflow.run.completed", %{"run_id" => "r1"}}, 1_000
    end
  end
end
