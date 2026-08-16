defmodule Cgc2046Web.PaymentWebhookController do
  @moduledoc """
  渠道回调入口（U6，KTD4）：验签 → 幂等落库 → 同事务入队落账 job → 快速 200。

  - 不过 :graphql（无 actor；鉴权语义 = 渠道验签，#172 已定 seam）。
  - 幂等（R21）：webhook_events (provider, event_id) 唯一索引承担——重复投递
    命中唯一冲突即按成功回执（渠道停止重试），业务状态只变一次。
  - 应答体按渠道（adapter 层语义）：微信 200 + {"code":"SUCCESS"}；支付宝
    200 + "success"（小写纯文本，支付宝要求特定 ack）。
  - 验签失败 400 + telemetry（渠道按频率策略重试）。
  """

  use Cgc2046Web, :controller

  require Logger

  alias Cgc2046.Payments.{Provider, WebhookEvent}
  alias Cgc2046.Workers.PaymentSettlementWorker

  @channel_providers %{"wechat" => :wechat, "alipay" => :alipay}

  def handle(conn, %{"provider" => provider}) when provider in ["wechat", "alipay"] do
    channel = @channel_providers[provider]
    raw_body = conn.private[:raw_body] || ""
    headers = Map.new(conn.req_headers)

    case Provider.for_channel(channel).verify_webhook(raw_body, headers) do
      {:ok, event} when is_map(event) ->
        persist_and_enqueue(conn, provider, event)

      other ->
        Logger.warning(
          "payment webhook verify failed: provider=#{provider} result=#{inspect(other)}"
        )

        :telemetry.execute(
          [:cgc2046, :payment_webhook, :verify_failed],
          %{count: 1},
          %{provider: provider}
        )

        conn |> put_resp_content_type("application/json") |> send_resp(400, fail_body(provider))
    end
  end

  def handle(conn, _params), do: send_resp(conn, 404, "")

  # 落库 + 入队同事务（KTD4）：唯一冲突（重复投递）= 已收到，按成功回执；
  # 新事件 → Oban job（args 只带 webhook_event_id + provider，不存 payload）。
  defp persist_and_enqueue(conn, provider, event) do
    event_id = event_identifier(event)

    result =
      Cgc2046.Repo.transaction(fn ->
        changeset =
          WebhookEvent
          |> Ash.Changeset.for_create(:create, %{
            provider: @channel_providers[provider],
            event_id: event_id,
            payload: event
          })

        case Ash.create(changeset, authorize?: false) do
          {:ok, webhook_event} ->
            webhook_event.id
            |> settlement_job()
            |> Oban.insert!()

            :enqueued

          {:error, %{errors: errors} = error} ->
            if unique_conflict?(errors) do
              :duplicate
            else
              Cgc2046.Repo.rollback({:persist_failed, error})
            end
        end
      end)

    case result do
      {:ok, _} ->
        respond(conn, provider, 200, success_body(provider))

      # Ash 在事务内遇 DB 唯一冲突会自行 rollback 并以 changeset 返回——
      # 唯一冲突 = 重复投递，按成功回执（R21）
      {:error, %Ash.Changeset{errors: errors}} ->
        if unique_conflict?(errors) do
          respond(conn, provider, 200, success_body(provider))
        else
          Logger.error("payment webhook persist failed: #{inspect(errors)}")

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(500, fail_body(provider))
        end

      {:error, {:persist_failed, error}} ->
        Logger.error("payment webhook persist failed: #{inspect(error)}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, fail_body(provider))
    end
  end

  defp settlement_job(webhook_event_id) do
    PaymentSettlementWorker.new(%{
      "webhook_event_id" => webhook_event_id
    })
  end

  # 渠道事件标识：微信 v3 通知体 id；支付宝表单 notify_id；兜底 sha256(raw body)
  # 去重键（两渠道正常路径均有稳定 id）。
  defp event_identifier(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp event_identifier(%{"notify_id" => id}) when is_binary(id) and id != "", do: id

  defp event_identifier(event) do
    :crypto.hash(:sha256, :erlang.term_to_binary(event)) |> Base.encode16(case: :lower)
  end

  # 唯一冲突识别（Ash 可能包成 Ash.Error.Invalid 或裸 Changeset，errors 形状一致）
  defp unique_conflict?(errors) do
    Enum.any?(errors, fn
      %{private_vars: vars} ->
        Keyword.get(vars || [], :constraint_type) == :unique

      _ ->
        false
    end)
  end

  defp respond(conn, provider, status, body) do
    content_type = if provider == "alipay", do: "text/plain", else: "application/json"
    conn |> put_resp_content_type(content_type) |> send_resp(status, body)
  end

  # 应答体（渠道 ack 契约）
  defp success_body("alipay"), do: "success"
  defp success_body(_wechat), do: ~s({"code":"SUCCESS"})

  defp fail_body("alipay"), do: "fail"
  defp fail_body(_wechat), do: ~s({"code":"FAIL","message":"verify failed"})
end
