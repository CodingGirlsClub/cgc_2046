defmodule Cgc2046.Integrations.Wechat.UrlLinkTest do
  use Cgc2046.DataCase, async: false

  alias Cgc2046.Integrations.Wechat.UrlLink

  # Tesla.Mock 008 模式（share_scheme_service_test.exs 先例）：SDK 请求全量
  # 被 mock 拦截，access_token 走 Storage.Cache 未种值路径（autostart=false，
  # 零全局副作用）。契约面：
  # - 成功：透传 url_link
  # - errcode 传播（platform_rejected）
  # - 参数形状：path 不带 query + expire_type=1 + expire_interval=30（安全
  #   红线断言——path 若混入 query，微信端静默丢参，落小程序主页）
  # - wechat 未配置：wechat_not_configured 原样传播

  defp mock_urllink(test_pid, resp) do
    Tesla.Mock.mock(fn
      %{method: :post, url: "https://api.weixin.qq.com/wxa/generate_urllink" <> _} = env ->
        send(test_pid, {:urllink_request, Jason.decode!(env.body)})
        resp.()

      %{method: :post, url: "https://api.weixin.qq.com/" <> _} = env ->
        # token 刷新等 SDK 内部调用（未种 token 时不应出现；出现即测试信号）
        send(test_pid, {:unexpected_wechat_call, env.url})
        Tesla.Mock.json(%{"errcode" => 0})
    end)
  end

  describe "create_link/2" do
    test "成功：透传 url_link 且参数形状契约（path 纯路径 + 间隔天数）" do
      mock_urllink(self(), fn ->
        Tesla.Mock.json(%{"url_link" => "https://wxaurl.cn/s/GEN123"})
      end)

      assert {:ok, "https://wxaurl.cn/s/GEN123"} =
               UrlLink.create_link("pages/flashback/index", 30)

      assert_receive {:urllink_request,
                      %{
                        "path" => "pages/flashback/index",
                        "expire_type" => 1,
                        "expire_interval" => 30
                      }}

      refute_receive {:unexpected_wechat_call, _}
    end

    test "微信 errcode：{:error, {:platform_rejected, code, msg}}" do
      mock_urllink(self(), fn ->
        Tesla.Mock.json(%{"errcode" => 40_029, "errmsg" => "invalid code"})
      end)

      assert {:error, {:platform_rejected, 40_029, "invalid code"}} =
               UrlLink.create_link("pages/flashback/index", 30)
    end

    test "非 200 / 网络失败：包成 {:error, {:urllink_failed, _}}" do
      mock_urllink(self(), fn -> {:error, :econnrefused} end)

      assert {:error, {:urllink_failed, {:error, :econnrefused}}} =
               UrlLink.create_link("pages/flashback/index", 30)
    end

    test "wechat 未配置：wechat_not_configured 传播（fail-open 由调用方决定）" do
      original = Application.get_env(:cgc_2046, :miniprogram_platforms)

      on_exit(fn -> Application.put_env(:cgc_2046, :miniprogram_platforms, original) end)

      Application.put_env(:cgc_2046, :miniprogram_platforms, %{})

      assert {:error, :wechat_not_configured} = UrlLink.create_link("pages/flashback/index", 30)
    end
  end
end
