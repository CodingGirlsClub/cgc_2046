defmodule Cgc2046.Payments.ProvidersTest do
  @moduledoc """
  U4：Provider behaviour 边界 + FakeProvider 契约 + 验签密码学。

  - FakeProvider 五回调与 behaviour 形状一致（test/dev 注入件）。
  - 验签：微信 RSA-SHA256（WeChat.Pay.Crypto.verify）与支付宝 RSA2
    （Alipay.Crypto.verify_callback）——测试向量以本测试生成的 RSA 密钥对
    构造（等价于官方向量；错签/篡改一律拒绝）。
  - 渠道密钥零落库：adapter 从应用环境读密钥（KTD7），缺失时明确
    :provider_not_configured 而非静默外呼。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.Payments.Provider
  alias Cgc2046.Payments.Providers.Fake

  describe "FakeProvider 契约（behaviour 一致性）" do
    test "五回调按 behaviour 元数导出（@behaviour 声明编译期已强制实现）" do
      assert function_exported?(Fake, :create_payment, 2)
      assert function_exported?(Fake, :fetch_transaction, 1)
      assert function_exported?(Fake, :refund, 1)
      assert function_exported?(Fake, :verify_webhook, 2)
      assert function_exported?(Fake, :fetch_statement, 1)
    end

    test "五回调形状与 behaviour 声明一致" do
      order = fake_order()

      assert {:ok, credential} = Fake.create_payment(order, %{openid: "oX"})
      assert is_map(credential) and is_binary(credential["type"])

      assert {:ok, txn} = Fake.fetch_transaction(order.out_trade_no)
      assert %{status: status, amount_cents: amount, transaction_id: txn_id} = txn
      assert status in [:paid, :pending, :closed, :refunded]
      assert is_integer(amount) and amount >= 0
      assert is_binary(txn_id)

      # 默认 = 支付宝同步完成语义;:ok = 微信异步受理(F1 契约扩展)
      assert {:ok, :completed} = Fake.refund(order)

      Fake.script!(refund: :ok)
      assert :ok = Fake.refund(order)
      Fake.script!(refund: {:error, :channel_rejected})
      assert {:error, :channel_rejected} = Fake.refund(order)
      Fake.reset!()
      assert {:ok, event} = Fake.verify_webhook(~s({"id":"evt-1"}), %{})
      assert is_map(event)
      assert {:ok, rows} = Fake.fetch_statement(~D[2026-08-15])
      assert is_list(rows)
    end

    test "可脚本化：迟到/金额不符/退款失败分支" do
      order = fake_order()

      Fake.script!(
        fetch_transaction: {:ok, %{status: :pending, amount_cents: 0, transaction_id: ""}}
      )

      assert {:ok, %{status: :pending}} = Fake.fetch_transaction(order.out_trade_no)

      Fake.script!(refund: {:error, :channel_rejected})
      assert {:error, :channel_rejected} = Fake.refund(order)
    after
      Fake.reset!()
    end
  end

  describe "Provider.for 解析（KTD3 隔离）" do
    test "四 provider 归属两渠道 adapter；test 环境注入 Fake" do
      assert Provider.for(:wechat_jsapi) == Fake
      assert Provider.for(:wechat_native) == Fake
      assert Provider.for(:alipay_page) == Fake
      assert Provider.for(:alipay_wap) == Fake
    end

    test "未知 provider 拒绝" do
      assert_raise FunctionClauseError, fn -> Provider.for(:paypal) end
    end
  end

  describe "微信回调验签（RSA-SHA256）+ AES-GCM 资源解密" do
    setup do
      {pub, priv} = rsa_keypair()
      %{pub: pub, priv: priv}
    end

    test "正确签名 + 时间戳 + nonce 验签通过；篡改任一项拒绝", ctx do
      body = ~s({"event_type":"TRANSACTION.SUCCESS"})
      {signature, timestamp, nonce} = sign_wechat(ctx.priv, body)

      assert WeChat.Pay.Crypto.verify(signature, timestamp, nonce, body, ctx.pub)

      refute WeChat.Pay.Crypto.verify(signature, "9999999999", nonce, body, ctx.pub)
      refute WeChat.Pay.Crypto.verify(signature, timestamp, "bad-nonce", body, ctx.pub)
      refute WeChat.Pay.Crypto.verify(signature, timestamp, nonce, ~s({"tampered":1}), ctx.pub)
      refute WeChat.Pay.Crypto.verify("not-base64!!!", timestamp, nonce, body, ctx.pub)
    end

    test "回调资源 AES-256-GCM 加解密回环（APIv3 key）" do
      api_key = :crypto.strong_rand_bytes(32)
      iv = :crypto.strong_rand_bytes(12)
      plaintext = ~s({"out_trade_no":"oto-1","amount":100})

      # 微信回调资源体 = base64(ciphertext || tag)
      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, api_key, iv, plaintext, "transaction", true)

      combined = Base.encode64(<<ciphertext::binary, tag::binary>>)

      assert WeChat.Pay.Crypto.decrypt_aes_256_gcm(api_key, combined, "transaction", iv) ==
               plaintext
    end
  end

  describe "支付宝回调验签（RSA2）" do
    setup do
      {pub, priv} = rsa_keypair()
      %{pub: pub, priv: priv}
    end

    test "正确签名参数集验签通过；篡改金额拒绝", ctx do
      params = %{
        "out_trade_no" => "oto-1",
        "trade_status" => "TRADE_SUCCESS",
        "total_amount" => "100.00",
        "sign_type" => "RSA2"
      }

      sign =
        Base.encode64(:public_key.sign(v2_string(Map.drop(params, ["sign"])), :sha256, ctx.priv))

      signed = Map.put(params, "sign", sign)

      assert Alipay.Crypto.verify_callback(signed, ctx.pub)

      tampered = Map.put(signed, "total_amount", "1.00")
      refute Alipay.Crypto.verify_callback(tampered, ctx.pub)
    end
  end

  describe "支付宝账单 query 形状（对账规⑦回归钉,生产实证 2026-08-21~25）" do
    setup do
      {_pub, priv} = rsa_keypair()
      %{priv: priv}
    end

    test "fetch_statement 的 query 经 v3_sign 签名段不崩(keyword list 形状)", ctx do
      # ArgumentError,每日对账 job 全数 discarded——此处钉死正确形状:
      # Tesla env.query 原样透传 v3_sign,只接受 keyword list/binary
      env = %{
        method: :get,
        url: "/v3/alipay/data/dataservice/bill/downloadurl/query",
        query: [bill_type: "trade", bill_date: "2026-08-24"],
        body: ""
      }

      # 签名纯函数可跑通即形状正确(map 形状此处 raise,等价生产崩溃)
      assert is_binary(Alipay.Crypto.v3_sign(env, "app_id=x,nonce=y,timestamp=z", ctx.priv))
    end
  end

  # ── 布置 ──

  defp fake_order do
    %Cgc2046.Payments.Order{
      id: Ecto.UUID.generate(),
      provider: :wechat_jsapi,
      out_trade_no: "oto-" <> Ecto.UUID.generate(),
      amount_cents: 19_900,
      status: :pending
    }
  end

  defp rsa_keypair do
    priv = :public_key.generate_key({:rsa, 2048, 65_537})
    {public_of(priv), priv}
  end

  # OTP 版本差异：generate_key 可能返回 map 或 RSAPrivateKey record，两种形状都取公钥
  defp public_of(%{modulus: m, publicExponent: e}), do: {:RSAPublicKey, m, e}
  defp public_of({:RSAPrivateKey, _, m, e, _, _, _, _, _, _, _}), do: {:RSAPublicKey, m, e}

  defp sign_wechat(priv, body) do
    timestamp = DateTime.to_unix(DateTime.utc_now()) |> to_string()
    nonce = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    content = "#{timestamp}\n#{nonce}\n#{body}\n"
    signature = Base.encode64(:public_key.sign(content, :sha256, priv))
    {signature, timestamp, nonce}
  end

  # Alipay v2 验签串：去掉 sign/sign_type 后按 key 排序 join "&"（Alipay.Crypto.v2_sign 同源逻辑）
  defp v2_string(params) do
    params
    |> Enum.reject(&match?({_k, nil}, &1))
    |> Enum.reject(fn {k, _v} -> k in ["sign", "sign_type"] end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)
  end
end
