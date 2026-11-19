defmodule Cgc2046.LlmGateway.PaymentOrders do
  @moduledoc """
  独立 LLM 算力收银台（Phase 3B）：创单、渠道凭据、幂等重放与查询。

  与 `Cgc2046.Payments.Order` / `PaymentSettlementWorker` 零耦合；本模块只
  写 `llm_payment_orders`，结算由 `LlmPaymentSettlementWorker` 消费渠道回调。

  金额单位：
  - 本表 `amount_cents` = 实付人民币分；
  - `credits_mc` = 创单时快照的入账微积分，`amount_cents * 10_000`。

  幂等键 `(user_id, idempotency_key)` 唯一；同键重放返回原订单与原渠道凭据，
  不重复调渠道、不重复扣款。`out_trade_no` 固定 `LLM_` 前缀，现有回调入口
  据此分流，无需新增渠道通知 URL。
  """

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Accounts.Policies.PlatformAdmin
  alias Cgc2046.Accounts.Role
  alias Cgc2046.LlmGateway.PaymentOrder
  alias Cgc2046.Payments.Provider
  alias Cgc2046.Repo
  require Logger

  @credit_multiplier 10_000
  @order_window_seconds 7_200
  @idempotency_key_max_length 128

  @kinds [
    llm_subscription: :llm_subscription,
    llm_credit_pack: :llm_credit_pack,
    llm_workspace_pool_topup: :llm_workspace_pool_topup
  ]

  @providers [
    wechat_native: :wechat_native,
    alipay_page: :alipay_page,
    alipay_qr: :alipay_qr,
    alipay_wap: :alipay_wap
  ]

  @doc """
  创建 pending LLM 订单并调用渠道生成凭据。

  返回 `{:ok, %PaymentOrder{}}`（`credential` 已落库）或稳定错误 atom。
  """
  @spec create(struct(), map()) :: {:ok, PaymentOrder.t()} | {:error, atom()}
  def create(actor, attrs) when is_map(attrs) do
    with {:ok, kind} <- cast_kind(Map.get(attrs, :order_kind)),
         {:ok, provider} <- cast_provider(Map.get(attrs, :provider)),
         {:ok, amount_cents} <- cast_amount(Map.get(attrs, :amount_cents)),
         {:ok, idempotency_key} <- cast_idempotency_key(Map.get(attrs, :idempotency_key)),
         {:ok, workspace_id} <- cast_workspace(kind, Map.get(attrs, :workspace_id), actor) do
      credits_mc = amount_cents * @credit_multiplier
      out_trade_no = generate_out_trade_no()
      now = DateTime.utc_now()
      expires_at = DateTime.add(now, @order_window_seconds, :second)

      result =
        Repo.transaction(fn ->
          case find_by_idempotency(actor.id, idempotency_key) do
            %PaymentOrder{} = existing ->
              existing

            nil ->
              case insert_order!(
                     actor.id,
                     workspace_id,
                     kind,
                     provider,
                     out_trade_no,
                     amount_cents,
                     credits_mc,
                     expires_at,
                     idempotency_key,
                     now
                   ) do
                {:new, order} ->
                  create_channel_credential(
                    order,
                    kind,
                    provider,
                    amount_cents,
                    out_trade_no,
                    now
                  )

                {:existing, order} ->
                  order
              end
          end
        end)

      case result do
        {:ok, %PaymentOrder{} = order} -> {:ok, order}
        {:error, {:provider_error, _reason}} -> {:error, :provider_failed}
        {:error, :idempotency_conflict} -> {:error, :idempotency_conflict}
        {:error, _reason} -> {:error, :database_error}
      end
    end
  end

  @doc "按渠道单号读取订单（webhook worker 平台读）。"
  @spec find_by_out_trade_no(String.t()) ::
          {:ok, PaymentOrder.t()} | {:error, :not_found | :database_error}
  def find_by_out_trade_no(out_trade_no) when is_binary(out_trade_no) do
    case PaymentOrder
         |> Ash.Query.for_read(:by_out_trade_no, %{out_trade_no: out_trade_no})
         |> Ash.read_one(authorize?: false) do
      {:ok, %PaymentOrder{} = order} -> {:ok, order}
      {:ok, nil} -> {:error, :not_found}
      {:error, _error} -> {:error, :database_error}
    end
  end

  @doc "当前 actor 可读的单笔订单（本人 / PlatformAdmin；工作台订单购买人即 Owner/Admin）。"
  @spec get_for_actor(struct(), String.t()) :: {:ok, PaymentOrder.t()} | {:error, :not_found}
  def get_for_actor(actor, order_id) do
    with {:ok, uuid} <- cast_uuid(order_id) do
      case Ash.get(PaymentOrder, uuid, actor: actor) do
        {:ok, %PaymentOrder{} = order} -> {:ok, order}
        _ -> {:error, :not_found}
      end
    end
  end

  @doc "1 cent = 10,000 microcredits；供 worker/测试复用。"
  def credits_for_cents(amount_cents) when is_integer(amount_cents),
    do: amount_cents * @credit_multiplier

  @doc "订阅订单入账后的 30 天到期时间；加油包永久（nil）。"
  def grant_expires_at(kind, now \\ DateTime.utc_now())

  def grant_expires_at(:llm_subscription, now),
    do: DateTime.add(now, 30 * 86_400, :second)

  def grant_expires_at(:llm_credit_pack, _now), do: nil

  @doc false
  def error_code(reason), do: domain_error_code(reason)

  defp domain_error_code(:invalid_kind), do: "llm_payment_order_invalid_kind"
  defp domain_error_code(:invalid_provider), do: "llm_payment_order_invalid_provider"
  defp domain_error_code(:invalid_amount), do: "llm_payment_order_invalid_amount"
  defp domain_error_code(:invalid_workspace), do: "llm_payment_order_invalid_workspace"

  defp domain_error_code(:invalid_idempotency_key),
    do: "llm_payment_order_invalid_idempotency_key"

  defp domain_error_code(:workspace_required), do: "llm_payment_order_workspace_required"
  defp domain_error_code(:forbidden), do: "llm_payment_order_forbidden"
  defp domain_error_code(:provider_failed), do: "llm_payment_order_provider_failed"
  defp domain_error_code(:idempotency_conflict), do: "llm_payment_order_idempotency_conflict"
  defp domain_error_code(:not_found), do: "llm_payment_order_not_found"
  defp domain_error_code(:database_error), do: "llm_payment_order_database_error"

  defp find_by_idempotency(user_id, idempotency_key) do
    case PaymentOrder
         |> Ash.Query.for_read(:by_idempotency_key, %{
           user_id: user_id,
           idempotency_key: idempotency_key
         })
         |> Ash.read_one(authorize?: false) do
      {:ok, %PaymentOrder{} = order} -> order
      _ -> nil
    end
  end

  defp insert_order!(
         user_id,
         workspace_id,
         kind,
         provider,
         out_trade_no,
         amount_cents,
         credits_mc,
         expires_at,
         idempotency_key,
         now
       ) do
    case Repo.query!(
           """
           INSERT INTO llm_payment_orders (
             id, user_id, workspace_id, order_kind, provider, out_trade_no,
             amount_cents, credits_mc, status, expires_at, idempotency_key,
             inserted_at, updated_at
           )
           VALUES (
             gen_random_uuid(), $1, $2, $3, $4, $5, $6, $7, 'pending', $8, $9, $10, $10
           )
           ON CONFLICT (user_id, idempotency_key) DO NOTHING
           RETURNING id
           """,
           [
             Repo.uuid!(user_id),
             maybe_uuid(workspace_id),
             to_string(kind),
             to_string(provider),
             out_trade_no,
             amount_cents,
             credits_mc,
             expires_at,
             idempotency_key,
             now
           ]
         ).rows do
      [[order_id]] ->
        {:new, Ash.get!(PaymentOrder, Ecto.UUID.load!(order_id), authorize?: false)}

      [] ->
        case find_by_idempotency(user_id, idempotency_key) do
          %PaymentOrder{} = existing -> {:existing, existing}
          nil -> Repo.rollback(:idempotency_conflict)
        end
    end
  end

  defp create_channel_credential(order, kind, provider, amount_cents, out_trade_no, now) do
    order_shape = %{
      provider: provider,
      out_trade_no: out_trade_no,
      amount_cents: amount_cents,
      tier_snapshot: %{"name" => order_description(kind)}
    }

    case Provider.for(provider).create_payment(order_shape, %{}) do
      {:ok, credential} ->
        Repo.query!(
          """
          UPDATE llm_payment_orders
          SET credential = $2, updated_at = $3
          WHERE id = $1
          """,
          [Repo.uuid!(order.id), credential, now]
        )

        %{order | credential: credential}

      {:error, reason} ->
        Logger.warning(
          "llm payment provider create failed provider=#{provider} reason=#{inspect(reason)}"
        )

        Repo.rollback({:provider_error, reason})
    end
  end

  defp order_description(:llm_subscription), do: "CGC 算力订阅"
  defp order_description(:llm_credit_pack), do: "CGC 算力加油包"
  defp order_description(:llm_workspace_pool_topup), do: "CGC 工作台算力池充值"

  defp cast_kind(kind) when is_atom(kind), do: cast_kind(Atom.to_string(kind))

  defp cast_kind(kind) when is_binary(kind) do
    case Enum.find(@kinds, fn {name, _} -> Atom.to_string(name) == kind end) do
      {_name, atom} -> {:ok, atom}
      nil -> {:error, :invalid_kind}
    end
  end

  defp cast_kind(_kind), do: {:error, :invalid_kind}

  defp cast_provider(provider) when is_atom(provider), do: cast_provider(Atom.to_string(provider))

  defp cast_provider(provider) when is_binary(provider) do
    case Enum.find(@providers, fn {name, _} -> Atom.to_string(name) == provider end) do
      {_name, atom} -> {:ok, atom}
      nil -> {:error, :invalid_provider}
    end
  end

  defp cast_provider(_provider), do: {:error, :invalid_provider}

  defp cast_amount(amount) when is_integer(amount) and amount > 0, do: {:ok, amount}
  defp cast_amount(_amount), do: {:error, :invalid_amount}

  defp cast_idempotency_key(key) when is_binary(key) do
    key = String.trim(key)

    cond do
      key == "" -> {:error, :invalid_idempotency_key}
      String.length(key) > @idempotency_key_max_length -> {:error, :invalid_idempotency_key}
      true -> {:ok, key}
    end
  end

  defp cast_idempotency_key(_key), do: {:error, :invalid_idempotency_key}

  defp cast_workspace(:llm_workspace_pool_topup, nil, _actor), do: {:error, :workspace_required}

  defp cast_workspace(:llm_workspace_pool_topup, workspace_id, actor) do
    with {:ok, uuid} <- cast_uuid(workspace_id),
         true <- workspace_manage?(actor, uuid) do
      {:ok, uuid}
    else
      :error -> {:error, :invalid_workspace}
      :forbidden -> {:error, :forbidden}
      false -> {:error, :forbidden}
    end
  end

  defp cast_workspace(kind, nil, _actor) when kind in [:llm_subscription, :llm_credit_pack],
    do: {:ok, nil}

  defp cast_workspace(_kind, _workspace_id, _actor), do: {:error, :invalid_workspace}

  defp workspace_manage?(actor, workspace_id) do
    if PlatformAdmin.platform_admin?(actor) do
      true
    else
      actor
      |> MembershipContext.role_names(workspace_id)
      |> Enum.any?(&Role.manage_role?/1)
    end
  end

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp cast_uuid(_value), do: :error

  defp maybe_uuid(nil), do: nil
  defp maybe_uuid(uuid), do: Repo.uuid!(uuid)

  defp generate_out_trade_no do
    # 微信 APIv3 out_trade_no 上限 32 字符；"LLM_" + 28 位十六进制 = 32。
    "LLM_" <> binary_part(String.replace(Ecto.UUID.generate(), "-", ""), 0, 28)
  end
end
