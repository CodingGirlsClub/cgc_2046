defmodule Cgc2046.Workflows.CheckpointLifecycleTest do
  @moduledoc """
  CheckpointLifecycle 直测（架构评审候选 #2，计划 §5.1）。

  覆盖：waiting → hibernate 可恢复（round-trip）、终态删除、delete 幂等、
  失败契约（写严格 / 清宽松，fake adapter 注入）。
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Workflows.CheckpointLifecycle
  alias Cgc2046.Workflows.CheckpointLifecycleTest.{FakeDeleteFail, FakeHibernateFail}
  alias Cgc2046.Workflows.JidoAdapter
  alias Cgc2046.Workflows.StepHandlerRegistry
  alias Cgc2046.Workflows.TestActions

  setup do
    # 注册测试 step handlers（ADR-0003 两阶段初始化）
    StepHandlerRegistry.register(TestActions.Uppercase)
    StepHandlerRegistry.register(TestActions.AppendExclamation)
    :ok
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

  defp waiting_workflow do
    {:ok, workflow} = JidoAdapter.build_workflow(gated_node_def())
    {:ok, workflow} = JidoAdapter.react_until_satisfied(workflow, %{"text" => "hi"})
    assert JidoAdapter.run_status(workflow) == :waiting
    workflow
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  describe "on_status(:waiting, ...)" do
    test "hibernates checkpoint (round-trip, facts preserved)" do
      workflow = waiting_workflow()
      run_id = unique_id("run")
      partition = unique_id("ws")

      assert :ok = CheckpointLifecycle.on_status(:waiting, run_id, partition, workflow)

      assert {:ok, restored} = JidoAdapter.thaw(run_id, partition)
      assert JidoAdapter.run_status(restored) == :waiting
      assert JidoAdapter.list_run_facts(restored)["uppercase"] == %{text: "HI"}
    end

    test "hibernate failure is strict (not swallowed)" do
      assert {:error, {:hibernate_failed, :boom}} =
               CheckpointLifecycle.on_status(:waiting, "r", "p", %{}, FakeHibernateFail)
    end
  end

  describe "on_status terminal" do
    test "succeeded deletes checkpoint" do
      workflow = waiting_workflow()
      run_id = unique_id("run")
      partition = unique_id("ws")

      assert :ok = CheckpointLifecycle.on_status(:waiting, run_id, partition, workflow)
      assert {:ok, _} = JidoAdapter.thaw(run_id, partition)

      assert :ok = CheckpointLifecycle.on_status(:succeeded, run_id, partition, workflow)
      assert {:error, :not_found} = JidoAdapter.thaw(run_id, partition)
    end

    test "failed / cancelled / expired delete checkpoint" do
      for status <- [:failed, :cancelled, :expired] do
        workflow = waiting_workflow()
        run_id = unique_id("run")
        partition = unique_id("ws")

        assert :ok = CheckpointLifecycle.on_status(:waiting, run_id, partition, workflow)
        assert :ok = CheckpointLifecycle.on_status(status, run_id, partition, workflow)
        assert {:error, :not_found} = JidoAdapter.thaw(run_id, partition)
      end
    end

    test "delete is idempotent without checkpoint" do
      assert :ok =
               CheckpointLifecycle.on_status(:succeeded, unique_id("run"), unique_id("ws"), nil)
    end

    test "delete failure is lenient (logged, not blocking)" do
      assert :ok = CheckpointLifecycle.on_status(:succeeded, "r", "p", nil, FakeDeleteFail)
    end
  end

  defmodule FakeHibernateFail do
    def hibernate(_run_id, _partition, _workflow), do: {:error, :boom}
  end

  defmodule FakeDeleteFail do
    def delete_checkpoint(_run_id, _partition), do: {:error, :boom}
  end
end
