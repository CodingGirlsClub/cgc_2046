defmodule Cgc2046.LlmGateway.Ledger do
  @moduledoc """
  LLM Gateway 算力账本（Phase 1）。

  所有余额变动都收敛在本模块的裸 SQL 行锁路径，保证：

  - `cached_balance_mc >= 0`、`0 <= held_mc <= cached_balance_mc`；
  - 并发流式请求的预授权 hold 不会超卖（条件 UPDATE 原子判定）；
  - 结算按 `expires_at ASC NULLS LAST, inserted_at ASC` 从最早到期批次扣起；
  - 工作台批量派发以 `(workspace_id, idempotency_key)` 幂等，重复提交不二次扣池。

  资源层只读；任何调用方都不得绕过本模块直接改钱包/批次表。
  """

  alias Cgc2046.Accounts.{MembershipContext, Role}
  alias Cgc2046.Repo

  @source_types ~w(subscription pack workspace_grant admin_gift)
  @billing_modes ~w(exact estimated_abort waived_upstream_error)

  @doc """
  确保用户钱包存在并返回其快照（金额为微积分 / microcredit）。
  """
  def ensure_wallet!(user_id) do
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO llm_wallets (
        id, user_id, cached_balance_mc, held_mc, max_concurrent_streams, status,
        inserted_at, updated_at
      )
      VALUES (gen_random_uuid(), $1, 0, 0, 3, 'active', $2, $2)
      ON CONFLICT (user_id) DO NOTHING
      """,
      [dump_uuid!(user_id), now]
    )

    fetch_wallet!(user_id)
  end

  @doc """
  读取用户钱包快照；没有钱包时抛错（调用方必须先经过 `ensure_wallet!`）。
  """
  def fetch_wallet!(user_id) do
    case Repo.query!(
           """
           SELECT id, cached_balance_mc, held_mc, max_concurrent_streams, status
           FROM llm_wallets
           WHERE user_id = $1
           """,
           [dump_uuid!(user_id)]
         ).rows do
      [[id, cached_balance_mc, held_mc, max_concurrent_streams, status]] ->
        %{
          id: Ecto.UUID.load!(id),
          user_id: user_id,
          cached_balance_mc: cached_balance_mc,
          held_mc: held_mc,
          max_concurrent_streams: max_concurrent_streams,
          status: status
        }

      [] ->
        raise "llm wallet not found for user #{user_id}"
    end
  end

  @doc """
  给个人钱包入账（订阅、算力包、管理员赠送）。

  `payment_order_id` 非空时以部分唯一索引幂等：同一订单重复入账只记一次。
  """
  def grant_personal_credits(user_id, attrs) when is_map(attrs) do
    amount_mc = Map.fetch!(attrs, :amount_mc)
    source_type = attrs |> Map.fetch!(:source_type) |> to_string()
    expires_at = Map.get(attrs, :expires_at)
    payment_order_id = Map.get(attrs, :payment_order_id)
    sponsor_workspace_id = Map.get(attrs, :sponsor_workspace_id)
    granted_by_user_id = Map.get(attrs, :granted_by_user_id)

    if amount_mc <= 0, do: raise(ArgumentError, "amount_mc must be positive")
    validate_source_type!(source_type)

    Repo.transaction(fn ->
      wallet = ensure_wallet!(user_id)
      now = DateTime.utc_now()

      %{rows: inserted} =
        Repo.query!(
          """
          INSERT INTO llm_credit_grants (
            id, wallet_id, user_id, source_type, payment_order_id,
            sponsor_workspace_id, granted_by_user_id,
            initial_mc, remaining_mc, expires_at, status, inserted_at, updated_at
          )
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $8, $9, 'active', $10, $10)
          ON CONFLICT (payment_order_id) WHERE payment_order_id IS NOT NULL DO NOTHING
          RETURNING id
          """,
          [
            dump_uuid!(Ecto.UUID.generate()),
            dump_uuid!(wallet.id),
            dump_uuid!(user_id),
            source_type,
            maybe_dump_uuid(payment_order_id),
            maybe_dump_uuid(sponsor_workspace_id),
            maybe_dump_uuid(granted_by_user_id),
            amount_mc,
            expires_at,
            now
          ]
        )

      if inserted != [] do
        Repo.query!(
          """
          UPDATE llm_wallets
          SET cached_balance_mc = cached_balance_mc + $2, updated_at = $3
          WHERE id = $1
          """,
          [dump_uuid!(wallet.id), amount_mc, now]
        )
      end

      # 幂等冲突时重新读取，拿到已提交事务后的最新余额。
      fetch_wallet!(user_id)
    end)
  end

  @doc """
  给工作台算力池充值（订单结算或平台管理员操作）。
  """
  def topup_workspace_pool(workspace_id, amount_mc)
      when is_integer(amount_mc) and amount_mc > 0 do
    now = DateTime.utc_now()

    case Repo.query!(
           """
           UPDATE workspaces
           SET credit_pool_mc = credit_pool_mc + $2, updated_at = $3
           WHERE id = $1
           RETURNING credit_pool_mc
           """,
           [dump_uuid!(workspace_id), amount_mc, now]
         ).rows do
      [[new_pool_mc]] -> {:ok, new_pool_mc}
      [] -> {:error, :workspace_not_found}
    end
  end

  @doc """
  工作台 Owner/Admin 从工作台算力池向当前全部成员派发额度。

  额度进入成员个人钱包后可跨工作台消费。重复 `idempotency_key` 返回原批次，
  不二次扣池。
  """
  def batch_grant_workspace_members(
        actor,
        workspace_id,
        per_member_mc,
        idempotency_key,
        opts \\ []
      )
      when is_integer(per_member_mc) and per_member_mc > 0 and is_binary(idempotency_key) do
    expires_at = Keyword.get(opts, :expires_at)

    with :ok <- authorize_workspace_admin(actor, workspace_id) do
      Repo.transaction(fn ->
        now = DateTime.utc_now()
        ws_uuid = dump_uuid!(workspace_id)

        # 先锁工作台行：同一工作台的批量派发串行化，幂等重查在锁内完成，
        # 并发同 key 的第二个请求不会走进创建路径。
        case Repo.query!(
               "SELECT credit_pool_mc FROM workspaces WHERE id = $1 FOR UPDATE",
               [ws_uuid]
             ).rows do
          [] ->
            Repo.rollback(:workspace_not_found)

          [[current_pool_mc]] ->
            case fetch_batch(ws_uuid, idempotency_key) do
              {:ok, batch} ->
                batch

              :not_found ->
                member_ids = member_user_ids(workspace_id)
                member_count = length(member_ids)

                if member_count == 0 do
                  Repo.rollback(:no_workspace_members)
                end

                total_required_mc = member_count * per_member_mc

                if current_pool_mc < total_required_mc do
                  Repo.rollback(:insufficient_workspace_pool)
                end

                Repo.query!(
                  """
                  UPDATE workspaces
                  SET credit_pool_mc = credit_pool_mc - $2, updated_at = $3
                  WHERE id = $1
                  """,
                  [ws_uuid, total_required_mc, now]
                )

                batch_id = Ecto.UUID.generate()
                batch_uuid = dump_uuid!(batch_id)

                Repo.query!(
                  """
                  INSERT INTO llm_workspace_grant_batches (
                    id, workspace_id, actor_user_id, per_member_mc,
                    member_count, total_granted_mc, expires_at, idempotency_key, inserted_at
                  )
                  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
                  """,
                  [
                    batch_uuid,
                    ws_uuid,
                    dump_uuid!(actor.id),
                    per_member_mc,
                    member_count,
                    total_required_mc,
                    expires_at,
                    idempotency_key,
                    now
                  ]
                )

                Enum.each(member_ids, fn member_id ->
                  wallet = ensure_wallet!(member_id)

                  Repo.query!(
                    """
                    INSERT INTO llm_credit_grants (
                      id, wallet_id, user_id, source_type, workspace_batch_id,
                      sponsor_workspace_id, granted_by_user_id,
                      initial_mc, remaining_mc, expires_at, status, inserted_at, updated_at
                    )
                    VALUES (
                      gen_random_uuid(), $1, $2, 'workspace_grant', $3, $4, $5, $6, $6, $7,
                      'active', $8, $8
                    )
                    """,
                    [
                      dump_uuid!(wallet.id),
                      dump_uuid!(member_id),
                      batch_uuid,
                      ws_uuid,
                      dump_uuid!(actor.id),
                      per_member_mc,
                      expires_at,
                      now
                    ]
                  )

                  Repo.query!(
                    """
                    UPDATE llm_wallets
                    SET cached_balance_mc = cached_balance_mc + $2, updated_at = $3
                    WHERE id = $1
                    """,
                    [dump_uuid!(wallet.id), per_member_mc, now]
                  )
                end)

                %{
                  batch_id: batch_id,
                  member_count: member_count,
                  total_granted_mc: total_required_mc,
                  idempotent_replay?: false
                }
            end
        end
      end)
    end
  end

  @doc """
  流式请求开始前的原子预授权冻结。条件 UPDATE 同时校验钱包状态与可用余额，
  并发请求不会超卖。
  """
  def acquire_hold(user_id, hold_mc) when is_integer(hold_mc) and hold_mc > 0 do
    _wallet = ensure_wallet!(user_id)
    now = DateTime.utc_now()

    case Repo.query!(
           """
           UPDATE llm_wallets
           SET held_mc = held_mc + $2, updated_at = $3
           WHERE user_id = $1
             AND status = 'active'
             AND (cached_balance_mc - held_mc) >= $2
           RETURNING id, cached_balance_mc, held_mc
           """,
           [dump_uuid!(user_id), hold_mc, now]
         ).rows do
      [[wallet_id, cached_balance_mc, held_mc]] ->
        {:ok,
         %{
           wallet_id: Ecto.UUID.load!(wallet_id),
           cached_balance_mc: cached_balance_mc,
           held_mc: held_mc
         }}

      [] ->
        {:error, :insufficient_quota}
    end
  end

  @doc """
  流结束时结算：释放 hold、从最早到期批次扣费、更新钱包缓存并写用量账本。

  实际扣费上限为「余额减去其他并发 hold 占用的部分」，保证结算后仍满足
  `held_mc <= cached_balance_mc`；上游成本突增时宁可少扣，也不破坏账本不变量。
  """
  def settle_usage(user_id, hold_mc, usage_attrs)
      when is_integer(hold_mc) and hold_mc >= 0 and is_map(usage_attrs) do
    charged_mc = usage_attrs |> Map.fetch!(:charged_mc) |> max(0)
    upstream_cost_mc = usage_attrs |> Map.fetch!(:upstream_cost_mc) |> max(0)
    billing_mode = usage_attrs |> Map.fetch!(:billing_mode) |> to_string()
    validate_billing_mode!(billing_mode)

    Repo.transaction(fn ->
      now = DateTime.utc_now()
      user_uuid = dump_uuid!(user_id)

      case Repo.query!(
             """
             SELECT id, cached_balance_mc, held_mc
             FROM llm_wallets
             WHERE user_id = $1
             FOR UPDATE
             """,
             [user_uuid]
           ).rows do
        [] ->
          Repo.rollback(:wallet_not_found)

        [[wallet_id_bin, current_balance, current_held]] ->
          # 先就地收口已到期批次：否则过期额度仍计入 cached_balance，既能被
          # 本次结算消费，又会在 Worker 后续扣减时被二次扣除。
          {_expired_count, expired_sum} = expire_wallet_grants!(wallet_id_bin, now)

          balance_after_expiry = max(0, current_balance - expired_sum)
          held_after_expiry = min(current_held, balance_after_expiry)
          effective_hold_mc = min(hold_mc, held_after_expiry)

          available_mc =
            max(0, balance_after_expiry - max(0, held_after_expiry - effective_hold_mc))

          actual_deduct_mc = min(charged_mc, available_mc)

          deduct_from_grants_fifo!(wallet_id_bin, actual_deduct_mc, now)

          Repo.query!(
            """
            UPDATE llm_wallets
            SET cached_balance_mc = GREATEST(0, cached_balance_mc - $2),
                held_mc = GREATEST(0, held_mc - $3),
                updated_at = $4
            WHERE id = $1
            """,
            [wallet_id_bin, actual_deduct_mc, effective_hold_mc, now]
          )

          Repo.query!(
            """
            INSERT INTO llm_usage_logs (
              id, wallet_id, user_id, session_id, logical_model,
              upstream_channel, upstream_model, billing_mode,
              prompt_cache_hit_tokens, prompt_cache_miss_tokens,
              completion_tokens, reasoning_tokens,
              charged_mc, upstream_cost_mc, ttfb_ms, duration_ms, inserted_at
            )
            VALUES (
              gen_random_uuid(), $1, $2, $3, $4,
              $5, $6, $7,
              $8, $9,
              $10, $11,
              $12, $13, $14, $15, $16
            )
            """,
            [
              wallet_id_bin,
              user_uuid,
              Map.get(usage_attrs, :session_id),
              Map.fetch!(usage_attrs, :logical_model),
              Map.fetch!(usage_attrs, :upstream_channel),
              Map.fetch!(usage_attrs, :upstream_model),
              billing_mode,
              Map.get(usage_attrs, :prompt_cache_hit_tokens, 0),
              Map.get(usage_attrs, :prompt_cache_miss_tokens, 0),
              Map.get(usage_attrs, :completion_tokens, 0),
              Map.get(usage_attrs, :reasoning_tokens, 0),
              actual_deduct_mc,
              upstream_cost_mc,
              Map.get(usage_attrs, :ttfb_ms),
              Map.get(usage_attrs, :duration_ms),
              now
            ]
          )

          fetch_wallet!(user_id)
      end
    end)
  end

  @doc false
  # 内部收口入口：调用方必须已持有目标 wallet 行锁（结算事务或到期 Worker）。
  # 锁定顺序固定为 wallet → grants，与 `deduct_from_grants_fifo!/3` 同序，
  # 避免与 Worker 的 wallet 更新形成死锁。
  def expire_wallet_grants!(wallet_id_bin, now) do
    %{rows: grants} =
      Repo.query!(
        """
        SELECT id, remaining_mc
        FROM llm_credit_grants
        WHERE wallet_id = $1
          AND status = 'active'
          AND expires_at IS NOT NULL
          AND expires_at <= $2
        FOR UPDATE
        """,
        [wallet_id_bin, now]
      )

    expired_sum =
      Enum.reduce(grants, 0, fn [_grant_id_bin, remaining], acc -> acc + remaining end)

    Enum.each(grants, fn [grant_id_bin, _remaining] ->
      Repo.query!(
        """
        UPDATE llm_credit_grants
        SET remaining_mc = 0, status = 'expired', updated_at = $2
        WHERE id = $1
        """,
        [grant_id_bin, now]
      )
    end)

    if expired_sum > 0 do
      Repo.query!(
        """
        UPDATE llm_wallets
        SET cached_balance_mc = GREATEST(0, cached_balance_mc - $2),
            held_mc = LEAST(held_mc, GREATEST(0, cached_balance_mc - $2)),
            updated_at = $3
        WHERE id = $1
        """,
        [wallet_id_bin, expired_sum, now]
      )
    end

    {length(grants), expired_sum}
  end

  defp deduct_from_grants_fifo!(_wallet_id_bin, 0, _now), do: :ok

  defp deduct_from_grants_fifo!(wallet_id_bin, amount_to_deduct, now)
       when amount_to_deduct > 0 do
    %{rows: grants} =
      Repo.query!(
        """
        SELECT id, remaining_mc
        FROM llm_credit_grants
        WHERE wallet_id = $1
          AND status = 'active'
          AND remaining_mc > 0
          AND (expires_at IS NULL OR expires_at > $2)
        ORDER BY expires_at ASC NULLS LAST, inserted_at ASC
        FOR UPDATE
        """,
        [wallet_id_bin, now]
      )

    Enum.reduce_while(grants, amount_to_deduct, fn [grant_id_bin, remaining], left ->
      if left <= 0 do
        {:halt, 0}
      else
        take = min(remaining, left)
        new_remaining = remaining - take
        new_status = if new_remaining == 0, do: "exhausted", else: "active"

        Repo.query!(
          """
          UPDATE llm_credit_grants
          SET remaining_mc = $2, status = $3, updated_at = $4
          WHERE id = $1
          """,
          [grant_id_bin, new_remaining, new_status, now]
        )

        {:cont, left - take}
      end
    end)

    :ok
  end

  defp fetch_batch(ws_uuid, idempotency_key) do
    case Repo.query!(
           """
           SELECT id, member_count, total_granted_mc
           FROM llm_workspace_grant_batches
           WHERE workspace_id = $1 AND idempotency_key = $2
           """,
           [ws_uuid, idempotency_key]
         ).rows do
      [[batch_id, member_count, total_granted_mc]] ->
        {:ok,
         %{
           batch_id: Ecto.UUID.load!(batch_id),
           member_count: member_count,
           total_granted_mc: total_granted_mc,
           idempotent_replay?: true
         }}

      [] ->
        :not_found
    end
  end

  defp member_user_ids(workspace_id) do
    Repo.query!(
      """
      SELECT user_id
      FROM workspace_memberships
      WHERE workspace_id = $1
      ORDER BY user_id
      """,
      [dump_uuid!(workspace_id)]
    ).rows
    |> Enum.map(fn [user_id] -> Ecto.UUID.load!(user_id) end)
    |> Enum.uniq()
  end

  defp authorize_workspace_admin(%{is_platform_admin: true}, _workspace_id), do: :ok

  defp authorize_workspace_admin(%{id: user_id}, workspace_id) when is_binary(user_id) do
    if %{id: user_id}
       |> MembershipContext.role_names(workspace_id)
       |> Enum.any?(&Role.manage_role?/1) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp authorize_workspace_admin(_, _), do: {:error, :forbidden}

  defp validate_source_type!(source_type) when source_type in @source_types, do: :ok

  defp validate_source_type!(source_type) do
    raise ArgumentError, "unknown source_type #{inspect(source_type)}"
  end

  defp validate_billing_mode!(billing_mode) when billing_mode in @billing_modes, do: :ok

  defp validate_billing_mode!(billing_mode) do
    raise ArgumentError, "unknown billing_mode #{inspect(billing_mode)}"
  end

  defp dump_uuid!(uuid) when is_binary(uuid), do: Ecto.UUID.dump!(uuid)

  defp maybe_dump_uuid(nil), do: nil
  defp maybe_dump_uuid(uuid), do: dump_uuid!(uuid)
end
