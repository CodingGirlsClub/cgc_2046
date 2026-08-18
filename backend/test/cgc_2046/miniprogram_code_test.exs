defmodule Cgc2046.MiniprogramCodeTest do
  use Cgc2046.DataCase, async: false

  alias Cgc2046.Accounts.Invitation
  alias Cgc2046.Miniprogram.Client
  alias Cgc2046.MiniprogramCode
  alias Cgc2046.AccountsFixtures, as: Fixtures

  setup do
    test_pid = self()

    Req.Test.stub(Cgc2046.MiniprogramClientStub, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.host, conn.request_path} do
        {"open.douyin.com", "/oauth/client_token/"} ->
          Req.Test.json(conn, %{"data" => %{"access_token" => "tt-code-token"}})

        {"open.douyin.com", "/api/apps/v1/qrcode/create/"} ->
          Req.Test.json(conn, %{
            "err_no" => 0,
            "data" => %{"img" => Base.encode64("tt-code")}
          })

        {"miniapp.xiaohongshu.com", "/api/rmp/token"} ->
          Req.Test.json(conn, %{"code" => 0, "data" => %{"access_token" => "xhs-code-token"}})

        {"miniapp.xiaohongshu.com", "/api/rmp/qrcode/unlimited"} ->
          Req.Test.json(conn, %{
            "code" => 0,
            "data" => %{"base64" => Base.encode64("xhs-code")}
          })

        other ->
          raise "unexpected miniprogram code request: #{inspect(other)}"
      end
    end)

    # wechat 码走 SDK client（宿主 WechatRequester + Tesla.Mock）；
    # mock fun 内回传请求体，断言 page/check_path/scene 由用例完成。
    Tesla.Mock.mock(fn
      %{method: :post, url: "https://api.weixin.qq.com/wxa/getwxacodeunlimit" <> _} = env ->
        send(test_pid, {:code_request, Jason.decode!(env.body)})

        %Tesla.Env{
          status: 200,
          body: <<137, 80, 78, 71, 1, 2, 3>>,
          headers: [{"content-type", "image/jpeg"}]
        }
    end)

    :ok
  end

  test "生成 scene 符合约束并缓存 invitation/platform 的平台码" do
    admin = Fixtures.platform_admin("code-cache-admin")
    workspace = Fixtures.create_workspace(admin)
    invitation = create_invitation(workspace, admin)

    assert {:ok, first} = MiniprogramCode.generate_for_invitation(invitation, :wechat)
    assert first.scene =~ ~r/^[A-Za-z0-9_]{1,32}$/
    assert first.code == <<137, 80, 78, 71, 1, 2, 3>>
    assert_receive {:code_request, %{"scene" => scene}}
    assert scene == first.scene

    assert {:ok, second} = MiniprogramCode.generate_for_invitation(invitation, :wechat)
    assert second.id == first.id
    refute_receive {:code_request, _}
  end

  test "每日配额以 Postgres 原子计数守卫" do
    old_limit = Application.get_env(:cgc_2046, :miniprogram_code_daily_limit, 100_000)
    Application.put_env(:cgc_2046, :miniprogram_code_daily_limit, 1)
    on_exit(fn -> Application.put_env(:cgc_2046, :miniprogram_code_daily_limit, old_limit) end)

    admin = Fixtures.platform_admin("code-quota-admin")
    workspace = Fixtures.create_workspace(admin)

    assert {:ok, _} =
             workspace
             |> create_invitation(admin)
             |> MiniprogramCode.generate_for_invitation(:wechat)

    assert {:error, :daily_quota_exhausted} =
             workspace
             |> create_invitation(admin)
             |> MiniprogramCode.generate_for_invitation(:wechat)
  end

  test "三平台小程序码 adapter 归一为图片字节" do
    assert {:ok, <<137, 80, 78, 71, 1, 2, 3>>} = Client.generate_code(:wechat, "SCENE_1")
    assert {:ok, "tt-code"} = Client.generate_code(:tt, "SCENE_2")
    assert {:ok, "xhs-code"} = Client.generate_code(:xhs, "SCENE_3")

    # 落页契约（本计划修正项）：码统一落 join（三端注册且消费 scene）；
    # check_path=false——page 为前端裁剪路径，无需微信侧校验线上版本。
    assert_receive {:code_request,
                    %{"scene" => "SCENE_1", "page" => "pages/join/index", "check_path" => false}}
  end

  test "wechat 41030 页面无效：errcode 保真出栈" do
    Tesla.Mock.mock(fn
      %{method: :post, url: "https://api.weixin.qq.com/wxa/getwxacodeunlimit" <> _} ->
        Tesla.Mock.json(%{"errcode" => 41030, "errmsg" => "invalid page"})
    end)

    assert {:error, {:platform_rejected, 41030, "invalid page"}} =
             Client.generate_code(:wechat, "SCENE_41030")
  end

  defp create_invitation(workspace, actor) do
    Invitation
    |> Ash.Changeset.for_create(:create, %{
      workspace_id: workspace.id,
      inviter_id: actor.id,
      expires_at: DateTime.add(DateTime.utc_now(), 7, :day),
      preauthorized_role_names: []
    })
    |> Ash.create!(actor: actor)
  end
end
