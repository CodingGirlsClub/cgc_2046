defmodule Cgc2046Web.GraphqlSchema.LlmGateway.Helpers do
  @moduledoc """
  LLM Gateway 域内校验、权限门控与错误码映射 helper；仅本域 notation 与 projections 使用。
  """

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Accounts.Policies.PlatformAdmin
  alias Cgc2046.Accounts.Role
  alias Cgc2046.LlmGateway.Ledger
  alias Cgc2046.LlmGateway.PaymentOrders

  def with_workspace_admin(actor, workspace_id, fun) do
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

  def payment_order_error(reason) do
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

  def ledger_error(:forbidden), do: [message: "forbidden", code: "forbidden"]

  def ledger_error(:insufficient_workspace_pool) do
    [message: "工作台算力池余额不足", code: Ledger.error_code(:insufficient_workspace_pool)]
  end

  def ledger_error(:no_workspace_members) do
    [message: "工作台没有可派发成员", code: Ledger.error_code(:no_workspace_members)]
  end

  def ledger_error(:workspace_not_found) do
    [message: "工作台不存在", code: Ledger.error_code(:workspace_not_found)]
  end

  def ledger_error(:invalid_target_members) do
    [message: "包含非本工作台成员，无法派发", code: Ledger.error_code(:invalid_target_members)]
  end

  def ledger_error(:invalid_wallet_status) do
    [message: "账户状态必须为 active 或 frozen", code: Ledger.error_code(:invalid_wallet_status)]
  end

  def ledger_error(:invalid_concurrency_limit) do
    [message: "并发流上限必须为 1 到 20 之间的整数", code: Ledger.error_code(:invalid_concurrency_limit)]
  end

  def cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, [message: "invalid id", code: "invalid_id"]}
    end
  end

  def cast_uuid(_value), do: {:error, [message: "invalid id", code: "invalid_id"]}

  def positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  def positive_integer(_value),
    do: {:error, [message: "amount_mc must be positive", code: "invalid_amount"]}

  def nonempty_string(value) when is_binary(value) do
    if String.trim(value) == "" do
      {:error, [message: "idempotency_key must not be blank", code: "invalid_idempotency_key"]}
    else
      {:ok, value}
    end
  end

  def nonempty_string(_value),
    do: {:error, [message: "idempotency_key must not be blank", code: "invalid_idempotency_key"]}
end
