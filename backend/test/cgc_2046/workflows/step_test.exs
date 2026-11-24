defmodule Cgc2046.Workflows.StepTest do
  @moduledoc """
  纯数据线性人工门控引擎（`Cgc2046.Workflows.Engine`）单测。

  覆盖：单步/多步线性门控、`next` 拓扑排序与数组回退、`unknown_next`、
  `invalid_next`、`cycle_detected`、`duplicate_step_id`、`unsupported_step_type`
  （含 `"auto"`/`"gate"`/`"sub_workflow"` 被拒）、`invalid_step_id`、无 BEAM atom
  创建（SC2-003）、错序信号不提前放行、`prepare_all` `input_schema` 校验。
  """

  use ExUnit.Case, async: true

  alias Cgc2046.Workflows.Engine

  describe "validate_and_order_steps/1" do
    test "rejects nil, missing steps, non-list steps, or empty steps" do
      assert {:error, :no_steps} = Engine.validate_and_order_steps(nil)
      assert {:error, :no_steps} = Engine.validate_and_order_steps(%{})
      assert {:error, :no_steps} = Engine.validate_and_order_steps(%{"steps" => nil})
      assert {:error, :no_steps} = Engine.validate_and_order_steps(%{"steps" => "bad"})
      assert {:error, :no_steps} = Engine.validate_and_order_steps(%{"steps" => []})
    end

    test "rejects non-map step or step missing required id/type" do
      assert {:error, {:step_missing_required_fields, "approval"}} =
               Engine.validate_and_order_steps(%{"steps" => ["approval"]})

      assert {:error, {:step_missing_required_fields, %{"type" => "manual"}}} =
               Engine.validate_and_order_steps(%{"steps" => [%{"type" => "manual"}]})

      assert {:error, {:step_missing_required_fields, %{"id" => "", "type" => "manual"}}} =
               Engine.validate_and_order_steps(%{"steps" => [%{"id" => "", "type" => "manual"}]})

      assert {:error, {:step_missing_required_fields, %{"id" => "a1"}}} =
               Engine.validate_and_order_steps(%{"steps" => [%{"id" => "a1"}]})
    end

    test "rejects invalid step id (SC2-002)" do
      for bad_id <- ["BadID", "1start", "has space", "bad-dash", String.duplicate("a", 65)] do
        assert {:error, {:invalid_step_id, ^bad_id}} =
                 Engine.validate_and_order_steps(%{
                   "steps" => [%{"id" => bad_id, "type" => "manual"}]
                 })
      end
    end

    test "rejects duplicate step id" do
      node_def = %{
        "steps" => [
          %{"id" => "approval", "type" => "manual"},
          %{"id" => "approval", "type" => "manual"}
        ]
      }

      assert {:error, {:duplicate_step_id, "approval"}} =
               Engine.validate_and_order_steps(node_def)
    end

    test "rejects unsupported step types including retired auto, gate, sub_workflow" do
      for bad_type <- ["auto", "gate", "sub_workflow", "mystery", :manual] do
        assert {:error, {:unsupported_step_type, ^bad_type}} =
                 Engine.validate_and_order_steps(%{
                   "steps" => [%{"id" => "step_1", "type" => bad_type}]
                 })
      end
    end

    test "rejects unknown next and malformed next" do
      assert {:error, {:unknown_next, "ghost"}} =
               Engine.validate_and_order_steps(%{
                 "steps" => [%{"id" => "a1", "type" => "manual", "next" => ["ghost"]}]
               })

      assert {:error, {:invalid_next, "a2"}} =
               Engine.validate_and_order_steps(%{
                 "steps" => [
                   %{"id" => "a1", "type" => "manual", "next" => "a2"},
                   %{"id" => "a2", "type" => "manual"}
                 ]
               })

      assert {:error, {:invalid_next, [123]}} =
               Engine.validate_and_order_steps(%{
                 "steps" => [%{"id" => "a1", "type" => "manual", "next" => [123]}]
               })
    end

    test "detects cycles in next graph" do
      self_loop = %{
        "steps" => [%{"id" => "a1", "type" => "manual", "next" => ["a1"]}]
      }

      assert {:error, :cycle_detected} = Engine.validate_and_order_steps(self_loop)

      two_cycle = %{
        "steps" => [
          %{"id" => "a1", "type" => "manual", "next" => ["a2"]},
          %{"id" => "a2", "type" => "manual", "next" => ["a1"]}
        ]
      }

      assert {:error, :cycle_detected} = Engine.validate_and_order_steps(two_cycle)
    end

    test "orders steps via Kahn topological sort when next is present, preserving array order for ties" do
      node_def = %{
        "steps" => [
          %{"id" => "step_b", "type" => "manual"},
          %{"id" => "step_a", "type" => "manual", "next" => ["step_b"]}
        ]
      }

      assert {:ok, [%{"id" => "step_a"}, %{"id" => "step_b"}]} =
               Engine.validate_and_order_steps(node_def)
    end

    test "falls back to array order when no step has non-empty next" do
      node_def = %{
        "steps" => [
          %{"id" => "first", "type" => "manual", "next" => []},
          %{"id" => "second", "type" => "manual"}
        ]
      }

      assert {:ok, [%{"id" => "first"}, %{"id" => "second"}]} =
               Engine.validate_and_order_steps(node_def)
    end
  end

  describe "Engine.run/2 and Engine.resume/3" do
    test "single manual step: run waits, matching signal completes" do
      node_def = %{"steps" => [%{"id" => "approval", "type" => "manual"}]}

      assert {:waiting, %{}} = Engine.run(node_def, %{"text" => "hi"})
      assert {:waiting, %{}} = Engine.resume(node_def, [], %{"signal_type" => "workflow.other"})
      assert {:ok, %{}} = Engine.resume(node_def, [], %{"signal_type" => "workflow.approval"})
    end

    test "multi-step with next topological order: out-of-order signal does not skip gate" do
      node_def = %{
        "steps" => [
          %{"id" => "second", "type" => "manual"},
          %{"id" => "first", "type" => "manual", "next" => ["second"]}
        ]
      }

      assert {:waiting, %{}} = Engine.run(node_def, %{})

      # Waiting for "first"; sending "workflow.second" early must NOT advance or unlock "second"
      assert {:waiting, %{}} = Engine.resume(node_def, [], "workflow.second")

      # Even after "first" arrives, "second" was sent earlier while waiting on "first", so still waiting
      assert {:waiting, %{}} = Engine.resume(node_def, ["workflow.second"], "workflow.first")

      # Once "workflow.second" arrives in order after "workflow.first", completes
      assert {:ok, %{}} =
               Engine.resume(node_def, ["workflow.second", "workflow.first"], "workflow.second")
    end

    test "nil or non-string signal does not advance gate" do
      node_def = %{"steps" => [%{"id" => "a1", "type" => "manual"}]}

      assert {:waiting, %{}} = Engine.resume(node_def, [], nil)
      assert {:waiting, %{}} = Engine.resume(node_def, [], %{})

      assert {:waiting, %{}} =
               Engine.resume(node_def, [%{"bad" => 1}, nil], %{"signal_type" => 123})
    end

    test "invalid node_def returns {:error, reason} on run and resume" do
      bad_def = %{"steps" => [%{"id" => "a1", "type" => "auto"}]}

      assert {:error, {:unsupported_step_type, "auto"}} = Engine.run(bad_def, %{})

      assert {:error, {:unsupported_step_type, "auto"}} =
               Engine.resume(bad_def, [], "workflow.a1")
    end

    test "unknown signal_type and dynamic step ids do not create BEAM atoms (SC2-003)" do
      unique = System.unique_integer([:positive])
      dyn_step = "dyn_step_#{unique}"
      dyn_sig = "workflow.unknown_#{unique}"
      node_def = %{"steps" => [%{"id" => dyn_step, "type" => "manual"}]}

      # Warm up once
      assert {:waiting, %{}} = Engine.resume(node_def, [], %{"signal_type" => "workflow.warmup"})

      before = :erlang.system_info(:atom_count)

      for i <- 1..1000 do
        assert {:waiting, %{}} =
                 Engine.resume(node_def, [], %{"signal_type" => "workflow.unknown_#{unique}_#{i}"})
      end

      after_ = :erlang.system_info(:atom_count)
      assert after_ - before < 100

      assert_raise ArgumentError, fn ->
        :erlang.binary_to_existing_atom(dyn_step, :utf8)
      end

      assert_raise ArgumentError, fn ->
        :erlang.binary_to_existing_atom(dyn_sig, :utf8)
      end

      assert_raise ArgumentError, fn ->
        :erlang.binary_to_existing_atom("workflow.unknown_#{unique}_500", :utf8)
      end
    end
  end

  describe "input_schema 校验（prepare 阶段）" do
    test "missing required field fails prepare" do
      node_def = %{
        "steps" => [
          %{"id" => "approval", "type" => "manual", "input_schema" => %{"text" => "string"}}
        ]
      }

      assert {:error, {:prepare_failed, {:missing_field, "approval", "text"}}} =
               Engine.run(node_def, %{})
    end

    test "type mismatch fails prepare" do
      node_def = %{
        "steps" => [
          %{"id" => "approval", "type" => "manual", "input_schema" => %{"text" => "string"}}
        ]
      }

      assert {:error,
              {:prepare_failed, {:type_mismatch, "approval", "text", "string", "integer"}}} =
               Engine.run(node_def, %{"text" => 123})
    end

    test "all supported types validate" do
      node_def = %{
        "steps" => [
          %{
            "id" => "approval",
            "type" => "manual",
            "input_schema" => %{
              "text" => "string",
              "count" => "integer",
              "flag" => "boolean",
              "meta" => "map",
              "tags" => "list"
            }
          }
        ]
      }

      input = %{
        "text" => "hi",
        "count" => 3,
        "flag" => true,
        "meta" => %{"a" => 1},
        "tags" => ["x", "y"]
      }

      assert :ok = Engine.prepare_all(node_def, input)
      assert {:waiting, %{}} = Engine.run(node_def, input)
    end

    test "step without input_schema skips validation" do
      node_def = %{"steps" => [%{"id" => "approval", "type" => "manual"}]}
      assert :ok = Engine.prepare_all(node_def, %{"text" => "hi"})
      assert {:waiting, %{}} = Engine.run(node_def, %{"text" => "hi"})
    end
  end
end
