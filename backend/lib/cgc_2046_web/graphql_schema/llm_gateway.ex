defmodule Cgc2046Web.GraphqlSchema.LlmGateway do
  @moduledoc """
  LLM Gateway 域 GraphQL 面：算力钱包摘要、工作台算力池查询/派发、
  算力收银台订单、用量流水与 PlatformAdmin 治理/分析面。
  类型在 `LlmGateway.Types`，投影在 `LlmGateway.Projections`，校验与错误映射在 `LlmGateway.Helpers`。
  """

  use Absinthe.Schema.Notation

  import_types(Cgc2046Web.GraphqlSchema.LlmGateway.Types)

  import Cgc2046Web.GraphqlSchema.Helpers
  import Cgc2046Web.GraphqlSchema.LlmGateway.Helpers
  import Cgc2046Web.GraphqlSchema.LlmGateway.Projections

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.Accounts.User
  alias Cgc2046.LlmGateway.Ledger
  alias Cgc2046.LlmGateway.PaymentOrders
  alias Cgc2046.Repo

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

    @desc "PlatformAdmin 冻结或解冻用户 LLM 额度账户（解冻清空 frozenReason）；与 AdminActionLog 同事务"
    field :admin_update_user_llm_wallet_status, :llm_wallet_summary do
      arg(:user_id, non_null(:id))
      arg(:status, non_null(:string))
      arg(:frozen_reason, :string)

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn actor ->
          with {:ok, user_id} <- cast_uuid(args.user_id) do
            case Ash.get(User, user_id, authorize?: false) do
              {:ok, nil} ->
                {:error, [message: "user not found", code: "user_not_found"]}

              {:ok, _user} ->
                update_admin_wallet_status(actor, user_id, args.status, args[:frozen_reason])

              {:error, _error} ->
                {:error, [message: "user not found", code: "user_not_found"]}
            end
          end
        end)
      end)
    end

    @desc "PlatformAdmin 调整用户 LLM 并发流上限（范围 1..20）；与 AdminActionLog 同事务"
    field :admin_update_user_llm_concurrency, :llm_wallet_summary do
      arg(:user_id, non_null(:id))
      arg(:max_concurrent_streams, non_null(:integer))

      resolve(fn _, args, %{context: context} ->
        with_admin(context, fn actor ->
          with {:ok, user_id} <- cast_uuid(args.user_id) do
            case Ash.get(User, user_id, authorize?: false) do
              {:ok, nil} ->
                {:error, [message: "user not found", code: "user_not_found"]}

              {:ok, _user} ->
                update_admin_wallet_concurrency(actor, user_id, args.max_concurrent_streams)

              {:error, _error} ->
                {:error, [message: "user not found", code: "user_not_found"]}
            end
          end
        end)
      end)
    end
  end

  defp update_admin_wallet_status(actor, user_id, status, frozen_reason) do
    case Repo.transaction(fn ->
           case Ledger.set_wallet_status(user_id, status, reason: frozen_reason) do
             {:ok, wallet} ->
               AdminActionLog.log!(%{
                 actor_id: actor.id,
                 action: :llm_wallet_status_update,
                 target_type: :user,
                 target_id: user_id,
                 metadata: %{
                   status: wallet.status,
                   frozen_reason: wallet.frozen_reason,
                   wallet_id: wallet.id
                 }
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

  defp update_admin_wallet_concurrency(actor, user_id, max_concurrent_streams) do
    case Repo.transaction(fn ->
           case Ledger.set_max_concurrent_streams(user_id, max_concurrent_streams) do
             {:ok, wallet} ->
               AdminActionLog.log!(%{
                 actor_id: actor.id,
                 action: :llm_wallet_concurrency_update,
                 target_type: :user,
                 target_id: user_id,
                 metadata: %{
                   max_concurrent_streams: wallet.max_concurrent_streams,
                   wallet_id: wallet.id
                 }
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
end
