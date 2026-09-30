defmodule Cgc2046.Integrations.Wechat.WebLoginLaunchTest do
  use Cgc2046.DataCase, async: false
  alias Cgc2046.Integrations.Wechat.WebLoginLaunch
  @code "abcdefghijklmnopqrstuv"

  test "mobile link targets the published confirmation page and carries only the public code" do
    Req.Test.stub(Cgc2046.MiniprogramClientStub, fn conn ->
      assert conn.request_path == "/wxa/generate_urllink"
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "path" => "pages/web-login/index",
               "expire_type" => 1,
               "expire_interval" => 1
             }

      Req.Test.json(conn, %{url_link: "https://wxaurl.cn/test"})
    end)

    assert {:ok, %{launch_url: "https://wxaurl.cn/test?cq=wl_" <> @code}} =
             WebLoginLaunch.generate(:link, @code)
  end

  test "failed platform request is not retried or exposed verbatim" do
    parent = self()

    Req.Test.stub(Cgc2046.MiniprogramClientStub, fn conn ->
      send(parent, :launch_called)
      Plug.Conn.send_resp(conn, 503, "sensitive-platform-detail")
    end)

    assert {:error, :mini_web_login_unavailable} = WebLoginLaunch.generate(:qr, @code)
    assert_received :launch_called
    refute_received :launch_called
  end

  test "non-image errors and links outside the official HTTPS hosts fail closed" do
    Req.Test.stub(Cgc2046.MiniprogramClientStub, fn conn ->
      Req.Test.json(conn, %{errcode: 41030})
    end)

    assert {:error, :mini_web_login_unavailable} = WebLoginLaunch.generate(:qr, @code)

    for url <- [
          "https://evil.example/code",
          "http://wxaurl.cn/code",
          "https://wxaurl.cn/code?token=secret"
        ] do
      Req.Test.stub(Cgc2046.MiniprogramClientStub, fn conn ->
        Req.Test.json(conn, %{url_link: url})
      end)

      assert {:error, :mini_web_login_unavailable} = WebLoginLaunch.generate(:link, @code)
    end
  end

  test "image content-type cannot admit arbitrary or oversized QR bodies" do
    for body <- [
          "not an image",
          <<255, 216, 255>> <> :binary.copy(<<0>>, 1_048_576),
          <<137, 80, 78, 71, 13, 10, 26, 10>> <> :binary.copy(<<0>>, 1_048_576)
        ] do
      Req.Test.stub(Cgc2046.MiniprogramClientStub, fn conn ->
        conn |> Plug.Conn.put_resp_content_type("image/jpeg") |> Plug.Conn.send_resp(200, body)
      end)

      assert {:error, :mini_web_login_unavailable} = WebLoginLaunch.generate(:qr, @code)
    end
  end
end
