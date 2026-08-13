defmodule Cgc2046.Workers.SignalPublishWorker do
  @moduledoc """
  信号发布重试（E-9 #124）：after_transaction 直接发布失败 → 入队本 worker
  重投（Oban backoff），兑现「至少一次投递」（消费方经 signal_idempotency
  幂等去重，重复投递安全）。

  与 EventLifecycleWorker 同 queue（:maintenance）；args 为 JSON 安全载荷
  （UUID 已 cast 为字符串）。
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 8

  alias Cgc2046.Workflows.JidoAdapter

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"signal_type" => signal_type, "data" => data, "tenant" => tenant}
      }) do
    case JidoAdapter.publish(signal_type, data, tenant) do
      :ok ->
        :ok

      {:error, reason} ->
        # 返回 {:error, _} 触发 Oban 重试（backoff 60s×5）
        {:error, reason}
    end
  end

  @doc """
  发布失败后的重试入队（best-effort：入队本身失败只记日志，可见性交对账）。
  """
  @spec retry_later(String.t(), map(), String.t() | nil) :: :ok
  def retry_later(signal_type, data, tenant) when is_binary(signal_type) and is_map(data) do
    %{signal_type: signal_type, data: data, tenant: tenant}
    |> new()
    |> Oban.insert!()

    :ok
  rescue
    e ->
      Logger.error(
        "SignalPublishWorker enqueue failed for #{signal_type}: #{Exception.message(e)}"
      )

      :ok
  end
end
