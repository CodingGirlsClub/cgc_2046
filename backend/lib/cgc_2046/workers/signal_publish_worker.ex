defmodule Cgc2046.Workers.SignalPublishWorker do
  @moduledoc """
  信号发布投递（E-9 #124，复审 B1 收口）：ended 信号统一经本 worker 发布。

  **事务内 outbox 模式**：`enqueue_in_transaction/3` 在 Ash 事务内插入 Oban job
  （`before_transaction` hook 调用）——入队失败随事务回滚，close/cancel 不落库；
  job 随事务提交后可见，worker 发布失败经 Oban 重试（max_attempts 8）。
  至少一次投递由「事务性 job + Oban 重试」保证，消费方经 signal_idempotency
  幂等去重。

  与 EventLifecycleWorker 同 queue（:maintenance）；args 为 JSON 安全载荷
  （UUID 已 cast 为字符串）。
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 8

  alias Cgc2046.Workflows.JidoAdapter

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"signal_type" => signal_type, "data" => data, "tenant" => tenant}
      }) do
    case JidoAdapter.publish(signal_type, data, tenant) do
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
