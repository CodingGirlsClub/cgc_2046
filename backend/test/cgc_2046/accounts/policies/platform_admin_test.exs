defmodule Cgc2046.Accounts.Policies.PlatformAdminTest do
  use ExUnit.Case, async: true

  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.Policies.PlatformAdmin

  describe "platform_admin?/1（纯谓词，fail-closed）" do
    test "nil → false" do
      refute PlatformAdmin.platform_admin?(nil)
    end

    test "is_platform_admin: false → false" do
      refute PlatformAdmin.platform_admin?(%User{is_platform_admin: false})
    end

    test "is_platform_admin: true → true" do
      assert PlatformAdmin.platform_admin?(%User{is_platform_admin: true})
    end

    test "缺失字段（%{}）→ false" do
      refute PlatformAdmin.platform_admin?(%{})
    end
  end

  describe "match?/3（Ash check interface）" do
    test "匿名 actor → false" do
      refute PlatformAdmin.match?(nil, %{query: %Ash.Query{}}, [])
    end

    test "非平台管理员 → false" do
      refute PlatformAdmin.match?(%User{is_platform_admin: false}, %{query: %Ash.Query{}}, [])
    end

    test "平台管理员 → true" do
      assert PlatformAdmin.match?(%User{is_platform_admin: true}, %{query: %Ash.Query{}}, [])
    end
  end
end
