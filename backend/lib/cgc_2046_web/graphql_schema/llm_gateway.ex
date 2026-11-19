defmodule Cgc2046Web.GraphqlSchema.LlmGateway do
  @moduledoc """
  LLM Gateway 读面、管理面与独立收银台 GraphQL 面（Phase 3A/3B）。

  记账、并发 hold、FIFO 扣费全部收敛在 `Cgc2046.LlmGateway.Ledger`（Phase 1）；
  本模块只做鉴权、输入校验、金额单位换算与读模型投影，不直接写钱包/批次表。
  收银台创单/凭据由 `Cgc2046.LlmGateway.PaymentOrders` 负责，回调落账由
  `Cgc2046.LlmGateway.Workers.LlmPaymentSettlementWorker` 负责。

  - 个人读面：`myLlmWallet`（钱包 + 活跃授信批次 + 剩余额度百分比）
  - 工作台读面：`workspaceLlmPool`（Owner/Admin 或 PlatformAdmin）
  - 收银台：`createLlmPaymentOrder` / `llmPaymentOrder`（独立
    `llm_payment_orders`，`LLM_` 回调前缀）
  - 工作台派发：`distributeWorkspaceLlmCredits`（Owner/Admin；Ledger 按
    `(workspace_id, idempotency_key)` 幂等）
  - 平台管理：`adminTopupWorkspaceLlmPool` / `adminGrantUserLlmCredits`
    （PlatformAdmin；金额写操作与 AdminActionLog 同事务，失败回滚）
  """

  use Absinthe.Schema.Notation

  import Cgc2046Web.GraphqlSchema.Helpers

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Accounts.Policies.PlatformAdmin
  alias Cgc2046.Accounts.Role
  alias Cgc2046.Accounts.User
  alias Cgc2046.LlmGateway.Ledger
  alias Cgc2046.LlmGateway.PaymentOrders
  alias Cgc2046.Repo

  @min_int64 -9_223_372_036_854_775_808
  @max_int64 9_223_372_036_854_775_807

  @desc "Signed 64-bit integer (microcredits). Accepts integer or numeric string; serializes as JSON integer."
  scalar :bigint, name: "BigInt" do
    parse(&__MODULE__.parse_bigint/1)
    serialize(&__MODULE__.serialize_bigint/1)
  end

  @doc false
  def parse_bigint(%Absinthe.Blueprint.Input.Integer{value: value}), do: coerce_bigint(value)
  def parse_bigint(%Absinthe.Blueprint.Input.String{value: value}), do: coerce_bigint(value)
  def parse_bigint(%Absinthe.Blueprint.Input.Null{}), do: {:ok, nil}
  def parse_bigint(value) when is_integer(value) or is_binary(value), do: coerce_bigint(value)
  def parse_bigint(_other), do: :error

  @doc false
  def serialize_bigint(value)
      when is_integer(value) and value >= @min_int64 and value <= @max_int64 do
    value
  end

  def serialize_bigint(value) do
    raise Absinthe.SerializationError, "Value #{inspect(value)} is not a valid BigInt."
  end

  defp coerce_bigint(value)
       when is_integer(value) and value >= @min_int64 and value <= @max_int64 do
    {:ok, value}
  end

  defp coerce_bigint(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= @min_int64 and int <= @max_int64 -> {:ok, int}
      _ -> :error
    end
  end

  defp coerce_bigint(_value), do: :error

  @desc "LLM 钱包内一笔活跃授信（订阅/算力包/工作台派发/管理员赠送）"
  object :llm_credit_grant_item do
    field(:id, non_null(:id))

    field(:source_type, non_null(:string),
      description: "subscription | pack | workspace_grant | admin_gift"
    )

    field(:initial_mc, non_null(:bigint), description: "发放额度（微积分）")
    field(:remaining_mc, non_null(:bigint), description: "当前剩余额度（微积分）")
    field(:expires_at, :datetime)
    field(:status, non_null(:string), description: "active | exhausted | expired")
    field(:inserted_at, non_null(:datetime))
  end

  @desc "当前用户 LLM 钱包摘要；金额均为微积分（1 CNY = 1,000,000 mc）"
  object :llm_wallet_summary do
    field(:wallet_id, non_null(:id))
    field(:cached_balance_mc, non_null(:bigint), description: "缓存总余额（含冻结）")
    field(:held_mc, non_null(:bigint), description: "在途流式请求冻结额度")
    field(:available_mc, non_null(:bigint), description: "可用额度（未过期授信与缓存余额取小后扣除冻结）")
    field(:max_concurrent_streams, non_null(:integer))
    field(:status, non_null(:string), description: "active | frozen")
    field(:remaining_percentage, non_null(:integer), description: "活跃授信剩余百分比 0-100")
    field(:active_grants, non_null(list_of(non_null(:llm_credit_grant_item))))
  end

  @desc "工作台算力池与最近派发批次"
  object :llm_workspace_pool_summary do
    field(:workspace_id, non_null(:id))
    field(:credit_pool_mc, non_null(:bigint), description: "待派发池余额（微积分）")
    field(:updated_at, non_null(:datetime))
    field(:recent_batches, non_null(list_of(non_null(:llm_workspace_grant_batch))))
    field(:recent_pool_entries, non_null(list_of(non_null(:llm_workspace_pool_entry))))
  end

  @desc "工作台算力池追加账本流水行"
  object :llm_workspace_pool_entry do
    field(:id, non_null(:id))

    field(:entry_type, non_null(:string),
      description: "order_topup | admin_topup | batch_grant_debit | migration_baseline"
    )

    field(:delta_mc, non_null(:bigint), description: "变动微积分（充值正数，派发负数）")
    field(:payment_order_id, :id)
    field(:workspace_batch_id, :id)
    field(:actor_user_id, :id)
    field(:inserted_at, non_null(:datetime))
  end

  @desc "工作台批量派发审计行"
  object :llm_workspace_grant_batch do
    field(:id, non_null(:id))
    field(:actor_user_id, non_null(:id))
    field(:per_member_mc, non_null(:bigint))
    field(:member_count, non_null(:integer))
    field(:total_granted_mc, non_null(:bigint))
    field(:expires_at, :datetime)
    field(:idempotency_key, non_null(:string))
    field(:inserted_at, non_null(:datetime))
  end

  @desc "工作台批量派发结果；idempotentReplay=true 表示命中同 key 原批次、未二次扣池"
  object :llm_workspace_grant_result do
    field(:id, non_null(:id))
    field(:per_member_mc, non_null(:bigint))
    field(:member_count, non_null(:integer))
    field(:total_granted_mc, non_null(:bigint))
    field(:idempotent_replay, non_null(:boolean))
  end

  @desc "LLM 算力收银台订单（独立于报名支付 payments_orders）"
  object :llm_payment_order do
    field(:id, non_null(:id))
    field(:user_id, non_null(:id), description: "购买人/钱包入账用户")
    field(:workspace_id, :id, description: "工作台池充值目标；个人订单为空")

    field(:order_kind, non_null(:string),
      description: "llm_subscription | llm_credit_pack | llm_workspace_pool_topup"
    )

    field(:provider, non_null(:string), description: "wechat_native | alipay_qr")

    field(:out_trade_no, non_null(:string))
    field(:amount_cents, non_null(:integer), description: "实付金额（分）")
    field(:credits_mc, non_null(:bigint), description: "入账算力（微积分；1 cent = 10,000 mc）")
    field(:status, non_null(:string), description: "pending | paid | cancelled | expired")
    field(:expires_at, :datetime)
    field(:paid_at, :datetime)
    field(:inserted_at, non_null(:datetime))
  end

  @desc "创单结果：订单快照 + 渠道凭据（二维码/跳转参数）"
  object :llm_payment_checkout do
    field(:order, non_null(:llm_payment_order))
    field(:credential, :json, description: "渠道凭据；幂等重放原样返回")
  end

  @desc "当前用户单条 LLM 调用用量流水（不含上游渠道与上游成本）"
  object :llm_usage_log_item do
    field(:id, non_null(:id))
    field(:session_id, :string)
    field(:logical_model, non_null(:string))
    field(:billing_mode, non_null(:string))
    field(:prompt_cache_hit_tokens, non_null(:bigint))
    field(:prompt_cache_miss_tokens, non_null(:bigint))
    field(:completion_tokens, non_null(:bigint))
    field(:reasoning_tokens, non_null(:bigint))
    field(:charged_mc, non_null(:bigint))
    field(:ttfb_ms, :integer)
    field(:duration_ms, :integer)
    field(:inserted_at, non_null(:datetime))
  end

  @desc "平台管理面按日 × 上游渠道聚合的 LLM 营收与成本指标（UTC 日期）"
  object :llm_daily_channel_metric do
    field(:day, non_null(:string))
    field(:upstream_channel, non_null(:string))
    field(:request_count, non_null(:integer))
    field(:aborted_count, non_null(:integer))
    field(:waived_count, non_null(:integer))
    field(:cache_hit_tokens, non_null(:bigint))
    field(:cache_miss_tokens, non_null(:bigint))
    field(:completion_tokens, non_null(:bigint))
    field(:total_charged_mc, non_null(:bigint))
    field(:total_upstream_cost_mc, non_null(:bigint))
    field(:gross_margin_mc, non_null(:bigint))
  end

  object :llm_gateway_queries do
    @desc "当前用户/购买人读取单笔 LLM 收银台订单"
    field :llm_payment_order, :llm_payment_order do
      arg(:id, non_null(:id))

      resolve(fn _, %{id: id}, %{context: context} ->
        with_actor(context, fn actor ->
          case PaymentOrders.get_for_actor(actor, id) do
            {:ok, order} -> {:ok, order}
            {:error, :not_found} -> {:error, payment_order_error(:not_found)}
          end
        end)
      end)
    end

    @desc "当前用户 LLM 钱包（含活跃授信批次）；未登录 unauthorized"
    field :my_llm_wallet, :llm_wallet_summary do
      resolve(fn _, _, %{context: context} ->
        with_actor(context, fn actor -> build_wallet_summary(actor.id) end)
      end)
    end

    @desc "当前用户 LLM 调用用量流水（按 insertedAt 倒序分页，limit 默认 20、范围 1..100）"
    field :my_llm_usage_logs, non_null(list_of(non_null(:llm_usage_log_item))) do
      arg(:limit, :integer)
      arg(:before, :datetime)

      resolve(fn _, args, %{context: context} ->
        with_actor(context, fn actor -> list_user_usage_logs(actor.id, args) end)
      end)
    end

    @desc "PlatformAdmin 按日 × 上游渠道聚合的 LLM 营收、成本与毛利指标（days 默认 14、范围 1..90）"
    field :admin_llm_usage_analytics, non_null(list_of(non_null(:llm_daily_channel_metric))) do
      arg(:days, :integer)

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn _actor -> list_admin_usage_analytics(args) end)
      end)
    end

    @desc "工作台算力池与最近派发记录（Owner/Admin；PlatformAdmin 跨租户可读）"
    field :workspace_llm_pool, :llm_workspace_pool_summary do
      arg(:workspace_id, non_null(:id))

      resolve(fn _, %{workspace_id: workspace_id}, %{context: context} ->
        with_actor(context, fn actor ->
          with {:ok, ws_id} <- cast_uuid(workspace_id) do
            with_workspace_admin(actor, ws_id, fn -> build_workspace_pool(ws_id) end)
          end
        end)
      end)
    end
  end

  object :llm_gateway_mutations do
    @desc "创建 LLM 算力收银台订单并返回渠道凭据；同 idempotencyKey 返回原单"
    field :create_llm_payment_order, :llm_payment_checkout do
      arg(:order_kind, non_null(:string))
      arg(:provider, non_null(:string))
      arg(:amount_cents, non_null(:integer))
      arg(:workspace_id, :id)
      arg(:idempotency_key, non_null(:string))

      resolve(fn _, args, %{context: context} ->
        with_actor(context, fn actor ->
          case PaymentOrders.create(actor, %{
                 order_kind: args.order_kind,
                 provider: args.provider,
                 amount_cents: args.amount_cents,
                 workspace_id: args[:workspace_id],
                 idempotency_key: args.idempotency_key
               }) do
            {:ok, order} ->
              {:ok, %{order: order, credential: order.credential}}

            {:error, reason} ->
              {:error, payment_order_error(reason)}
          end
        end)
      end)
    end

    @desc "工作台 Owner/Admin 从算力池向目标成员（默认全部，可按成员 ID/角色筛选）派发额度；同 idempotencyKey 幂等"
    field :distribute_workspace_llm_credits, :llm_workspace_grant_result do
      arg(:workspace_id, non_null(:id))
      arg(:per_member_mc, non_null(:bigint))
      arg(:idempotency_key, non_null(:string))
      arg(:expires_at, :datetime)
      arg(:target_user_ids, list_of(non_null(:id)))
      arg(:target_roles, list_of(non_null(:string)))

      resolve(fn _, args, %{context: context} ->
        with_actor(context, fn actor ->
          with {:ok, ws_id} <- cast_uuid(args.workspace_id),
               {:ok, per_member_mc} <- positive_integer(args.per_member_mc),
               {:ok, idempotency_key} <- nonempty_string(args.idempotency_key) do
            case Ledger.batch_grant_workspace_members(
                   actor,
                   ws_id,
                   per_member_mc,
                   idempotency_key,
                   expires_at: args[:expires_at],
                   target_user_ids: args[:target_user_ids],
                   target_roles: args[:target_roles]
                 ) do
              {:ok, batch} ->
                {:ok,
                 %{
                   id: batch.batch_id,
                   per_member_mc: per_member_mc,
                   member_count: batch.member_count,
                   total_granted_mc: batch.total_granted_mc,
                   idempotent_replay: batch.idempotent_replay?
                 }}

              {:error, reason} ->
                {:error, ledger_error(reason)}
            end
          end
        end)
      end)
    end

    @desc "PlatformAdmin 向工作台算力池充值；与 AdminActionLog 同事务"
    field :admin_topup_workspace_llm_pool, :llm_workspace_pool_summary do
      arg(:workspace_id, non_null(:id))
      arg(:amount_mc, non_null(:bigint))

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn actor ->
          with {:ok, ws_id} <- cast_uuid(args.workspace_id),
               {:ok, amount_mc} <- positive_integer(args.amount_mc) do
            case Repo.transaction(fn ->
                   case Ledger.topup_workspace_pool(ws_id, amount_mc,
                          entry_type: :admin_topup,
                          actor_user_id: actor.id
                        ) do
                     {:ok, new_pool_mc} ->
                       AdminActionLog.log!(%{
                         actor_id: actor.id,
                         action: :llm_workspace_topup,
                         target_type: :workspace,
                         target_id: ws_id,
                         metadata: %{amount_mc: amount_mc, new_pool_mc: new_pool_mc}
                       })

                       new_pool_mc

                     {:error, reason} ->
                       Repo.rollback(reason)
                   end
                 end) do
              {:ok, _new_pool_mc} -> build_workspace_pool(ws_id)
              {:error, reason} -> {:error, ledger_error(reason)}
            end
          end
        end)
      end)
    end

    @desc "PlatformAdmin 向个人钱包赠予算力（source=admin_gift）；与 AdminActionLog 同事务"
    field :admin_grant_user_llm_credits, :llm_wallet_summary do
      arg(:user_id, non_null(:id))
      arg(:amount_mc, non_null(:bigint))
      arg(:expires_at, :datetime)

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn actor ->
          with {:ok, user_id} <- cast_uuid(args.user_id),
               {:ok, amount_mc} <- positive_integer(args.amount_mc) do
            case Ash.get(User, user_id, authorize?: false) do
              {:ok, nil} ->
                {:error, [message: "user not found", code: "user_not_found"]}

              {:ok, _user} ->
                grant_admin_credits(actor, user_id, amount_mc, args[:expires_at])

              {:error, _error} ->
                {:error, [message: "user not found", code: "user_not_found"]}
            end
          end
        end)
      end)
    end
  end

  defp grant_admin_credits(actor, user_id, amount_mc, expires_at) do
    case Repo.transaction(fn ->
           case Ledger.grant_personal_credits(user_id, %{
                  amount_mc: amount_mc,
                  source_type: :admin_gift,
                  expires_at: expires_at,
                  granted_by_user_id: actor.id
                }) do
             {:ok, wallet} ->
               AdminActionLog.log!(%{
                 actor_id: actor.id,
                 action: :llm_user_credit_grant,
                 target_type: :user,
                 target_id: user_id,
                 metadata: %{amount_mc: amount_mc, wallet_id: wallet.id}
               })

               wallet

             {:error, reason} ->
               Repo.rollback(reason)
           end
         end) do
      {:ok, _wallet} -> build_wallet_summary(user_id)
      {:error, reason} -> {:error, ledger_error(reason)}
    end
  end

  defp build_wallet_summary(user_id) do
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
          expires_at: expires_at,
          status: status,
          inserted_at: inserted_at
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
       remaining_percentage: remaining_percentage,
       active_grants: active_grants
     }}
  end

  defp build_workspace_pool(workspace_id) do
    case Repo.query(
           """
           SELECT id, credit_pool_mc, updated_at
           FROM workspaces
           WHERE id = $1
           """,
           [Ecto.UUID.dump!(workspace_id)]
         ) do
      {:ok, %{rows: [[ws_id, credit_pool_mc, updated_at]]}} ->
        {:ok,
         %{
           workspace_id: Ecto.UUID.load!(ws_id),
           credit_pool_mc: credit_pool_mc,
           updated_at: to_utc_datetime(updated_at),
           recent_batches: workspace_recent_batches(workspace_id),
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

  defp workspace_recent_batches(workspace_id) do
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT id, actor_user_id, per_member_mc, member_count, total_granted_mc,
               expires_at, idempotency_key, inserted_at
        FROM llm_workspace_grant_batches
        WHERE workspace_id = $1
        ORDER BY inserted_at DESC
        LIMIT 20
        """,
        [Ecto.UUID.dump!(workspace_id)]
      )

    Enum.map(rows, fn [
                        id,
                        actor_user_id,
                        per_member_mc,
                        member_count,
                        total_granted_mc,
                        expires_at,
                        idempotency_key,
                        inserted_at
                      ] ->
      %{
        id: Ecto.UUID.load!(id),
        actor_user_id: Ecto.UUID.load!(actor_user_id),
        per_member_mc: per_member_mc,
        member_count: member_count,
        total_granted_mc: total_granted_mc,
        expires_at: expires_at,
        idempotency_key: idempotency_key,
        inserted_at: inserted_at
      }
    end)
  end

  defp list_user_usage_logs(user_id, args) do
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

  defp list_admin_usage_analytics(args) do
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

  defp to_utc_datetime(%DateTime{} = dt), do: dt
  defp to_utc_datetime(%NaiveDateTime{} = dt), do: DateTime.from_naive!(dt, "Etc/UTC")

  defp with_workspace_admin(actor, workspace_id, fun) do
    cond do
      PlatformAdmin.platform_admin?(actor) ->
        fun.()

      actor
      |> MembershipContext.role_names(workspace_id)
      |> Enum.any?(&Role.manage_role?/1) ->
        fun.()

      true ->
        {:error, [message: "forbidden", code: "forbidden"]}
    end
  end

  defp payment_order_error(reason) do
    message =
      case reason do
        :invalid_kind -> "不支持的算力订单类型"
        :invalid_provider -> "不支持的支付渠道"
        :invalid_amount -> "金额必须为正整数（分）"
        :invalid_workspace -> "工作台参数无效"
        :invalid_idempotency_key -> "幂等键不能为空或过长"
        :workspace_required -> "工作台池充值必须指定工作台"
        :forbidden -> "只有工作台 Owner/Admin 可以充值该工作台"
        :provider_failed -> "支付渠道下单失败，请稍后重试"
        :idempotency_conflict -> "订单创建冲突，请重试"
        :not_found -> "订单不存在"
        :database_error -> "订单写入失败，请重试"
      end

    [message: message, code: PaymentOrders.error_code(reason)]
  end

  defp ledger_error(:forbidden), do: [message: "forbidden", code: "forbidden"]

  defp ledger_error(:insufficient_workspace_pool) do
    [message: "工作台算力池余额不足", code: Ledger.error_code(:insufficient_workspace_pool)]
  end

  defp ledger_error(:no_workspace_members) do
    [message: "工作台没有可派发成员", code: Ledger.error_code(:no_workspace_members)]
  end

  defp ledger_error(:workspace_not_found) do
    [message: "工作台不存在", code: Ledger.error_code(:workspace_not_found)]
  end

  defp ledger_error(:invalid_target_members) do
    [message: "包含非本工作台成员，无法派发", code: Ledger.error_code(:invalid_target_members)]
  end

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, [message: "invalid id", code: "invalid_id"]}
    end
  end

  defp cast_uuid(_value), do: {:error, [message: "invalid id", code: "invalid_id"]}

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(_value),
    do: {:error, [message: "amount_mc must be positive", code: "invalid_amount"]}

  defp nonempty_string(value) when is_binary(value) do
    if String.trim(value) == "" do
      {:error, [message: "idempotency_key must not be blank", code: "invalid_idempotency_key"]}
    else
      {:ok, value}
    end
  end

  defp nonempty_string(_value),
    do: {:error, [message: "idempotency_key must not be blank", code: "invalid_idempotency_key"]}
end
