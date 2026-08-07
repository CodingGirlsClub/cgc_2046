defmodule Cgc2046.Workflows.StepTest do
  @moduledoc """
  #36 Step 四分类 + 顺序解锁（阶段 3）验收测试。

  覆盖：四分类（auto/manual/gate/sub_workflow）构建与执行、`next` 顺序解锁、
  `next` 回退数组顺序、gate 条件路由、input_schema 校验、sub_workflow stub、
  next 引用完整性。
  """

  use ExUnit.Case, async: false

  alias Cgc2046.Workflows.{Engine, JidoAdapter, StepHandlerRegistry, TestActions}

  setup do
    # 注册测试 step handlers（ADR-0003 两阶段初始化：引擎只执行显式注册的模块）
    StepHandlerRegistry.register(TestActions.Uppercase)
    StepHandlerRegistry.register(TestActions.AppendExclamation)
    StepHandlerRegistry.register(TestActions.AlwaysFail)
    :ok
  end

  defp uppercase_step(extra \\ %{}) do
    Map.merge(
      %{
        "id" => "uppercase",
        "type" => "auto",
        "action" => "Elixir.Cgc2046.Workflows.TestActions.Uppercase"
      },
      extra
    )
  end

  defp append_step(extra \\ %{}) do
    Map.merge(
      %{
        "id" => "append_exclamation",
        "type" => "auto",
        "action" => "Elixir.Cgc2046.Workflows.TestActions.AppendExclamation"
      },
      extra
    )
  end

  describe "四分类：auto/manual/gate/sub_workflow" do
    test "auto step builds and executes" do
      node_def = %{"steps" => [uppercase_step()]}

      assert {:ok, workflow} = JidoAdapter.build_workflow(node_def)
      assert {:ok, workflow} = JidoAdapter.react_until_satisfied(workflow, %{"text" => "hi"})
      assert JidoAdapter.run_status(workflow) == :succeeded
      assert JidoAdapter.list_run_facts(workflow)["uppercase"] == %{text: "HI"}
    end

    test "manual step builds and waits for signal" do
      node_def = %{"steps" => [%{"id" => "approval", "type" => "manual"}]}

      assert {:ok, workflow} = JidoAdapter.build_workflow(node_def)
      assert {:ok, workflow} = JidoAdapter.react_until_satisfied(workflow, %{"text" => "hi"})
      assert JidoAdapter.run_status(workflow) == :waiting
    end

    test "gate step builds and routes by condition" do
      node_def = %{
        "steps" => [
          %{
            "id" => "check",
            "type" => "gate",
            "condition" => %{"field" => "status", "equals" => "full"},
            "next" => ["uppercase"]
          },
          uppercase_step()
        ]
      }

      assert {:ok, workflow} = JidoAdapter.build_workflow(node_def)

      assert {:ok, workflow} =
               JidoAdapter.react_until_satisfied(workflow, %{"status" => "full", "text" => "hi"})

      assert JidoAdapter.run_status(workflow) == :succeeded
      assert JidoAdapter.list_run_facts(workflow)["uppercase"] == %{text: "HI"}
    end

    test "sub_workflow step builds and passes input through (v1 stub)" do
      node_def = %{"steps" => [%{"id" => "sub", "type" => "sub_workflow"}]}

      assert {:ok, workflow} = JidoAdapter.build_workflow(node_def)
      assert {:ok, workflow} = JidoAdapter.react_until_satisfied(workflow, %{"text" => "hi"})
      assert JidoAdapter.run_status(workflow) == :succeeded
      assert JidoAdapter.list_run_facts(workflow)["sub"] == %{"text" => "hi"}
    end
  end

  describe "next 顺序解锁" do
    test "next declares order independent of array order" do
      # 数组顺序是 [append, uppercase]，但 next 声明 uppercase → append：
      # 执行必须按 next 拓扑（uppercase 先跑），而非数组顺序
      node_def = %{
        "steps" => [
          append_step(),
          Map.put(uppercase_step(), "next", ["append_exclamation"])
        ]
      }

      assert {:ok, workflow} = JidoAdapter.build_workflow(node_def)
      assert {:ok, workflow} = JidoAdapter.react_until_satisfied(workflow, %{"text" => "hi"})
      assert JidoAdapter.run_status(workflow) == :succeeded

      facts = JidoAdapter.list_run_facts(workflow)
      assert facts["uppercase"] == %{text: "HI"}
      assert facts["append_exclamation"] == %{text: "HI!"}
    end

    test "downstream step does not run before upstream completes" do
      # approval（manual）next → uppercase：信号未到前 uppercase 不执行
      node_def = %{
        "steps" => [
          %{"id" => "approval", "type" => "manual", "next" => ["uppercase"]},
          uppercase_step()
        ]
      }

      assert {:ok, workflow} = JidoAdapter.build_workflow(node_def)
      assert {:ok, workflow} = JidoAdapter.react_until_satisfied(workflow, %{"text" => "hi"})
      assert JidoAdapter.run_status(workflow) == :waiting
      refute Map.has_key?(JidoAdapter.list_run_facts(workflow), "uppercase")

      # 信号放行 → 下游执行
      assert {:ok, workflow} =
               JidoAdapter.feed_signal(workflow, %{
                 "signal_type" => "workflow.approval",
                 "text" => "hi"
               })

      assert JidoAdapter.run_status(workflow) == :succeeded
      assert JidoAdapter.list_run_facts(workflow)["uppercase"] == %{text: "HI"}
    end

    test "next fallback: no next field uses array order (phase 2 compat)" do
      node_def = %{"steps" => [uppercase_step(), append_step()]}

      assert {:ok, workflow} = JidoAdapter.build_workflow(node_def)
      assert {:ok, workflow} = JidoAdapter.react_until_satisfied(workflow, %{"text" => "hi"})
      assert JidoAdapter.run_status(workflow) == :succeeded

      facts = JidoAdapter.list_run_facts(workflow)
      assert facts["uppercase"] == %{text: "HI"}
      assert facts["append_exclamation"] == %{text: "HI!"}
    end

    test "next referencing unknown step fails at build" do
      node_def = %{
        "steps" => [
          Map.put(uppercase_step(), "next", ["ghost"])
        ]
      }

      assert {:error, {:unknown_next, "ghost"}} = JidoAdapter.build_workflow(node_def)
    end
  end

  describe "gate 条件路由" do
    test "condition satisfied releases downstream" do
      node_def = %{
        "steps" => [
          %{
            "id" => "check",
            "type" => "gate",
            "condition" => %{"field" => "status", "equals" => "full"},
            "next" => ["uppercase"]
          },
          uppercase_step()
        ]
      }

      assert {:ok, facts, _workflow} = Engine.run(node_def, %{"status" => "full", "text" => "hi"})
      assert facts["uppercase"] == %{text: "HI"}
    end

    test "condition not satisfied consumes fact, downstream does not run" do
      node_def = %{
        "steps" => [
          %{
            "id" => "check",
            "type" => "gate",
            "condition" => %{"field" => "status", "equals" => "full"},
            "next" => ["uppercase"]
          },
          uppercase_step()
        ]
      }

      assert {:ok, facts, _workflow} =
               Engine.run(node_def, %{"status" => "partial", "text" => "hi"})

      refute Map.has_key?(facts, "uppercase")
    end

    test "gate with action runs action then checks condition on its output" do
      node_def = %{
        "steps" => [
          %{
            "id" => "check",
            "type" => "gate",
            "action" => "Elixir.Cgc2046.Workflows.TestActions.Uppercase",
            "condition" => %{"field" => "text", "equals" => "HI"},
            "next" => ["append_exclamation"]
          },
          append_step()
        ]
      }

      # 条件基于 action 产物（text == "HI"）判断，满足 → 放行下游
      assert {:ok, facts, _workflow} = Engine.run(node_def, %{"text" => "hi"})
      assert facts["check"] == %{text: "HI"}
      assert facts["append_exclamation"] == %{text: "HI!"}
    end

    test "gate without condition always passes through" do
      node_def = %{
        "steps" => [
          %{"id" => "check", "type" => "gate", "next" => ["uppercase"]},
          uppercase_step()
        ]
      }

      assert {:ok, facts, _workflow} = Engine.run(node_def, %{"text" => "hi"})
      assert facts["uppercase"] == %{text: "HI"}
    end
  end

  describe "input_schema 校验（prepare 阶段）" do
    test "missing required field fails prepare" do
      node_def = %{
        "steps" => [
          Map.put(uppercase_step(), "input_schema", %{"text" => "string"})
        ]
      }

      assert {:error, {:prepare_failed, {:missing_field, "uppercase", "text"}}} =
               Engine.run(node_def, %{})
    end

    test "type mismatch fails prepare" do
      node_def = %{
        "steps" => [
          Map.put(uppercase_step(), "input_schema", %{"text" => "string"})
        ]
      }

      assert {:error,
              {:prepare_failed, {:type_mismatch, "uppercase", "text", "string", "integer"}}} =
               Engine.run(node_def, %{"text" => 123})
    end

    test "all supported types validate" do
      node_def = %{
        "steps" => [
          Map.put(uppercase_step(), "input_schema", %{
            "text" => "string",
            "count" => "integer",
            "flag" => "boolean",
            "meta" => "map",
            "tags" => "list"
          })
        ]
      }

      input = %{
        "text" => "hi",
        "count" => 3,
        "flag" => true,
        "meta" => %{"a" => 1},
        "tags" => ["x", "y"]
      }

      assert {:ok, facts, _workflow} = Engine.run(node_def, input)
      assert facts["uppercase"] == %{text: "HI"}
    end

    test "step without input_schema skips validation" do
      node_def = %{"steps" => [uppercase_step()]}
      assert {:ok, _facts, _workflow} = Engine.run(node_def, %{"text" => "hi"})
    end
  end

  describe "sub_workflow 透传（无 sub_definition_id）" do
    test "passes input through and chains to downstream" do
      node_def = %{
        "steps" => [
          %{"id" => "sub", "type" => "sub_workflow", "next" => ["uppercase"]},
          uppercase_step()
        ]
      }

      assert {:ok, facts, _workflow} = Engine.run(node_def, %{"text" => "hi"})
      assert facts["sub"] == %{"text" => "hi"}
      assert facts["uppercase"] == %{text: "HI"}
    end
  end

  describe "next 引用完整性（Engine 层）" do
    test "next referencing unknown step fails run" do
      node_def = %{
        "steps" => [
          Map.put(uppercase_step(), "next", ["ghost"])
        ]
      }

      # #10：next 校验唯一实现是 JidoAdapter.build_workflow（构建期），
      # Engine 不再重复校验——错误直接透传。
      assert {:error, {:unknown_next, "ghost"}} = Engine.run(node_def, %{"text" => "hi"})
    end
  end
end
