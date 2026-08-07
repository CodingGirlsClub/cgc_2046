defmodule Cgc2046.Workflows.CheckpointLifecycle do
  @moduledoc """
  Checkpoint 生命周期单源（架构评审候选 #2，ADR-0003「checkpoint 剥离出引擎核心」落地）。

  按 status 驱动 checkpoint 生命周期：`:waiting` → hibernate（写，严格）；终态
  （`:succeeded`/`:failed`/`:cancelled`/`:expired`）→ delete（清，宽松）。
  **失败策略按操作区分，本模块是唯一定义处**：

  - **写（hibernate）严格**：失败返回 `{:error, {:hibernate_failed, reason}}`，不吞。
    hibernate 失败 = run 标 waiting 但无 checkpoint = 下次信号 thaw 死路，run 永久卡死
    （#2 bug class，commit `16e6072`）。
  - **清（delete）宽松**：失败 `Logger.error` + 返回 `:ok`。checkpoint 泄漏可对账，
    不该卡住状态流转（#16 既有设计意图）。

  引擎（`Engine.run`/`Engine.resume`）不再内建生命周期决策——Engine 只执行；
  本模块是产品层（`WorkflowRun`）的接线点。原语（hibernate/thaw/delete_checkpoint）
  在 `JidoAdapter`，本模块不重复实现。
  """

  alias Cgc2046.Workflows.JidoAdapter

  require Logger

  @terminal_statuses [:succeeded, :failed, :cancelled, :expired]

  @doc """
  按 status 驱动 checkpoint 生命周期。

  - `:waiting` → hibernate（写，严格：失败上抛为 `{:error, {:hibernate_failed, reason}}`）
  - 终态（`:succeeded`/`:failed`/`:cancelled`/`:expired`）→ delete（清，宽松：失败记日志不阻塞）

  返回 `:ok` 或 `{:error, {:hibernate_failed, reason}}`。未知 status 为编程错误
  （CaseClauseError）。
  """
  @spec on_status(atom(), term(), term(), map() | nil) :: :ok | {:error, term()}
  def on_status(status, run_id, partition, workflow) do
    on_status(status, run_id, partition, workflow, JidoAdapter)
  end

  @doc false
  # 测试缝：注入 adapter（实现 hibernate/3 + delete_checkpoint/2 同签名），覆盖
  # 失败契约（写严格 / 清宽松）。与 StepAuthorization.authorize_signal/5 同先例。
  @spec on_status(atom(), term(), term(), map() | nil, module()) :: :ok | {:error, term()}
  def on_status(status, run_id, partition, workflow, adapter) do
    case status do
      :waiting ->
        case adapter.hibernate(run_id, partition, workflow) do
          :ok -> :ok
          {:error, reason} -> {:error, {:hibernate_failed, reason}}
        end

      status when status in @terminal_statuses ->
        delete_terminal(adapter, run_id, partition)
    end
  end

  defp delete_terminal(adapter, run_id, partition) do
    case adapter.delete_checkpoint(run_id, partition) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("checkpoint cleanup failed for run #{run_id}: #{inspect(reason)}")
        :ok
    end
  end
end
