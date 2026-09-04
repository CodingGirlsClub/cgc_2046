defmodule Cgc2046.Integrations.Wechat.ClientGateTest do
  @moduledoc """
  issue #264：平台凭证功能门禁（runtime.exs 小程序 env 由 fetch_env! 改 get_env
  后的运行时守卫，写法沿用 wechat_pay_test 配置门禁块）。

  - 凭证全缺（config 无平台键 / 值 nil——prod 缺 env 时 runtime.exs 的真实形状）→
    四个外呼入口统一 `{:error, :platform_not_configured}`，不 raise、零外呼；
  - 半配置（空串；xhs 缺 qrcode_path/notification_path）同拦——空串归一语义同
    wechat_pay advisor07（runtime env 注入缺值常得 ""，防空串穿透门禁深处崩溃）；
  - 凭证齐 → 门禁放行且 config 注入真实请求（stub 内断言 appid/secret 来源）。

  串行：Application.put_env 为应用全局（async: false，与 wechat_pay_test 同约束）。
  """

  use ExUnit.Case, async: false

  alias Cgc2046.Integrations.Wechat.Client
  alias Cgc2046.MiniprogramFixtures, as: Fixtures
  # config.exs 在 boot 时载入 :miniprogram_platforms，put_env 覆盖后 delete_env
  # 会连原值一并删除（app env 是扁平 kv，无「回退 config」语义）——on_exit 存
  # 原值显式恢复，否则污染后续用例（wechat_not_configured 假失败）。
  setup do
    original = Application.get_env(:cgc_2046, :miniprogram_platforms)
    on_exit(fn -> Application.put_env(:cgc_2046, :miniprogram_platforms, original) end)
    :ok
  end

  describe "平台凭证门禁（platform_not_configured 短路）" do
    test "全缺（无平台键）：code2session/generate_code/send_notification/decrypt_phone 干净拒绝" do
      Application.put_env(:cgc_2046, :miniprogram_platforms, %{})

      assert {:error, :platform_not_configured} = Client.code2session(:tt, "code")
      assert {:error, :platform_not_configured} = Client.generate_code(:xhs, "scene")

      assert {:error, :platform_not_configured} =
               Client.send_notification(:tt, "oX", "tpl", %{})

      assert {:error, :platform_not_configured} =
               Client.decrypt_phone(:wechat, %{session_key: "k"}, "d", "i")
    end

    test "值 nil（get_env 缺 env 的形状）：三平台登录入口拦截而非深处崩溃" do
      Application.put_env(:cgc_2046, :miniprogram_platforms, %{
        wechat: %{appid: nil, secret: nil},
        tt: %{appid: nil, secret: nil},
        xhs: %{appid: nil, secret: nil, qrcode_path: nil, notification_path: nil}
      })

      for platform <- Client.platforms() do
        assert {:error, :platform_not_configured} = Client.code2session(platform, "code")
      end
    end

    test "半配置（secret 空串）：拦截" do
      Application.put_env(:cgc_2046, :miniprogram_platforms, %{
        tt: %{appid: "tt-appid", secret: ""}
      })

      assert {:error, :platform_not_configured} = Client.code2session(:tt, "code")
    end

    test "xhs 半配置（缺 qrcode_path/notification_path）：生成码与通知入口拦截" do
      Application.put_env(:cgc_2046, :miniprogram_platforms, %{
        xhs: %{appid: "xhs-appid", secret: "xhs-secret"}
      })

      assert {:error, :platform_not_configured} = Client.generate_code(:xhs, "scene")

      assert {:error, :platform_not_configured} =
               Client.send_notification(:xhs, "oX", "tpl", %{})
    end

    test "凭证齐 → 门禁放行，config 注入请求（stub 断言 appid/secret 来源）" do
      Application.put_env(:cgc_2046, :miniprogram_platforms, %{
        tt: %{appid: "tt-gate-appid", secret: "tt-gate-secret"}
      })

      Fixtures.stub_code2session(%{
        tt: Fixtures.code2session_body(:tt, %{openid: "tt-gate-openid", session_key: "k"})
      })

      assert {:ok, %{openid: "tt-gate-openid"}} = Client.code2session(:tt, "gate-code")
    end
  end

  describe "code2session 异常响应形状（#99 真机:微信边缘错误返回非 JSON）" do
    test "text/plain 错误页（binary body）→ :code2session_bad_response,不 crash" do
      Application.put_env(:cgc_2046, :miniprogram_platforms, %{
        wechat: %{appid: "wx-gate-appid", secret: "wx-gate-secret"}
      })

      # 绕过 Fixtures.stub_code2session(其固定 JSON content-type)——直接控制
      # content-type 模拟微信网关层返回的 text/plain 错误页。
      Req.Test.stub(Fixtures.stub_name(), fn conn ->
        Req.Test.text(conn, "System Error, please try again later")
      end)

      assert {:error, :code2session_bad_response} = Client.code2session(:wechat, "c")
    end

    test "未知 JSON 形状(无 openid/errcode 键)→ :code2session_bad_response,不 crash" do
      Application.put_env(:cgc_2046, :miniprogram_platforms, %{
        wechat: %{appid: "wx-gate-appid", secret: "wx-gate-secret"}
      })

      Req.Test.stub(Fixtures.stub_name(), fn conn ->
        Req.Test.json(conn, %{"unexpected" => "shape"})
      end)

      assert {:error, :code2session_bad_response} = Client.code2session(:wechat, "c")
    end
  end
end
