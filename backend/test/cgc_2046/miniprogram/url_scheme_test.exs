defmodule Cgc2046.Miniprogram.UrlSchemeTest do
  use Cgc2046.DataCase, async: false

  alias Cgc2046.Miniprogram.UrlScheme

  describe "create_event_link/3" do
    test "成功：返回 openlink，且请求体携带 jump_wxa 与到期失效参数（SDK 覆盖验证）" do
      test_pid = self()

      Tesla.Mock.mock(fn
        %{method: :post, url: "https://api.weixin.qq.com/wxa/generatescheme" <> _} = env ->
          send(test_pid, {:scheme_request, Jason.decode!(env.body)})
          Tesla.Mock.json(%{"openlink" => "weixin://dl/business/?t=TEST"})
      end)

      expires_at = DateTime.add(DateTime.utc_now(), 7, :day)

      assert {:ok, "weixin://dl/business/?t=TEST"} =
               UrlScheme.create_event_link("event-123", "event", expires_at)

      assert_receive {:scheme_request,
                      %{
                        "jump_wxa" => %{
                          "path" => "/pages/event-detail/index",
                          "query" => "id=event-123&kind=event"
                        },
                        "is_expire" => true,
                        "expire_time" => unix
                      }}

      assert DateTime.to_unix(expires_at) == unix
    end

    test "成功：expires_at 为 nil 时走永久 scheme（不传 is_expire），且 kind 透传" do
      test_pid = self()

      Tesla.Mock.mock(fn
        %{method: :post, url: "https://api.weixin.qq.com/wxa/generatescheme" <> _} = env ->
          send(test_pid, {:scheme_request, Jason.decode!(env.body)})
          Tesla.Mock.json(%{"openlink" => "weixin://dl/business/?t=PERM"})
      end)

      assert {:ok, "weixin://dl/business/?t=PERM"} =
               UrlScheme.create_event_link("event-456", "course")

      assert_receive {:scheme_request, body}
      assert body["jump_wxa"]["query"] == "id=event-456&kind=course"
      refute Map.has_key?(body, "is_expire")
    end

    test "errcode 保真：平台拒绝原样透传" do
      Tesla.Mock.mock(fn
        %{method: :post, url: "https://api.weixin.qq.com/wxa/generatescheme" <> _} ->
          Tesla.Mock.json(%{
            "errcode" => 44990,
            "errmsg" => "reach max api second frequence limit"
          })
      end)

      assert {:error, {:platform_rejected, 44990, "reach max api second frequence limit"}} =
               UrlScheme.create_event_link("event-789", "course")
    end

    test "非 200 或异常响应归为 scheme_failed" do
      Tesla.Mock.mock(fn
        %{method: :post, url: "https://api.weixin.qq.com/wxa/generatescheme" <> _} ->
          %Tesla.Env{status: 500, body: "boom"}
      end)

      assert {:error, {:scheme_failed, _}} = UrlScheme.create_event_link("event-abc", "event")
    end
  end
end
