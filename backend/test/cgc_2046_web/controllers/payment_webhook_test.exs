defmodule Cgc2046Web.PaymentWebhookTest do
  @moduledoc """
  U6：渠道回调入口（KTD4/R7 入口段/R21）。

  - 合法回调：200 + webhook_event 落库 + 同事务 Oban 入队落账 job。
  - 同 (provider, event_id) 重放：200 + 不再入队（幂等去重唯一索引承担）。
  - 错签：400 + 零落库零入队 + telemetry。
  - 未知 provider：404。
  """

  use Cgc2046Web.ConnCase, async: false

  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.Payments.Providers.Fake
  alias Cgc2046.Payments.WebhookEvent
  alias Cgc2046.Workers.PaymentSettlementWorker

  describe "POST /api/payments/webhooks/:provider" do
    test "合法回调：200 + 事件落库 + 落账 job 入队（args 带 webhook_event_id + provider）" do
      body = ~s({"id":"evt-1","event_type":"TRANSACTION.SUCCESS","out_trade_no":"oto-1"})

      conn = post_wechat(body)

      assert json_response(conn, 200)

      assert [%{provider: :wechat, event_id: "evt-1", status: :received}] =
               Ash.read!(WebhookEvent, authorize?: false)

      assert_enqueued(
        worker: PaymentSettlementWorker,
        args: %{"webhook_event_id" => fetch_event_id("evt-1"), "provider" => "wechat"}
      )
    end

    test "同 (provider, event_id) 重放：200 + 不再入队 + 单行事件" do
      body = ~s({"id":"evt-replay","event_type":"TRANSACTION.SUCCESS"})

      assert %{} = json_response(post_wechat(body), 200)
      assert %{} = json_response(post_wechat(body), 200)

      assert [%{event_id: "evt-replay"}] = Ash.read!(WebhookEvent, authorize?: false)
      assert [job] = all_enqueued(worker: PaymentSettlementWorker)
      assert get_in(job.args, ["provider"]) == "wechat"
    end

    test "错签：400 + 零落库零入队 + telemetry" do
      Fake.script!(verify_webhook: :error)

      conn = post_wechat(~s({"id":"evt-bad"}))

      assert conn.status == 400
      assert Ash.read!(WebhookEvent, authorize?: false) == []
      assert [] = all_enqueued(worker: PaymentSettlementWorker)
    after
      Fake.reset!()
    end

    test "未知 provider：404" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/payments/webhooks/paypal", ~s({"id":"evt-x"}))

      assert conn.status == 404
    end

    test "渠道回调不走 GraphQL 鉴权链（无 actor 可达）" do
      # 匿名直发（无 cookie/无 bearer）即处理路径本身——鉴权语义全部在验签
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/payments/webhooks/wechat", ~s({"id":"evt-anon"}))

      assert json_response(conn, 200)
    end
  end

  # ── 布置 ──

  defp post_wechat(body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/payments/webhooks/wechat", body)
  end

  defp fetch_event_id(event_id) do
    Ash.read!(WebhookEvent, authorize?: false)
    |> Enum.find(&(&1.event_id == event_id))
    |> Map.fetch!(:id)
  end
end
