defmodule Cgc2046.Accounts.PasswordResetTest do
  use Cgc2046.DataCase, async: false

  alias AshAuthentication.{Info, Strategy}
  alias AshAuthentication.Strategy.Password
  alias Cgc2046.Accounts.{SendPasswordResetEmail, User}
  alias Cgc2046.AccountsFixtures, as: Fixtures

  @telemetry_event [:cgc2046, :password_reset, :send_email]

  defmodule FailingAdapter do
    use Swoosh.Adapter

    @impl true
    def deliver(_email, _config), do: {:error, :send_cloud_timeout}
  end

  setup do
    Application.put_env(:cgc_2046, :web_base_url, "http://localhost:3000")

    on_exit(fn ->
      Application.delete_env(:cgc_2046, Cgc2046.Mailer)
      Application.put_env(:cgc_2046, Cgc2046.Mailer, adapter: Swoosh.Adapters.Test)
      Application.put_env(:cgc_2046, :web_base_url, "http://localhost:3000")
    end)

    :ok
  end

  test "requesting a reset sends a one-time 24-hour email without rendering display_name" do
    user = Fixtures.register_user("password-reset-email")
    user = %{user | display_name: "<img src=x onerror=alert(1)>"}

    assert :ok = Strategy.action(strategy(), :reset_request, %{"email" => to_string(user.email)})

    assert_receive {:email, email}, 1_000
    assert {_name, address} = List.first(email.to)
    assert address == to_string(user.email)
    assert email.from == {"CGC 2046", "no-reply@example.com"}
    assert email.html_body =~ "24 小时"
    assert email.html_body =~ "仅可使用一次"
    assert email.html_body =~ "如果这不是你的操作，请忽略本邮件"
    assert email.html_body =~ "CGC 2046"
    refute email.html_body =~ "<img"
    refute email.html_body =~ "%"
  end

  test "requesting a reset for an unknown email is a silent success with no email" do
    assert :ok = Strategy.action(strategy(), :reset_request, %{"email" => "missing@example.com"})
    refute_receive {:email, _email}, 100
  end

  test "multiple reset links can be issued and the first successful reset revokes the other" do
    user = Fixtures.register_user("password-reset-multiple")
    first_token = reset_token(user)
    second_token = reset_token(user)

    assert {:ok, _updated} =
             Strategy.action(strategy(), :reset, reset_params(first_token, "new-password-1"))

    assert {:error, %AshAuthentication.Errors.InvalidToken{}} =
             Strategy.action(strategy(), :reset, reset_params(second_token, "new-password-2"))

    assert {:ok, _signed_in} =
             Strategy.action(strategy(), :sign_in, %{
               "email" => to_string(user.email),
               "password" => "new-password-1"
             })
  end

  test "a reset token is one-time and weak passwords do not consume it" do
    user = Fixtures.register_user("password-reset-token")
    token = reset_token(user)

    assert {:error, %Ash.Error.Invalid{}} =
             Strategy.action(strategy(), :reset, reset_params(token, "short"))

    assert {:ok, _updated} =
             Strategy.action(strategy(), :reset, reset_params(token, "valid-password-1"))

    assert {:error, %AshAuthentication.Errors.InvalidToken{}} =
             Strategy.action(strategy(), :reset, reset_params(token, "valid-password-2"))
  end

  test "mailer failures are swallowed and telemetry contains only masked email and reason" do
    user = Fixtures.register_user("password-reset-failure")
    test_pid = self()
    handler_id = "password-reset-email-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        @telemetry_event,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:password_reset_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    Application.put_env(:cgc_2046, Cgc2046.Mailer, adapter: FailingAdapter)

    assert :ok = SendPasswordResetEmail.send(user, "secret-reset-token")
    assert_receive {:password_reset_telemetry, @telemetry_event, %{count: 1}, metadata}, 1_000
    assert metadata.reason == :send_cloud_timeout
    assert metadata.email == "p***@example.com"
    refute inspect(metadata) =~ "secret-reset-token"
    refute inspect(metadata) =~ to_string(user.email)
  end

  defp strategy, do: Info.strategy!(User, :password)

  defp reset_token(user) do
    {:ok, token} = Password.reset_token_for(strategy(), user)
    token
  end

  defp reset_params(token, password) do
    %{
      "reset_token" => token,
      "password" => password
    }
  end
end
