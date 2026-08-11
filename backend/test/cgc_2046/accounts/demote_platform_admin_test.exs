defmodule Cgc2046.Accounts.DemotePlatformAdminTest do
  @moduledoc """
  `User :demote_platform_admin` action 验收（≥1 admin 不变量唯一入口）。

  不变量依赖全局 admin 计数（SELECT count(*) WHERE is_platform_admin = true），
  且 admin 标记经裸 SQL 写入（同 graphql_admin_queries_test.exs 的 platform_admin
  helper），故 async: false + setup 清理残留标记，保证每个测试从无 admin 状态开始。
  """

  use Cgc2046.DataCase, async: false

  alias Cgc2046.Accounts.PlatformAdminError
  alias Cgc2046.Accounts.User
  alias AshAuthentication.Info, as: AuthInfo

  @password "sup3r-secret-password"

  setup do
    # demote 的 ≥1 admin 约束依赖全局 admin 计数：清掉先前测试（sandbox 外）
    # 残留的 is_platform_admin 标记，保证每个测试从无 admin 状态开始。
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE users SET is_platform_admin = false WHERE is_platform_admin = true"
      )

    :ok
  end

  defp register_user(email) do
    strategy = AuthInfo.strategy!(User, :password)

    assert {:ok, user} =
             AshAuthentication.Strategy.action(strategy, :register, %{
               email: email,
               password: @password
             })

    user
  end

  defp platform_admin(email) do
    user = register_user(email)

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE users SET is_platform_admin = true WHERE id = $1",
        [Ecto.UUID.dump!(user.id)]
      )

    Ash.get!(User, user.id, actor: user, authorize?: false, domain: Cgc2046.GlobalApi)
  end

  # Ash.update 失败返回 %Ash.Error.Invalid{errors: [...]}（含单个 splode error），
  # 取出内层 PlatformAdminError 断言 code。
  defp unwrap_error(%Ash.Error.Invalid{errors: [error | _]}), do: error
  defp unwrap_error(%Ash.Error.Forbidden{errors: [error | _]}), do: error
  defp unwrap_error(error), do: error

  # demote_platform_admin 非 primary update action，须经 for_update 构造 changeset
  # （同 resolver 调 set_platform_admin 的范式）。
  defp demote(user, actor) do
    user
    |> Ash.Changeset.for_update(:demote_platform_admin, %{})
    |> Ash.update(actor: actor)
  end

  describe "demote_platform_admin" do
    test "demotes a non-last platform admin" do
      admin = platform_admin("demote-action-admin@example.com")
      target = platform_admin("demote-action-target@example.com")

      assert {:ok, user} = demote(target, admin)
      refute user.is_platform_admin

      reloaded = Ash.get!(User, target.id, authorize?: false)
      refute reloaded.is_platform_admin
      # 另一 admin 不受影响
      assert Ash.get!(User, admin.id, authorize?: false).is_platform_admin
    end

    test "rejects demoting the last remaining platform admin" do
      admin = platform_admin("demote-action-last@example.com")

      assert {:error, error} = demote(admin, admin)
      assert %PlatformAdminError{code: "last_admin_denied"} = unwrap_error(error)

      reloaded = Ash.get!(User, admin.id, authorize?: false)
      assert reloaded.is_platform_admin
    end

    test "rejects demoting a non-admin user" do
      admin = platform_admin("demote-action-admin2@example.com")
      target = register_user("demote-action-nonadmin@example.com")

      assert {:error, error} = demote(target, admin)
      assert %PlatformAdminError{code: "not_platform_admin"} = unwrap_error(error)

      reloaded = Ash.get!(User, target.id, authorize?: false)
      refute reloaded.is_platform_admin
    end

    test "forbids non-platform-admin actor" do
      admin = platform_admin("demote-action-admin3@example.com")
      regular = register_user("demote-action-regular@example.com")

      assert {:error, error} = demote(admin, regular)
      assert %Ash.Error.Forbidden{} = error

      reloaded = Ash.get!(User, admin.id, authorize?: false)
      assert reloaded.is_platform_admin
    end

    test "forbids non-platform-admin actor without side effects (write happens after authorize)" do
      admin = platform_admin("demote-action-admin4@example.com")
      target = platform_admin("demote-action-target4@example.com")
      regular = register_user("demote-action-regular4@example.com")

      # 多个 admin 存在时，若 change 在授权前写 DB，普通用户可借 action 降级 admin；
      # before_action 保证授权先于原子判定执行，普通用户只能拿到 Forbidden。
      assert {:error, error} = demote(target, regular)
      assert %Ash.Error.Forbidden{} = error

      assert Ash.get!(User, target.id, authorize?: false).is_platform_admin
      assert Ash.get!(User, admin.id, authorize?: false).is_platform_admin
    end
  end
end
