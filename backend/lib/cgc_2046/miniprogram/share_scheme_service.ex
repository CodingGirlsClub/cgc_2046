defmodule Cgc2046.Miniprogram.ShareSchemeService do
  @moduledoc """
  微信 URL Scheme 分享链接：生成 / 复用 / 到期刷新（plan 011 P2，spike §6
  D1-A/D2-A 拍板）。

  `fetch_or_generate/2`——同一 (target_kind, target_id, platform)：

  - 命中未过期记录 → 直接复用，**零外呼**（D2-A 复用生效的关键行为）
  - 无记录或已过期 → 调 `UrlScheme.create_link/3` 重新生成并 upsert 覆盖
  - errcode（如 44990/40002）原样传播、不落库

  ## 到期 clamp（D-1；时间源修正 = plan owner 2026-08-18 应答选 A）

  Event/Course 均无 endsAt 字段（plan current-state 前提修正），统一以
  `registration_deadline`（两 kind 同形的唯一结束语义字段，
  EventLifecycleWorker 到点自动 close）为 clamp 代理：

      expires_at = min(registration_deadline + 7d, now + 30d)
      registration_deadline 为 nil → now + 30d

  30 天上限是官方临时 scheme 硬约束（错误码 85401，spike §2.3）。

  目标不存在 → `{:error, :not_found}` 传播、不生成不落库（answer 拍板）。
  """

  require Ash.Query

  alias Cgc2046.Offering
  alias Cgc2046.Miniprogram.{ShareScheme, UrlScheme}

  @buffer_days 7
  @max_days 30

  @doc """
  取或生成目标的微信分享 scheme。返回 `{:ok, ShareScheme.t()}` 或
  `{:error, reason}`（`{:platform_rejected, code, msg}` / `{:scheme_failed, _}` /
  `:not_found`）。
  """
  @spec fetch_or_generate(:event | :course, String.t()) ::
          {:ok, ShareScheme.t()} | {:error, term()}
  def fetch_or_generate(target_kind, target_id)
      when target_kind in [:event, :course] and is_binary(target_id) do
    with {:ok, entity} <- Offering.fetch(target_kind, target_id) do
      case fetch_valid(target_kind, target_id) do
        {:ok, %ShareScheme{} = scheme} ->
          {:ok, scheme}

        {:ok, nil} ->
          expires_at = clamp_expires_at(entity.registration_deadline)

          with {:ok, openlink} <- UrlScheme.create_link(target_id, target_kind, expires_at) do
            upsert(target_kind, target_id, openlink, expires_at)
          end
      end
    end
  end

  # 未过期命中（expires_at > now）；nil = 无记录或已过期 → 需重新生成。
  defp fetch_valid(target_kind, target_id) do
    now = DateTime.utc_now()

    ShareScheme
    |> Ash.Query.filter(
      target_kind == ^target_kind and target_id == ^target_id and platform == :wechat and
        expires_at > ^now
    )
    |> Ash.read_one(authorize?: false)
  end

  # min(deadline + 7d, now + 30d)；deadline 缺失 → now + 30d。
  defp clamp_expires_at(registration_deadline) do
    now = DateTime.utc_now()
    cap = DateTime.add(now, @max_days, :day)

    case registration_deadline do
      nil -> cap
      deadline -> deadline |> DateTime.add(@buffer_days, :day) |> earliest(cap)
    end
  end

  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  defp upsert(target_kind, target_id, openlink, expires_at) do
    ShareScheme
    |> Ash.Changeset.for_create(:create, %{
      target_kind: target_kind,
      target_id: target_id,
      platform: :wechat,
      openlink: openlink,
      expires_at: expires_at
    })
    |> Ash.create(authorize?: false)
  end
end
