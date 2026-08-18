defmodule Cgc2046.Workers.ShareSchemeWorker do
  @moduledoc """
  微信 URL Scheme 预生成 job（plan 011 P3）。

  `event.launched`/`course.launched` → ShareSchemeInstantiator 入队本 worker →
  调 `ShareSchemeService.fetch_or_generate/2`（生成/复用/clamp 契约见其 moduledoc）。

  错误语义（plan owner 2026-08-18 应答）：`:not_found`（目标不存在，重试无意义）
  → warning + `:ok` 不重试；平台错误（限频 44990 等）返回 `{:error, _}` 走 Oban
  默认重试——scheme 生成是非关键路径，失败不阻断任何业务。

  幂等：fetch_or_generate 天然幂等（未过期命中复用零外呼）；unique 防同目标
  短窗重复入队（period 1h，states :incomplete）。
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 3600, fields: [:worker, :args], states: :incomplete]

  require Logger

  alias Cgc2046.Miniprogram.ShareSchemeService

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"target_kind" => kind, "target_id" => target_id}}) do
    case ShareSchemeService.fetch_or_generate(String.to_existing_atom(kind), target_id) do
      {:ok, _scheme} ->
        :ok

      {:error, :not_found} ->
        Logger.warning("ShareSchemeWorker target not found: #{kind} #{target_id}, skip")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
