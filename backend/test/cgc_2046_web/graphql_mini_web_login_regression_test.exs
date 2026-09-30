defmodule Cgc2046Web.GraphqlMiniWebLoginRegressionTest do
  use Cgc2046Web.ConnCase, async: false
  alias Cgc2046Web.Plugs.RateLimit

  setup do
    :ets.delete_all_objects(RateLimit.table())
    :ok
  end

  defp http(query) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("origin", Application.fetch_env!(:cgc_2046, :web_base_url))
    |> post("/api/graphql", %{query: query})
    |> json_response(200)
  end

  test "QR start accepts a successful JPEG image without relabelling it as PNG" do
    # Public repository QR image copied as a self-contained backend fixture.
    jpeg = File.read!("test/fixtures/mini_web_login_qr.jpg")
    assert <<255, 216, 255, _::binary>> = jpeg

    Req.Test.stub(Cgc2046.MiniprogramClientStub, fn conn ->
      conn |> put_resp_content_type("image/jpeg") |> send_resp(200, jpeg)
    end)

    result = http("mutation { wechatMiniWebLoginStart(mode: QR) { status qrDataUrl } }")
    refute result["errors"]

    assert %{"status" => "PENDING", "qrDataUrl" => "data:image/jpeg;base64," <> encoded} =
             result["data"]["wechatMiniWebLoginStart"]

    assert Base.decode64!(encoded) == jpeg
  end

  test "rate-limited anonymous previews cannot allocate more per-code keys" do
    for n <- 1..120 do
      result = preview(n)
      assert [%{"code" => "mini_web_login_invalid"}] = result["errors"]
    end

    before_count = :ets.info(RateLimit.table(), :size)

    for n <- 121..220 do
      assert [%{"code" => "rate_limited"}] = preview(n)["errors"]
    end

    assert :ets.info(RateLimit.table(), :size) == before_count
  end

  test "rate-limited starts without a proof cannot allocate more browser keys" do
    Req.Test.stub(Cgc2046.MiniprogramClientStub, fn conn ->
      conn
      |> put_resp_content_type("image/png")
      |> send_resp(200, <<137, 80, 78, 71, 13, 10, 26, 10>>)
    end)

    query = "mutation { wechatMiniWebLoginStart(mode: QR) { status } }"
    for _ <- 1..60, do: refute(http(query)["errors"])

    before_count = :ets.info(RateLimit.table(), :size)

    for _ <- 1..100 do
      assert [%{"code" => "rate_limited"}] = http(query)["errors"]
    end

    assert :ets.info(RateLimit.table(), :size) == before_count
  end

  defp preview(n) do
    code = Base.url_encode64(<<n::128>>, padding: false)
    http("{ wechatMiniWebLoginPreview(requestId: \"#{code}\") { status } }")
  end
end
