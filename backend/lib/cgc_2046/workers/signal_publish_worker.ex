defmodule Cgc2046.Workers.SignalPublishWorker do
  @moduledoc """
  信号发布投递（E-9 #124，复审 B1 收口）：ended 信号统一经本 worker 发布。

  **事务内 outbox 模式**：`enqueue_in_transaction/3` 由 Event/Course close/cancel
  的 `Ash.Changeset.after_action` hook 调用（Ash 3.31：数据层成功后、事务提交前
  执行，错误回滚整个事务）——job 与实体终态同事务提交；入队失败 → 事务回滚，
  close/cancel 整体失败可安全重试（幂等）；worker 发布失败经 Oban 重试
  （max_attempts 8）。至少一次投递由「事务性 job + Oban 重试」保证，消费方经
  signal_idempotency 幂等去重。

  与 EventLifecycleWorker 同 queue（:maintenance）；args 为 JSON 安全载荷
  （UUID 已 cast 为字符串）。
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 8

  alias Cgc2046.Workflows.JidoAdapter

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"signal_type" => signal_type, "data" => data}}) do
    case JidoAdapter.publish(signal_type, data) do
      :ok ->
        :ok

      {:error, reason} ->
        # 返回 {:error, _} 触发 Oban 重试
        {:error, reason}
    end
  end

  @doc """
  事务内入队（Ash `before_transaction` hook 调用）：插入失败 raise 使事务回滚，
  close/cancel 整体失败可安全重试（幂等）。
  """
  @spec enqueue_in_transaction(String.t(), map(), String.t() | nil) :: :ok
  def enqueue_in_transaction(signal_type, data, tenant)
      when is_binary(signal_type) and is_map(data) do
    %{signal_type: signal_type, data: data, tenant: tenant}
    |> new()
    |> Oban.insert!()

    :ok
  end
end
