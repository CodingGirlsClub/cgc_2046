defmodule Cgc2046Web.GraphqlSchema.LlmGateway.Projections do
  @moduledoc """
  LLM Gateway 域 SQL 读模型投影：钱包摘要、工作台算力池汇总、
  用户用量流水与平台渠道分析；仅本域 notation 模块使用。
  """

  import Cgc2046Web.GraphqlSchema.LlmGateway.Helpers

  alias Cgc2046.LlmGateway.Ledger
  alias Cgc2046.Repo

  def build_wallet_summary(user_id) do
    wallet = Ledger.ensure_wallet!(user_id)
    now = DateTime.utc_now()

    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT id, source_type, initial_mc, remaining_mc, expires_at, status, inserted_at
        FROM llm_credit_grants
        WHERE wallet_id = $1
          AND status = 'active'
          AND remaining_mc > 0
          AND (expires_at IS NULL OR expires_at > $2)
        ORDER BY expires_at ASC NULLS LAST, inserted_at ASC
        """,
        [Ecto.UUID.dump!(wallet.id), now]
      )

    active_grants =
      Enum.map(rows, fn [
                          id,
                          source_type,
                          initial_mc,
                          remaining_mc,
                          expires_at,
                          status,
                          inserted_at
                        ] ->
        %{
          id: Ecto.UUID.load!(id),
          source_type: source_type,
          initial_mc: initial_mc,
          remaining_mc: remaining_mc,
          expires_at: to_utc_datetime(expires_at),
          status: status,
          inserted_at: to_utc_datetime(inserted_at)
        }
      end)

    unexpired_remaining_mc = Enum.sum(Enum.map(active_grants, & &1.remaining_mc))
    total_active_initial_mc = Enum.sum(Enum.map(active_grants, & &1.initial_mc))
    effective_balance_mc = min(unexpired_remaining_mc, wallet.cached_balance_mc)
    available_mc = max(effective_balance_mc - wallet.held_mc, 0)

    remaining_percentage =
      if total_active_initial_mc > 0 do
        div(effective_balance_mc * 100, total_active_initial_mc)
        |> max(0)
        |> min(100)
      else
        0
      end

    {:ok,
     %{
       wallet_id: wallet.id,
       cached_balance_mc: wallet.cached_balance_mc,
       held_mc: wallet.held_mc,
       available_mc: available_mc,
       max_concurrent_streams: wallet.max_concurrent_streams,
       status: wallet.status,
       frozen_reason: wallet.frozen_reason,
       remaining_percentage: remaining_percentage,
       active_grants: active_grants
     }}
  end

  def build_workspace_pool(workspace_id) do
    case Repo.query(
           """
           SELECT id, credit_pool_mc, updated_at
           FROM workspaces
           WHERE id = $1
           """,
           [Ecto.UUID.dump!(workspace_id)]
         ) do
      {:ok, %{rows: [[ws_id, credit_pool_mc, updated_at]]}} ->
        now = DateTime.utc_now()

        {dist_total, dist_consumed, dist_remaining} =
          workspace_distributed_totals(workspace_id, now)

        {:ok,
         %{
           workspace_id: Ecto.UUID.load!(ws_id),
           credit_pool_mc: credit_pool_mc,
           distributed_total_mc: dist_total,
           distributed_consumed_mc: dist_consumed,
           distributed_remaining_mc: dist_remaining,
           updated_at: to_utc_datetime(updated_at),
           recent_batches: workspace_recent_batches(workspace_id, now),
           recent_pool_entries: workspace_recent_pool_entries(workspace_id)
         }}

      _ ->
        {:error, ledger_error(:workspace_not_found)}
    end
  end

  defp workspace_recent_pool_entries(workspace_id) do
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT id, entry_type, delta_mc, payment_order_id, workspace_batch_id,
               actor_user_id, inserted_at
        FROM llm_workspace_pool_entries
        WHERE workspace_id = $1
        ORDER BY inserted_at DESC
        LIMIT 20
        """,
        [Ecto.UUID.dump!(workspace_id)]
      )

    Enum.map(rows, fn [
                        id,
                        entry_type,
                        delta_mc,
                        payment_order_id,
                        workspace_batch_id,
                        actor_user_id,
                        inserted_at
                      ] ->
      %{
        id: Ecto.UUID.load!(id),
        entry_type: entry_type,
        delta_mc: delta_mc,
        payment_order_id: maybe_load_uuid(payment_order_id),
        workspace_batch_id: maybe_load_uuid(workspace_batch_id),
        actor_user_id: maybe_load_uuid(actor_user_id),
        inserted_at: to_utc_datetime(inserted_at)
      }
    end)
  end

  defp maybe_load_uuid(nil), do: nil
  defp maybe_load_uuid(bin), do: Ecto.UUID.load!(bin)

  # 汇总本工作台通过派发批次发放出去的额度使用情况（仅按 sponsor_workspace_id 聚合，
  # 不暴露单个成员消耗）。不变量：consumed + remaining + expired == total。
  # expired_mc 持久化记录被 CreditExpiryWorker 归零的未用额度，加上已到期但尚
  # 未被 Worker 扫到的 remaining_mc，确保部分消费后过期仍保留历史 consumed。
  defp workspace_distributed_totals(workspace_id, now) do
    {:ok, %{rows: [[total_mc, consumed_mc, remaining_mc]]}} =
      Repo.query(
        """
        SELECT COALESCE(SUM(initial_mc), 0)::bigint AS total_mc,
               COALESCE(SUM(GREATEST(0, initial_mc - remaining_mc - expired_mc)), 0)::bigint AS consumed_mc,
               COALESCE(SUM(
                 CASE
                   WHEN status = 'active' AND (expires_at IS NULL OR expires_at > $2) THEN remaining_mc
                   ELSE 0
                 END
               ), 0)::bigint AS remaining_mc
        FROM llm_credit_grants
        WHERE sponsor_workspace_id = $1
        """,
        [Ecto.UUID.dump!(workspace_id), now]
      )

    {total_mc, consumed_mc, remaining_mc}
  end

  defp workspace_recent_batches(workspace_id, now) do
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT b.id, b.actor_user_id, b.per_member_mc, b.member_count, b.total_granted_mc,
               b.expires_at, b.idempotency_key, b.inserted_at,
               COALESCE(SUM(
                 CASE
                   WHEN g.id IS NULL THEN 0
                   ELSE GREATEST(0, g.initial_mc - g.remaining_mc - g.expired_mc)
                 END
               ), 0)::bigint AS consumed_mc,
               COALESCE(SUM(
                 CASE
                   WHEN g.id IS NULL THEN 0
                   WHEN g.status = 'active' AND (g.expires_at IS NULL OR g.expires_at > $2) THEN g.remaining_mc
                   ELSE 0
                 END
               ), 0)::bigint AS remaining_mc,
               COALESCE(SUM(
                 CASE
                   WHEN g.id IS NULL THEN 0
                   WHEN g.status = 'active' AND g.expires_at IS NOT NULL AND g.expires_at <= $2 THEN g.expired_mc + g.remaining_mc
                   ELSE g.expired_mc
                 END
               ), 0)::bigint AS expired_mc
        FROM llm_workspace_grant_batches b
        LEFT JOIN llm_credit_grants g ON g.workspace_batch_id = b.id
        WHERE b.workspace_id = $1
        GROUP BY b.id
        ORDER BY b.inserted_at DESC
        LIMIT 20
        """,
        [Ecto.UUID.dump!(workspace_id), now]
      )

    Enum.map(rows, fn [
                        id,
                        actor_user_id,
                        per_member_mc,
                        member_count,
                        total_granted_mc,
                        expires_at,
                        idempotency_key,
                        inserted_at,
                        consumed_mc,
                        remaining_mc,
                        expired_mc
                      ] ->
      %{
        id: Ecto.UUID.load!(id),
        actor_user_id: Ecto.UUID.load!(actor_user_id),
        per_member_mc: per_member_mc,
        member_count: member_count,
        total_granted_mc: total_granted_mc,
        consumed_mc: consumed_mc,
        remaining_mc: remaining_mc,
        expired_mc: expired_mc,
        expires_at: to_utc_datetime(expires_at),
        idempotency_key: idempotency_key,
        inserted_at: to_utc_datetime(inserted_at)
      }
    end)
  end

  def list_user_usage_logs(user_id, args) do
    limit = clamp_int(Map.get(args, :limit), 20, 1, 100)
    before = Map.get(args, :before)
    user_uuid = Ecto.UUID.dump!(user_id)

    {sql, params} =
      case before do
        %DateTime{} = cursor ->
          {"""
           SELECT id, session_id, logical_model, billing_mode,
                  prompt_cache_hit_tokens, prompt_cache_miss_tokens,
                  completion_tokens, reasoning_tokens, charged_mc,
                  ttfb_ms, duration_ms, inserted_at
           FROM llm_usage_logs
           WHERE user_id = $1 AND inserted_at < $2
           ORDER BY inserted_at DESC
           LIMIT $3
           """, [user_uuid, cursor, limit]}

        _ ->
          {"""
           SELECT id, session_id, logical_model, billing_mode,
                  prompt_cache_hit_tokens, prompt_cache_miss_tokens,
                  completion_tokens, reasoning_tokens, charged_mc,
                  ttfb_ms, duration_ms, inserted_at
           FROM llm_usage_logs
           WHERE user_id = $1
           ORDER BY inserted_at DESC
           LIMIT $2
           """, [user_uuid, limit]}
      end

    {:ok, %{rows: rows}} = Repo.query(sql, params)

    {:ok,
     Enum.map(rows, fn [
                         id,
                         session_id,
                         logical_model,
                         billing_mode,
                         prompt_cache_hit_tokens,
                         prompt_cache_miss_tokens,
                         completion_tokens,
                         reasoning_tokens,
                         charged_mc,
                         ttfb_ms,
                         duration_ms,
                         inserted_at
                       ] ->
       %{
         id: Ecto.UUID.load!(id),
         session_id: session_id,
         logical_model: logical_model,
         billing_mode: billing_mode,
         prompt_cache_hit_tokens: prompt_cache_hit_tokens,
         prompt_cache_miss_tokens: prompt_cache_miss_tokens,
         completion_tokens: completion_tokens,
         reasoning_tokens: reasoning_tokens,
         charged_mc: charged_mc,
         ttfb_ms: ttfb_ms,
         duration_ms: duration_ms,
         inserted_at: to_utc_datetime(inserted_at)
       }
     end)}
  end

  def list_admin_usage_analytics(args) do
    days = clamp_int(Map.get(args, :days), 14, 1, 90)
    since = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT to_char(inserted_at, 'YYYY-MM-DD') AS day,
               upstream_channel,
               COUNT(*)::int AS request_count,
               COUNT(*) FILTER (WHERE billing_mode = 'estimated_abort')::int AS aborted_count,
               COUNT(*) FILTER (WHERE billing_mode = 'waived_upstream_error')::int AS waived_count,
               COALESCE(SUM(prompt_cache_hit_tokens), 0)::bigint AS cache_hit_tokens,
               COALESCE(SUM(prompt_cache_miss_tokens), 0)::bigint AS cache_miss_tokens,
               COALESCE(SUM(completion_tokens), 0)::bigint AS completion_tokens,
               COALESCE(SUM(charged_mc), 0)::bigint AS total_charged_mc,
               COALESCE(SUM(upstream_cost_mc), 0)::bigint AS total_upstream_cost_mc
        FROM llm_usage_logs
        WHERE inserted_at >= $1
        GROUP BY to_char(inserted_at, 'YYYY-MM-DD'), upstream_channel
        ORDER BY day DESC, upstream_channel ASC
        """,
        [since]
      )

    {:ok,
     Enum.map(rows, fn [
                         day,
                         upstream_channel,
                         request_count,
                         aborted_count,
                         waived_count,
                         cache_hit_tokens,
                         cache_miss_tokens,
                         completion_tokens,
                         total_charged_mc,
                         total_upstream_cost_mc
                       ] ->
       %{
         day: day,
         upstream_channel: upstream_channel,
         request_count: request_count,
         aborted_count: aborted_count,
         waived_count: waived_count,
         cache_hit_tokens: cache_hit_tokens,
         cache_miss_tokens: cache_miss_tokens,
         completion_tokens: completion_tokens,
         total_charged_mc: total_charged_mc,
         total_upstream_cost_mc: total_upstream_cost_mc,
         gross_margin_mc: total_charged_mc - total_upstream_cost_mc
       }
     end)}
  end

  defp clamp_int(value, _default, min_val, max_val) when is_integer(value) do
    value |> max(min_val) |> min(max_val)
  end

  defp clamp_int(_value, default, _min_val, _max_val), do: default

  defp to_utc_datetime(nil), do: nil
  defp to_utc_datetime(%DateTime{} = dt), do: dt
  defp to_utc_datetime(%NaiveDateTime{} = dt), do: DateTime.from_naive!(dt, "Etc/UTC")
end
