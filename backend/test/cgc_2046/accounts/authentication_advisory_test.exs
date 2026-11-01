defmodule Cgc2046.Accounts.AuthenticationAdvisoryTest do
  use ExUnit.Case, async: true

  alias AshAuthentication.Info
  alias Cgc2046.Accounts.User

  test "the Assent Apple advisory exception remains limited to non-OAuth strategies" do
    assert Mix.Project.config()[:hex][:ignore_advisories] == ["EEF-CVE-2026-117656"]

    assert AshAuthentication.authenticated_resources(:cgc_2046) == [User]

    strategies =
      User
      |> Info.authentication_strategies()
      |> Enum.map(&{&1.name, &1.__struct__})
      |> Enum.sort()

    assert strategies == [
             {:miniprogram, Cgc2046.Accounts.Strategies.Miniprogram},
             {:password, AshAuthentication.Strategy.Password},
             {:password_phone, AshAuthentication.Strategy.Password}
           ]
  end
end
