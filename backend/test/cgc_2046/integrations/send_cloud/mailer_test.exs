defmodule Cgc2046.Integrations.SendCloud.MailerTest do
  use ExUnit.Case, async: false

  import Swoosh.Email

  alias Cgc2046.Integrations.SendCloud.Mailer

  @stub __MODULE__
  @config [
    api_user: "test-api-user",
    api_key: "test-api-key",
    from: "noreply@example.com",
    from_name: "CGC 2046"
  ]

  test "returns response body when SendCloud accepts the message and encodes form fields" do
    register_stub(fn conn, test_pid ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.request_path, URI.decode_query(body)})
      Req.Test.json(conn, %{"result" => true, "info" => "message-id"})
    end)

    assert {:ok, %{"result" => true, "info" => "message-id"}} = deliver()

    assert_receive {:request, "/apiv2/mail/send", form}
    assert form["apiUser"] == "test-api-user"
    assert form["apiKey"] == "test-api-key"
    assert form["from"] == "noreply@example.com"
    assert form["fromName"] == "CGC 2046"
    assert form["to"] == "recipient@example.com"
    assert form["subject"] == "Reset your password"
    assert form["html"] == "<p>Reset</p>"
  end

  test "returns an error when SendCloud reports a failed result" do
    register_stub(fn conn, _test_pid ->
      Req.Test.json(conn, %{"result" => false, "message" => "invalid credentials"})
    end)

    assert {:error, _reason} = deliver()
  end

  test "returns an error for HTTP failures and transport timeouts" do
    register_stub(fn conn, _test_pid -> Plug.Conn.send_resp(conn, 503, "unavailable") end)
    assert {:error, _reason} = deliver()

    register_stub(fn conn, _test_pid -> Req.Test.transport_error(conn, :timeout) end)
    assert {:error, _reason} = deliver()
  end

  defp register_stub(handler) do
    test_pid = self()
    Req.Test.stub(@stub, fn conn -> handler.(conn, test_pid) end)
  end

  defp deliver do
    email =
      new()
      |> from("sender@example.com")
      |> to("recipient@example.com")
      |> subject("Reset your password")
      |> html_body("<p>Reset</p>")

    Mailer.deliver(email, @config ++ [req_options: [plug: {Req.Test, @stub}]])
  end
end
