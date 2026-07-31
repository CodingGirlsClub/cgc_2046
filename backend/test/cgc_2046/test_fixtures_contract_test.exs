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

  describe "未实现时给出明确指引" do
    test "seed_user 指向 T02" do
      error = assert_raise RuntimeError, fn -> Cgc2046.TestFixtures.seed_user() end

      assert error.message =~ "T02 全局账号与认证"
    end

    test "seed_token 指向 T02" do
      error = assert_raise RuntimeError, fn -> Cgc2046.TestFixtures.seed_token(%{}) end

      assert error.message =~ "T02 全局账号与认证"
    end

    test "seed_workspace 指向 T03" do
      error = assert_raise RuntimeError, fn -> Cgc2046.TestFixtures.seed_workspace() end

      assert error.message =~ "T03 Workspace 与多租户地基"
    end

    test "seed_membership 指向 T04" do
      error =
        assert_raise RuntimeError, fn ->
          Cgc2046.TestFixtures.seed_membership(%{}, %{})
        end

      assert error.message =~ "T04 成员与角色"
    end
  end
end
