defmodule Cgc2046Web.GraphqlSchema.LlmGateway.Types do
  @moduledoc """
  LLM Gateway 域 GraphQL 类型（BigInt scalar 与钱包/池/订单/流水/分析投影）；
  仅本域 notation 模块 `import_types` 使用。
  """

  use Absinthe.Schema.Notation

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
    field(:frozen_reason, :string, description: "账户冻结原因（仅冻结且管理员填写时非空）")
    field(:remaining_percentage, non_null(:integer), description: "活跃授信剩余百分比 0-100")
    field(:active_grants, non_null(list_of(non_null(:llm_credit_grant_item))))
  end

  @desc "工作台算力池与最近派发批次"
  object :llm_workspace_pool_summary do
    field(:workspace_id, non_null(:id))
    field(:credit_pool_mc, non_null(:bigint), description: "待派发池余额（微积分）")
    field(:distributed_total_mc, non_null(:bigint), description: "累计已派发给成员的额度总额（微积分）")
    field(:distributed_consumed_mc, non_null(:bigint), description: "已派发额度中累计已消耗金额（微积分）")
    field(:distributed_remaining_mc, non_null(:bigint), description: "已派发额度中当前尚未到期且未消耗的余额（微积分）")
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
    field(:consumed_mc, non_null(:bigint), description: "该批次汇总已消耗额度（微积分）")
    field(:remaining_mc, non_null(:bigint), description: "该批次当前未到期剩余额度（微积分）")
    field(:expired_mc, non_null(:bigint), description: "该批次已过期未用额度（微积分）")
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
end
