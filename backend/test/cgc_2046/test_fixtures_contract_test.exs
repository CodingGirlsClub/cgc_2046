defmodule Cgc2046.TestFixturesContractTest do
  @moduledoc """
  T01 切片C:TestFixtures 种子帮助函数契约。

  T01 阶段资源(User/Token/Workspace/Membership)尚未落地,种子帮助函数只
  建立契约;本测试锁定契约(函数存在、arity 正确、未实现时给出指向对应
  票据的明确错误),防止后续票据改动签名时静默破坏共享夹具。
  """

  use Cgc2046.DataCase, async: true

  describe "seed 帮助函数契约" do
    test "导出 seed_user/1" do
      assert function_exported?(Cgc2046.TestFixtures, :seed_user, 1)
    end

    test "导出 seed_token/2" do
      assert function_exported?(Cgc2046.TestFixtures, :seed_token, 2)
    end

    test "导出 seed_workspace/1" do
      assert function_exported?(Cgc2046.TestFixtures, :seed_workspace, 1)
    end

    test "导出 seed_membership/3" do
      assert function_exported?(Cgc2046.TestFixtures, :seed_membership, 3)
    end
  end

  describe "T02 落地后 seed_user/seed_token 可用" do
    test "seed_user 创建用户并返回 User 记录" do
      user = Cgc2046.TestFixtures.seed_user()
      assert %Cgc2046.Accounts.User{} = user
      assert to_string(user.email) =~ "@example.com"
    end

    test "seed_user 支持自定义 email" do
      user = Cgc2046.TestFixtures.seed_user(email: "custom@example.com")
      assert to_string(user.email) == "custom@example.com"
    end

    test "seed_token 返回可放入 Bearer 头的 token" do
      user = Cgc2046.TestFixtures.seed_user()
      token = Cgc2046.TestFixtures.seed_token(user)
      assert is_binary(token) and byte_size(token) > 0
    end
  end

  describe "T03 落地后 seed_platform_admin/seed_workspace 可用" do
    test "seed_platform_admin 创建平台管理员" do
      admin = Cgc2046.TestFixtures.seed_platform_admin()
      assert %Cgc2046.Accounts.User{is_platform_admin: true} = admin
    end

    test "seed_workspace 创建 Workspace 并返回记录" do
      admin = Cgc2046.TestFixtures.seed_platform_admin()
      ws = Cgc2046.TestFixtures.seed_workspace(owner: admin)

      assert %Cgc2046.Workspaces.Workspace{} = ws
      assert ws.owner_id == admin.id
    end
  end

  describe "T04 落地后 seed_membership 可用" do
    test "seed_membership 创建成员并可带角色" do
      admin = Cgc2046.TestFixtures.seed_platform_admin()
      ws = Cgc2046.TestFixtures.seed_workspace(owner: admin)
      user = Cgc2046.TestFixtures.seed_user()

      membership = Cgc2046.TestFixtures.seed_membership(user, ws, roles: ["Learner"])

      assert %Cgc2046.Workspaces.WorkspaceMembership{} = membership
      assert membership.user_id == user.id

      loaded =
        Ash.get!(Cgc2046.Workspaces.WorkspaceMembership, membership.id,
          tenant: ws.id,
          authorize?: false,
          load: [:roles]
        )

      assert Enum.map(loaded.roles, & &1.name) == ["Learner"]
    end
  end
end
