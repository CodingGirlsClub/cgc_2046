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

  require Logger

  alias Cgc2046.Accounts.{MembershipContext, Role}
  alias Cgc2046.Repo

  @source_types ~w(subscription pack workspace_grant admin_gift)
  @billing_modes ~w(exact estimated_abort waived_upstream_error)
  @hold_ttl_seconds 7_200

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
    now = DateTime.utc_now()
    user_uuid = dump_uuid!(user_id)

    result =
      Repo.transaction(fn ->
        _wallet = ensure_wallet!(user_id)

        case Repo.query!(
               """
               SELECT id, status
               FROM llm_wallets
               WHERE user_id = $1
               FOR UPDATE
               """,
               [user_uuid]
             ).rows do
          [] ->
            Repo.rollback(:wallet_not_found)

          [[_wallet_id_bin, status]] when status != "active" ->
            {:error, :wallet_frozen}

          [[wallet_id_bin, "active"]] ->
            # 过期批次的 cached_balance 在 Worker 跑之前仍存在；先在钱包锁内收口，
            # 否则过期-only 钱包会被错误授权，结算时又因过期无法扣费 → 免费推理。
            {_expired_count, _expired_sum} = expire_wallet_grants!(wallet_id_bin, now)

            case Repo.query!(
                   """
                   UPDATE llm_wallets
                   SET held_mc = held_mc + $2, updated_at = $3
                   WHERE id = $1
                     AND status = 'active'
                     AND (cached_balance_mc - held_mc) >= $2
                   RETURNING id, cached_balance_mc, held_mc
                   """,
                   [wallet_id_bin, hold_mc, now]
                 ).rows do
              [[wallet_id, cached_balance_mc, held_mc]] ->
                hold_id = Ecto.UUID.generate()
                hold_expires_at = DateTime.add(now, @hold_ttl_seconds, :second)

                Repo.query!(
                  """
                  INSERT INTO llm_wallet_holds (
                    id, wallet_id, user_id, hold_mc, status, expires_at, inserted_at
                  )
                  VALUES ($1, $2, $3, $4, 'active', $5, $6)
                  """,
                  [dump_uuid!(hold_id), wallet_id_bin, user_uuid, hold_mc, hold_expires_at, now]
                )

                {:ok,
                 %{
                   wallet_id: Ecto.UUID.load!(wallet_id),
                   cached_balance_mc: cached_balance_mc,
                   held_mc: held_mc,
                   hold_id: hold_id
                 }}

              [] ->
                # 返回错误而非 rollback：保留上面的过期收口，避免余额缓存继续陈旧。
                {:error, :insufficient_quota}
            end
        end
      end)

    case result do
      {:ok, {:ok, wallet}} -> {:ok, wallet}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  流结束时结算：释放 hold、从最早到期批次扣费、更新钱包缓存并写用量账本。

  实际扣费上限为「余额减去其他并发 hold 占用的部分」，保证结算后仍满足
  `held_mc <= cached_balance_mc`；上游成本突增时宁可少扣，也不破坏账本不变量。
  """
  def settle_usage(user_id, hold_mc, usage_attrs, opts \\ [])
      when is_integer(hold_mc) and hold_mc >= 0 and is_map(usage_attrs) do
    charged_mc = usage_attrs |> Map.fetch!(:charged_mc) |> max(0)
    upstream_cost_mc = usage_attrs |> Map.fetch!(:upstream_cost_mc) |> max(0)
    billing_mode = usage_attrs |> Map.fetch!(:billing_mode) |> to_string()
    validate_billing_mode!(billing_mode)
    hold_id = Keyword.get(opts, :hold_id)

    tx_result =
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
            {hold_to_release_mc, hold_acquired_at} =
              case hold_id do
                nil ->
                  {min(hold_mc, current_held), nil}

                id ->
                  case Repo.query!(
                         """
                         DELETE FROM llm_wallet_holds
                         WHERE id = $1 AND wallet_id = $2
                         RETURNING hold_mc, inserted_at
                         """,
                         [dump_uuid!(id), wallet_id_bin]
                       ).rows do
                    [[held_mc, inserted_at]] -> {held_mc, inserted_at}
                    [] -> {0, nil}
                  end
              end

            # 不在此处收口过期 grants：在本次 hold 签发时尚未过期的批次仍可用于本次结算；
            # 签发时已经过期的批次（仅因更早的并发 hold 被保活）不得被本次请求扣用。
            available_mc = max(0, current_balance - max(0, current_held - hold_to_release_mc))
            actual_deduct_mc = min(charged_mc, available_mc)

            leftover_mc =
              deduct_from_grants_fifo!(wallet_id_bin, actual_deduct_mc, now,
                expired_budget_mc: hold_to_release_mc,
                hold_acquired_at: hold_acquired_at
              )

            actual_deduct_mc = actual_deduct_mc - leftover_mc
            uncollected_mc = max(0, charged_mc - actual_deduct_mc)

            Repo.query!(
              """
              UPDATE llm_wallets
              SET cached_balance_mc = GREATEST(0, cached_balance_mc - $2),
                  held_mc = GREATEST(0, held_mc - $3),
                  updated_at = $4
              WHERE id = $1
              """,
              [wallet_id_bin, actual_deduct_mc, hold_to_release_mc, now]
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

            {fetch_wallet!(user_id), actual_deduct_mc, uncollected_mc}
        end
      end)

    case tx_result do
      {:ok, {wallet, actual_deduct_mc, uncollected_mc}} ->
        if uncollected_mc > 0 do
          Logger.warning(
            "llm gateway settlement shortfall: user_id=#{user_id} billing_mode=#{billing_mode} " <>
              "charged_mc=#{charged_mc} actual_deduct_mc=#{actual_deduct_mc} uncollected_mc=#{uncollected_mc}"
          )

          :telemetry.execute(
            [:cgc2046, :llm_gateway, :settlement_shortfall],
            %{
              uncollected_mc: uncollected_mc,
              charged_mc: charged_mc,
              actual_deduct_mc: actual_deduct_mc
            },
            %{user_id: user_id, billing_mode: billing_mode}
          )
        end

        {:ok, wallet}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # 内部收口入口：调用方必须已持有目标 wallet 行锁（hold 准入或到期 Worker）。
  # 只过期「超出 held_mc 保留额」的批次：活跃请求的预授权额度即使中途到期，
  # 也要保留到结算，不能在这里被清零。
  def expire_wallet_grants!(wallet_id_bin, now) do
    preserve_mc =
      case Repo.query!(
             "SELECT held_mc FROM llm_wallets WHERE id = $1",
             [wallet_id_bin]
           ).rows do
        [[held_mc]] -> held_mc
        [] -> 0
      end

    %{rows: grants} =
      Repo.query!(
        """
        SELECT id, remaining_mc
        FROM llm_credit_grants
        WHERE wallet_id = $1
          AND status = 'active'
          AND remaining_mc > 0
          AND expires_at IS NOT NULL
          AND expires_at <= $2
        ORDER BY expires_at ASC, inserted_at ASC
        FOR UPDATE
        """,
        [wallet_id_bin, now]
      )

    expired_sum =
      Enum.reduce(grants, 0, fn [_grant_id_bin, remaining], acc -> acc + remaining end)

    to_expire_mc = max(0, expired_sum - preserve_mc)

    Enum.reduce_while(grants, to_expire_mc, fn [grant_id_bin, remaining], left ->
      if left <= 0 do
        {:halt, 0}
      else
        take = min(remaining, left)
        new_remaining = remaining - take
        new_status = if new_remaining == 0, do: "expired", else: "active"

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

    if to_expire_mc > 0 do
      Repo.query!(
        """
        UPDATE llm_wallets
        SET cached_balance_mc = GREATEST(0, cached_balance_mc - $2),
            updated_at = $3
        WHERE id = $1
        """,
        [wallet_id_bin, to_expire_mc, now]
      )
    end

    {length(grants), to_expire_mc}
  end

  defp deduct_from_grants_fifo!(_wallet_id_bin, 0, _now, _opts), do: 0

  defp deduct_from_grants_fifo!(wallet_id_bin, amount_to_deduct, now, opts)
       when amount_to_deduct > 0 do
    expired_budget_mc = max(0, Keyword.get(opts, :expired_budget_mc, 0))
    hold_acquired_at = Keyword.get(opts, :hold_acquired_at)

    %{rows: grants} =
      Repo.query!(
        """
        SELECT id, remaining_mc, expires_at, (expires_at IS NOT NULL AND expires_at <= $2) AS expired
        FROM llm_credit_grants
        WHERE wallet_id = $1
          AND status = 'active'
          AND remaining_mc > 0
        ORDER BY expires_at ASC NULLS LAST, inserted_at ASC
        FOR UPDATE
        """,
        [wallet_id_bin, now]
      )

    {leftover_mc, _expired_budget_mc} =
      Enum.reduce_while(
        grants,
        {amount_to_deduct, expired_budget_mc},
        fn [grant_id_bin, remaining, expires_at, expired], {left, budget} ->
          if left <= 0 do
            {:halt, {0, budget}}
          else
            take =
              cond do
                not expired ->
                  min(remaining, left)

                valid_at_hold_acquisition?(expires_at, hold_acquired_at) ->
                  min(remaining, min(left, budget))

                true ->
                  0
              end

            if take > 0 do
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

              next_budget = if expired, do: budget - take, else: budget
              {:cont, {left - take, next_budget}}
            else
              {:cont, {left, budget}}
            end
          end
        end
      )

    leftover_mc
  end

  defp valid_at_hold_acquisition?(_expires_at, nil), do: true

  defp valid_at_hold_acquisition?(%DateTime{} = exp, %DateTime{} = acquired_at),
    do: DateTime.compare(exp, acquired_at) == :gt

  defp valid_at_hold_acquisition?(%NaiveDateTime{} = exp, %NaiveDateTime{} = acquired_at),
    do: NaiveDateTime.compare(exp, acquired_at) == :gt

  defp valid_at_hold_acquisition?(%DateTime{} = exp, %NaiveDateTime{} = acquired_at),
    do: NaiveDateTime.compare(DateTime.to_naive(exp), acquired_at) == :gt

  defp valid_at_hold_acquisition?(%NaiveDateTime{} = exp, %DateTime{} = acquired_at),
    do: NaiveDateTime.compare(exp, DateTime.to_naive(acquired_at)) == :gt

  defp valid_at_hold_acquisition?(_, _), do: false

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

  @doc false
  # 工作台派发/充值的稳定错误码（GraphQL resolver 经此映射；AST 错误码契约
  # 扫描 `defp domain_error_code` 子句，新增/改名后必须重跑 generator）。
  def error_code(reason), do: domain_error_code(reason)

  defp domain_error_code(:insufficient_workspace_pool), do: "insufficient_workspace_pool"
  defp domain_error_code(:no_workspace_members), do: "no_workspace_members"
  defp domain_error_code(:workspace_not_found), do: "workspace_not_found"

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
