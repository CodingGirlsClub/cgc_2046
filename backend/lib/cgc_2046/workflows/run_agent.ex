defmodule Cgc2046.Workflows.RunAgent do
  @moduledoc """
  WorkflowRun 的 Jido Agent 载体（阶段 2 最小形态）。

  仅用于 `Jido.Persist.hibernate/thaw` 的 checkpoint 载体：state 持 workflow 快照
  （`%{workflow: runic_workflow}`），无 Agent 生命周期/策略/信号路由——阶段 2 的
  执行主路径是 Workflow 层 runic runner（`JidoAdapter.react_until_satisfied/2`），
  不走 Agent 策略层（F1 死锁，见 `Cgc2046.Workflows.JidoAdapter` moduledoc）。

  `Jido.Persist` 的默认 checkpoint/restore 回调要求 agent 模块实现 `new/1`
  （返回 `{:ok, agent}` 或 struct），并支持 `state` 字段合并。
  """

  defstruct [:id, :partition, :state]

  @type t :: %__MODULE__{id: term(), partition: term(), state: map()}

  @doc "构造 RunAgent（state 持 workflow 快照）"
  @spec new!(term(), term(), term()) :: t()
  def new!(run_id, partition, workflow) do
    %__MODULE__{
      id: run_id,
      partition: partition,
      state: %{workflow: workflow}
    }
  end

  @doc "Jido.Persist 默认 restore 回调：按 id 重建空 agent（state 由 checkpoint 合并）"
  @spec new(keyword()) :: {:ok, t()}
  def new(opts) do
    {:ok, struct!(__MODULE__, Keyword.put_new(opts, :state, %{}))}
  end
end
