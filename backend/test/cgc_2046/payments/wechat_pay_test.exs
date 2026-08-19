defmodule Cgc2046.Payments.WechatPayTest do
  @moduledoc """
  plan 007：WechatPay adapter 直接测试（此前 0 覆盖——test 环境无 :wechat_pay
  配置且 Fake 注入，真实 adapter 从不被触达）。

  - 配置门禁：七键齐（五商户键 + api_secret_v2_key + webhook_base_url）才可用，
    任何键缺失 → {:error, :provider_not_configured}，绝不静默外呼
    （B3：漏配回调域名曾是 Path.join(nil) 500；v2 key 是 SDK 硬性必需键）。
  - verify_webhook 回环：平台证书 RSA-SHA256 验签 + AEAD_AES_256_GCM 资源解密
    （夹具写法沿用 providers_test.exs 验签块）。
  - client 启动接线（B1）：client 经 ClientSup 动态挂载——Refresher.Pay 把平台
    证书载入 :persistent_term、per-client 命名 Finch 池存活。

  网络红线：setup 预置 SDK 文件存储的证书记录，Refresher.Pay init 走 restore
  分支（restore 命中 → put_certs，零外呼）；init_certs 下载路径由真实小额验收
  覆盖，CI 内不启动。
  """

  # 串行防跨用例污染（#246）：本文件触发 SDK 运行时动态模块编译
  # （WeChat.Pay.build_client 翻转全局 Code.compiler_options(ignore_module_conflict)）
  # + :current_fingerprint 全局键（cleanup 跨用例 terminate 仍在运行的 child）；
  # async 并发会与 graphql_sign_in_with_platform/enrollment 的 miniprogram
  # 动态编译互扰（与 client_test 同约束）。
  use Cgc2046.DataCase, async: false

  alias Cgc2046.Payments.Providers.WechatPay
  alias WeChat.Pay.Certificates

  @platform_serial "TESTSERIAL"

  describe "配置门禁（provider_not_configured 短路）" do
    test "零配置：create_payment 明确拒绝，current_client 为 nil" do
      Application.put_env(:cgc_2046, :wechat_pay, [])
      order = order()

      assert {:error, :provider_not_configured} = WechatPay.create_payment(order, %{openid: "oX"})
      assert is_nil(WechatPay.current_client())
    after
      Application.delete_env(:cgc_2046, :wechat_pay)
    end

    test "半配置（缺 webhook_base_url，B3 门禁回归钉）：干净拒绝而非 Path.join(nil) 崩溃" do
      Application.put_env(
        :cgc_2046,
        :wechat_pay,
        base_config() |> Keyword.delete(:webhook_base_url)
      )

      order = order()

      assert {:error, :provider_not_configured} = WechatPay.create_payment(order, %{openid: "oX"})
    after
      Application.delete_env(:cgc_2046, :wechat_pay)
    end

    test "半配置（缺 api_secret_v2_key，SDK 硬性必需键）：干净拒绝而非 build_client raise" do
      Application.put_env(
        :cgc_2046,
        :wechat_pay,
        base_config() |> Keyword.delete(:api_secret_v2_key)
      )

      order = order()

      assert {:error, :provider_not_configured} = WechatPay.create_payment(order, %{openid: "oX"})
    after
      Application.delete_env(:cgc_2046, :wechat_pay)
    end

    test "空串归一（advisor07）：七键全为 \"\" 等价未配置，门禁短路而非深处崩溃" do
      empty = base_config() |> Keyword.keys() |> Map.new(&{&1, ""})
      Application.put_env(:cgc_2046, :wechat_pay, empty)
      order = order()

      assert {:error, :provider_not_configured} = WechatPay.create_payment(order, %{openid: "oX"})
      assert is_nil(WechatPay.current_client())
    after
      Application.delete_env(:cgc_2046, :wechat_pay)
    end
  end

  describe "verify_webhook 回环（RSA-SHA256 验签 + AES-256-GCM 资源解密）" do
    setup :with_started_client

    test "种证书 serial + 正确签名 → 解密资源体；篡改 body / 未种 serial 拒绝", ctx do
      {raw_body, headers} = signed_webhook(ctx)

      assert {:ok, %{"out_trade_no" => "oto-test-1", "trade_state" => "SUCCESS"}} =
               WechatPay.verify_webhook(raw_body, headers)

      # 反例：篡改 body（签名不再覆盖内容）
      tampered = String.replace(raw_body, "TRANSACTION.SUCCESS", "TRANSACTION.FAILED")
      assert :error = WechatPay.verify_webhook(tampered, headers)

      # 反例：serial 未种平台证书
      assert :error =
               WechatPay.verify_webhook(raw_body, %{headers | "wechatpay-serial" => "NOT-SEEDED"})
    end
  end

  describe "client 启动接线（B1：ClientSup 动态挂载 + Refresher 证书加载）" do
    setup :with_started_client

    test "Finch 池存活、ClientSup 有 child、证书经 Refresher 进 persistent_term、缓存幂等", ctx do
      client = ctx.client

      finch = Process.whereis(:"#{client}.Finch")
      assert is_pid(finch) and Process.alive?(finch)

      children = DynamicSupervisor.which_children(Cgc2046.Payments.ClientSup)
      assert length(children) >= 1

      # Refresher restore 路径已把平台证书种进 persistent_term（未走 init_certs 外呼）
      assert not is_nil(Certificates.get_cert(client, @platform_serial))

      # 缓存命中：同配置二次获取返回同一模块（不重复 build/start）
      assert WechatPay.current_client() == client
    end
  end

  describe "缓存悬挂自愈（advisor07 F1：persistent_term 命中但 Supervisor 已死）" do
    setup :with_started_client

    test "杀掉 client Supervisor 后再取：重建并恢复 Finch 池与证书", ctx do
      client = ctx.client
      # 现状健康：缓存命中且进程存活
      assert WechatPay.current_client() == client
      assert is_pid(Process.whereis(:"#{client}.Supervisor"))

      # 制造悬挂：经 ClientSup terminate child（一次性摘除、无重启语义——等价
      # ClientSup 重启/发布重载清空动态 child 的生产故障形态；直接 kill 挂起名
      # 会被 one_for_one 自动拉起，复现不了悬挂）。persistent_term 缓存仍在。
      refresher = Process.whereis(:"#{client}.Refresher")
      :ok = DynamicSupervisor.terminate_child(Cgc2046.Payments.ClientSup, child_pid(client))
      refute is_pid(Process.whereis(:"#{client}.Supervisor"))
      assert not is_nil(:persistent_term.get({WechatPay, :erlang.phash2(ctx.config)}, nil))

      # 自愈：命中缓存但存活校验失败 → 重建模块 + 重新挂 ClientSup
      healed = WechatPay.current_client()
      assert is_atom(healed)
      assert is_pid(Process.whereis(:"#{healed}.Supervisor"))
      finch = Process.whereis(:"#{healed}.Finch")
      assert is_pid(finch) and Process.alive?(finch)
      # Refresher restore 路径重新种证书（零外呼）
      assert not is_nil(Certificates.get_cert(healed, @platform_serial))
      # 旧 Refresher 进程确已死亡（新挂的是新进程）
      assert Process.whereis(:"#{healed}.Refresher") != refresher
    end
  end

  # ── 布置 ──

  # 全量七键配置；每次调用生成新商户 RSA 密钥 → 配置指纹唯一 → client 模块名隔离
  defp base_config do
    [
      appid: "wx-test-appid",
      mch_id: "1900000000",
      api_v3_key: String.duplicate("k", 32),
      api_secret_v2_key: String.duplicate("v", 32),
      client_serial_no: "TEST0001",
      client_private_key: merchant_pem(),
      webhook_base_url: "https://cb.example.com"
    ]
  end

  # SDK 默认存储（PayFile）预置平台证书记录：Refresher.Pay init 的 make_sure_certs
  # 走 restore 命中分支 → put_certs，全程零 HTTP。存储路径只由 mch_id 决定，
  # 可在 client 模块构建前写入。
  defp seed_cert_storage(mch_id, platform_pem) do
    :ok =
      WeChat.Storage.PayFile.store(mch_id, :certs, [
        %{"serial_no" => @platform_serial, "certificate" => platform_pem}
      ])
  end

  defp with_started_client(_ctx) do
    config = base_config()
    platform_key = X509.PrivateKey.new_rsa(2048)
    platform_cert = X509.Certificate.self_signed(platform_key, "/CN=wechat-pay-platform-test")
    platform_pem = X509.Certificate.to_pem(platform_cert)

    Application.put_env(:cgc_2046, :wechat_pay, config)
    seed_cert_storage(config[:mch_id], platform_pem)

    client = WechatPay.current_client()
    on_exit(fn -> cleanup(config, client) end)
    %{config: config, client: client, platform_key: platform_key, platform_pem: platform_pem}
  end

  # 回环报文：真实微信回调形状（encrypt-resource + AEAD_AES_256_GCM），
  # 用平台证书私钥对 timestamp\nnonce\nraw_body\n 签名。
  defp signed_webhook(ctx) do
    api_key = ctx.config[:api_v3_key]

    # iv 需同时是合法 JSON 字符串与 12 字节 AES-GCM nonce（SDK 将 nonce 字段原样传入）
    iv = "0123456789ab"
    plaintext = ~s({"out_trade_no":"oto-test-1","trade_state":"SUCCESS"})

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, api_key, iv, plaintext, "transaction", true)

    combined = Base.encode64(<<ciphertext::binary, tag::binary>>)

    raw_body =
      Jason.encode!(%{
        "event_type" => "TRANSACTION.SUCCESS",
        "resource_type" => "encrypt-resource",
        "resource" => %{
          "algorithm" => "AEAD_AES_256_GCM",
          "nonce" => iv,
          "ciphertext" => combined,
          "associated_data" => "transaction"
        }
      })

    timestamp = DateTime.to_unix(DateTime.utc_now()) |> to_string()
    nonce = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    content = "#{timestamp}\n#{nonce}\n#{raw_body}\n"
    signature = Base.encode64(:public_key.sign(content, :sha256, ctx.platform_key))

    headers = %{
      "wechatpay-signature" => signature,
      "wechatpay-timestamp" => timestamp,
      "wechatpay-nonce" => nonce,
      "wechatpay-serial" => @platform_serial
    }

    {raw_body, headers}
  end

  defp cleanup(config, client) do
    Application.delete_env(:cgc_2046, :wechat_pay)

    if client do
      Certificates.remove_cert(client, @platform_serial)
      :persistent_term.erase({:wechat, {client, :certs}})
      :persistent_term.erase({WechatPay, :erlang.phash2(config)})
      :persistent_term.erase({WechatPay, :current_fingerprint})
      terminate_client_child(client)
    end

    File.rm(storage_file(config[:mch_id]))
  end

  # 摘 ClientSup 下该模块的动态 child（按 mods 匹配；DynamicSupervisor child id 为
  # :undefined，不能按模块名 terminate）——测试收尾不留 Finch 池。
  defp terminate_client_child(module) do
    case Process.whereis(Cgc2046.Payments.ClientSup) do
      nil ->
        :ok

      _ ->
        Cgc2046.Payments.ClientSup
        |> DynamicSupervisor.which_children()
        |> Enum.filter(fn {_id, _pid, _type, mods} -> mods == [module] end)
        |> Enum.each(fn {_id, pid, _type, _mods} ->
          DynamicSupervisor.terminate_child(Cgc2046.Payments.ClientSup, pid)
        end)
    end
  end

  defp storage_file(mch_id) do
    (Path.join([:code.priv_dir(:wechat), "wechat_pay_cacerts_#{mch_id}"]) <> ".json")
    |> to_string()
  end

  defp merchant_pem do
    priv = :public_key.generate_key({:rsa, 2048, 65_537})
    :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, priv)])
  end

  # ClientSup 下按模块名找该 client 的动态 child pid（child id 恒 :undefined）
  defp child_pid(module) do
    {_id, pid, _type, _mods} =
      Cgc2046.Payments.ClientSup
      |> DynamicSupervisor.which_children()
      |> Enum.find(fn {_id, _pid, _type, mods} -> mods == [module] end)

    pid
  end

  defp order do
    %Cgc2046.Payments.Order{
      id: Ecto.UUID.generate(),
      provider: :wechat_jsapi,
      out_trade_no: "oto-" <> Ecto.UUID.generate(),
      amount_cents: 19_900,
      status: :pending
    }
  end
end
