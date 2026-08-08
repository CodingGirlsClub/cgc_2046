defmodule Cgc2046.Mcp.TokenRaceTest do
  @moduledoc """
  连接 token 撤销竞态回归测试（/check review BLOCKING 项）。

  背景：`:revoke` 的 before_action 守卫读的是内存副本 `cs.data.revoked_at`——
  并发请求或陈旧 struct 持有的都是撤销前数据，双双通过守卫，后写覆盖审计时间戳。
  修复（对齐 pending_operation.ex 的 MEDIUM-1 范式）：`Ash.Changeset.filter` 把
  `is_nil(revoked_at)` 编进 UPDATE 的 WHERE，数据库层保证至多一个成功。

  async: false —— 并发任务需共享 sandbox 连接（同 confirmation_race_test.exs 惯例）。
  """
  use Cgc2046.DataCase, async: false

  alias Cgc2046.Mcp.Token

  defp register_user(email) do
    strategy = AshAuthentication.Info.strategy!(Cgc2046.Accounts.User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :register, %{
        email: email,
        password: "sup3r-secret-password"
      })

    user
  end

  defp issue(user, name) do
    {:ok, token} =
      Token
      |> Ash.Changeset.for_create(:issue, %{name: name}, actor: user)
      |> Ash.create()

    token
  end

  test "陈旧副本重撤：必须报错且 revoked_at 不被改写" do
    user = register_user("race-revoke-stale@example.com")
    stale = issue(user, "stale-copy")

    # 正常路径撤销（模拟 resolver：每次请求重新 get）
    fresh = Ash.get!(Token, stale.id, actor: user)

    assert {:ok, revoked} =
             fresh
             |> Ash.Changeset.for_update(:revoke, %{}, actor: user)
             |> Ash.update()

    first_revoked_at = revoked.revoked_at
    assert first_revoked_at

    # 用撤销前签发的陈旧 struct 再撤一次（双标签页/重试携带旧数据）
    Process.sleep(1100)

    assert {:error, _} =
             stale
             |> Ash.Changeset.for_update(:revoke, %{}, actor: user)
             |> Ash.update()

    reloaded = Ash.get!(Token, stale.id, authorize?: false)
    assert reloaded.revoked_at == first_revoked_at
  end

  test "8 路并发撤销（各自独立 get，resolver 同路径）：恰好一个成功" do
    user = register_user("race-revoke-concurrent@example.com")
    token = issue(user, "concurrent")

    results =
      1..8
      |> Task.async_stream(
        fn _ ->
          {:ok, fetched} = Ash.get(Token, token.id, actor: user)

          fetched
          |> Ash.Changeset.for_update(:revoke, %{}, actor: user)
          |> Ash.update()
        end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, r} -> r end)

    oks = Enum.count(results, &match?({:ok, _}, &1))
    errs = Enum.count(results, &match?({:error, _}, &1))

    assert oks == 1
    assert errs == 7

    reloaded = Ash.get!(Token, token.id, authorize?: false)
    assert reloaded.revoked_at
  end
end
