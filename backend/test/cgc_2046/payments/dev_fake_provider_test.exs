defmodule Cgc2046.Payments.DevFakeProviderTest do
  use ExUnit.Case, async: true

  alias Cgc2046.Payments.Order
  alias Cgc2046.Payments.Providers.DevFake

  test "create_payment returns qr_code credential with order context" do
    order = %Order{out_trade_no: "DEV-1", amount_cents: 9900}

    assert {:ok, credential} = DevFake.create_payment(order, %{})
    assert credential["type"] == "qr_code"
    assert credential["code_url"] == "https://dev.cgc2046.local/pay/DEV-1"
    assert credential["amount_cents"] == 9900
  end

  test "verify_webhook accepts json event with out_trade_no and rejects garbage" do
    body = Jason.encode!(%{"out_trade_no" => "DEV-1", "id" => "dev-evt"})
    assert {:ok, event} = DevFake.verify_webhook(body, %{})
    assert event["out_trade_no"] == "DEV-1"

    assert :error = DevFake.verify_webhook("not-json", %{})
    assert :error = DevFake.verify_webhook(Jason.encode!(%{"id" => "x"}), %{})
  end

  test "refund is synchronously completed and statement empty" do
    assert {:ok, :completed} = DevFake.refund(%Order{out_trade_no: "DEV-1"})
    assert {:ok, []} = DevFake.fetch_statement(~D[2026-10-19])
  end

  test "test env still injects the scripted Fake provider, not DevFake" do
    providers = Application.get_env(:cgc_2046, :payments_providers)
    assert providers[:wechat] == Cgc2046.Payments.Providers.Fake
    assert providers[:alipay] == Cgc2046.Payments.Providers.Fake
  end
end
