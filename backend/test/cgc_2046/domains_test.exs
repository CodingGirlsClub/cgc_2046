defmodule Cgc2046.DomainsTest do
  use ExUnit.Case, async: true

  test "Api, Admission and GlobalApi domains are loaded with the AshGraphQL extension" do
    assert Code.ensure_loaded?(Cgc2046.Api)
    assert Code.ensure_loaded?(Cgc2046.Admission)
    assert Code.ensure_loaded?(Cgc2046.GlobalApi)
  end

  test "all five domains are registered as Ash domains for the app" do
    ash_domains = Application.get_env(:cgc_2046, :ash_domains, [])

    assert Cgc2046.Api in ash_domains
    assert Cgc2046.Admission in ash_domains
    assert Cgc2046.GlobalApi in ash_domains
  end

  test "Repo is an AshPostgres.Repo (data layer ready)" do
    assert function_exported?(Cgc2046.Repo, :installed_extensions, 0)
  end
end
