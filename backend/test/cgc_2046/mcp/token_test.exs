defmodule Cgc2046.Mcp.TokenTest do
  @moduledoc """
  连接 token（MCP Bearer token，D13/D-D4）资源行为测试。

  关键约束：
  - 明文 token 仅创建时经 metadata 一次性返回，不落库；库中只存 SHA256 hash
  - 绑用户不绑工作区
  - 撤销后不可再用（validate_token 拒绝）
  - 用户只能读/撤自己的 token（越权 Forbidden）
  """
  use Cgc2046.DataCase, async: true

  require Ash.Query

  alias Cgc2046.Mcp.Token
  alias Cgc2046.AccountsFixtures, as: Fixtures

  describe "issue（签发）" do
    test "签发成功：hash 落库，明文仅在 metadata.plain_token 一次性返回" do
      user = Fixtures.register_user("mcp-token-1")

      assert {:ok, token} =
               Token
               |> Ash.Changeset.for_create(:issue, %{name: "我的 Mac"}, actor: user)
               |> Ash.create()

      # 明文一次性返回
      plain = token.__metadata__[:plain_token]
      assert is_binary(plain)
      assert byte_size(plain) > 20

      # 库中只存 hash，且 hash != 明文
      assert token.token_hash != plain

      expected_hash = :crypto.hash(:sha256, plain) |> Base.encode16(case: :lower)
      assert token.token_hash == expected_hash

      # 归属与默认值
      assert token.user_id == user.id
      assert token.name == "我的 Mac"
      assert is_nil(token.revoked_at)
      assert is_nil(token.last_used_at)
    end

    test "同一用户可持有多个 token（D-D4：撤销粒度按 token）" do
      user = Fixtures.register_user("mcp-token-2")

      assert {:ok, _t1} =
               Token
               |> Ash.Changeset.for_create(:issue, %{name: "A"}, actor: user)
               |> Ash.create()

      assert {:ok, _t2} =
               Token
               |> Ash.Changeset.for_create(:issue, %{name: "B"}, actor: user)
               |> Ash.create()
    end

    test "active token 达 10 个上限后拒绝签发；撤销一个后可再签" do
      user = Fixtures.register_user("mcp-token-cap")

      for i <- 1..10 do
        assert {:ok, _} =
                 Token
                 |> Ash.Changeset.for_create(:issue, %{name: "t#{i}"}, actor: user)
                 |> Ash.create()
      end

      assert {:error, %Ash.Error.Invalid{} = error} =
               Token
               |> Ash.Changeset.for_create(:issue, %{name: "over"}, actor: user)
               |> Ash.create()

      assert Exception.message(error) =~ "active connection token limit reached"

      # 撤销一个后恢复可签（上限按 active 计数）
      first =
        Token
        |> Ash.Query.filter(user_id == ^user.id and name == "t1")
        |> Ash.read_one!(actor: user)

      assert {:ok, _} =
               first
               |> Ash.Changeset.for_update(:revoke, %{}, actor: user)
               |> Ash.update()

      assert {:ok, _} =
               Token
               |> Ash.Changeset.for_create(:issue, %{name: "after-revoke"}, actor: user)
               |> Ash.create()
    end

    test "未认证 actor 不能签发" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Token
               |> Ash.Changeset.for_create(:issue, %{name: "X"})
               |> Ash.create()
    end
  end

  describe "validate_token（MCP 鉴权路径）" do
    test "有效明文 token → 返回所属 user" do
      user = Fixtures.register_user("mcp-token-3")

      {:ok, token} =
        Token |> Ash.Changeset.for_create(:issue, %{name: "A"}, actor: user) |> Ash.create()

      assert {:ok, found} = Token.validate_token(token.__metadata__[:plain_token])
      assert found.id == user.id
    end

    test "错误 token → :error" do
      assert :error = Token.validate_token("not-a-real-token")
    end

    test "已撤销 token → :error" do
      user = Fixtures.register_user("mcp-token-4")

      {:ok, token} =
        Token |> Ash.Changeset.for_create(:issue, %{name: "A"}, actor: user) |> Ash.create()

      plain = token.__metadata__[:plain_token]

      assert {:ok, _} =
               token |> Ash.Changeset.for_update(:revoke, %{}, actor: user) |> Ash.update()

      assert :error = Token.validate_token(plain)
    end

    test "validate_token 触碰 last_used_at" do
      user = Fixtures.register_user("mcp-token-5")

      {:ok, token} =
        Token |> Ash.Changeset.for_create(:issue, %{name: "A"}, actor: user) |> Ash.create()

      assert {:ok, _user} = Token.validate_token(token.__metadata__[:plain_token])

      updated = Ash.get!(Token, token.id, authorize?: false)
      assert %DateTime{} = updated.last_used_at
    end
  end

  describe "滚动过期（#222：连续 90 天未使用即失效）" do
    # 直改库回拨时间（绕过 Ash action；先例：pending_operation_test.exs「已过期」用例）。
    # 属性精度不同：last_used_at 是 :utc_datetime（秒，微秒须空），inserted_at 是 usec。
    defp backdate(token, fields) do
      changes =
        Map.new(fields, fn
          {:last_used_at, days} ->
            {:last_used_at,
             DateTime.utc_now() |> DateTime.add(days, :day) |> DateTime.truncate(:second)}

          {field, days} ->
            {field, DateTime.add(DateTime.utc_now(), days, :day)}
        end)

      token |> change(changes) |> Repo.update!()
    end

    test "新签发 token（inserted_at ≈ now，从未使用）→ validate_token 通过" do
      user = Fixtures.register_user("mcp-token-idle-fresh")

      {:ok, token} =
        Token |> Ash.Changeset.for_create(:issue, %{name: "A"}, actor: user) |> Ash.create()

      assert {:ok, found} = Token.validate_token(token.__metadata__[:plain_token])
      assert found.id == user.id
    end

    test "从未使用，inserted_at 回拨 -91 天 → :error" do
      user = Fixtures.register_user("mcp-token-idle-91")

      {:ok, token} =
        Token |> Ash.Changeset.for_create(:issue, %{name: "A"}, actor: user) |> Ash.create()

      backdate(token, inserted_at: -91)
      assert :error = Token.validate_token(token.__metadata__[:plain_token])
    end

    test "边界：inserted_at 恰 -90 天 → :error（距今 >= 90 天即失效）" do
      user = Fixtures.register_user("mcp-token-idle-90")

      {:ok, token} =
        Token |> Ash.Changeset.for_create(:issue, %{name: "A"}, actor: user) |> Ash.create()

      backdate(token, inserted_at: -90)
      assert :error = Token.validate_token(token.__metadata__[:plain_token])
    end

    test "活动重置窗口：inserted_at -100 天 + last_used_at -1 天 → 通过（锚点取 last_used_at）" do
      user = Fixtures.register_user("mcp-token-idle-anchor")

      {:ok, token} =
        Token |> Ash.Changeset.for_create(:issue, %{name: "A"}, actor: user) |> Ash.create()

      backdate(token, inserted_at: -100, last_used_at: -1)

      assert {:ok, found} = Token.validate_token(token.__metadata__[:plain_token])
      assert found.id == user.id
    end

    test "过期行未被动过：revoked_at 仍 nil 且不 touch last_used_at（过期 ≠ 撤销）" do
      user = Fixtures.register_user("mcp-token-idle-audit")

      {:ok, token} =
        Token |> Ash.Changeset.for_create(:issue, %{name: "A"}, actor: user) |> Ash.create()

      backdate(token, inserted_at: -91)
      assert :error = Token.validate_token(token.__metadata__[:plain_token])

      reloaded = Ash.get!(Token, token.id, authorize?: false)
      assert is_nil(reloaded.revoked_at)
      assert is_nil(reloaded.last_used_at)
    end
  end

  describe "revoke（撤销）" do
    test "本人可撤销自己的 token" do
      user = Fixtures.register_user("mcp-token-6")

      {:ok, token} =
        Token |> Ash.Changeset.for_create(:issue, %{name: "A"}, actor: user) |> Ash.create()

      assert {:ok, revoked} =
               token |> Ash.Changeset.for_update(:revoke, %{}, actor: user) |> Ash.update()

      assert %DateTime{} = revoked.revoked_at
    end

    test "他人不可撤销（Forbidden）" do
      owner = Fixtures.register_user("mcp-token-7")
      other = Fixtures.register_user("mcp-token-8")

      {:ok, token} =
        Token |> Ash.Changeset.for_create(:issue, %{name: "A"}, actor: owner) |> Ash.create()

      assert {:error, %Ash.Error.Forbidden{}} =
               token |> Ash.Changeset.for_update(:revoke, %{}, actor: other) |> Ash.update()
    end

    test "重复撤销被拒绝" do
      user = Fixtures.register_user("mcp-token-9")

      {:ok, token} =
        Token |> Ash.Changeset.for_create(:issue, %{name: "A"}, actor: user) |> Ash.create()

      assert {:ok, revoked} =
               token |> Ash.Changeset.for_update(:revoke, %{}, actor: user) |> Ash.update()

      assert {:error, _} =
               revoked |> Ash.Changeset.for_update(:revoke, %{}, actor: user) |> Ash.update()
    end
  end

  describe "read（列表）" do
    test "只能读到自己的 token" do
      u1 = Fixtures.register_user("mcp-token-10")
      u2 = Fixtures.register_user("mcp-token-11")

      {:ok, _} =
        Token |> Ash.Changeset.for_create(:issue, %{name: "u1"}, actor: u1) |> Ash.create()

      {:ok, _} =
        Token |> Ash.Changeset.for_create(:issue, %{name: "u2"}, actor: u2) |> Ash.create()

      mine = Token |> Ash.read!(actor: u1)
      assert length(mine) == 1
      assert hd(mine).name == "u1"
    end
  end

  describe "语义函数（list_for/issue/revoke）" do
    test "list_for/1：返回本人 token，新→旧排序" do
      user = Fixtures.register_user("mcp-token-12")

      {:ok, t1, _} = Token.issue("first", user)
      {:ok, t2, _} = Token.issue("second", user)

      assert {:ok, tokens} = Token.list_for(user)
      assert Enum.map(tokens, & &1.id) == [t2.id, t1.id]
      assert Enum.map(tokens, & &1.name) == ["second", "first"]
    end

    test "list_for/1：不含他人 token" do
      u1 = Fixtures.register_user("mcp-token-13")
      u2 = Fixtures.register_user("mcp-token-14")

      {:ok, _, _} = Token.issue("mine", u1)
      {:ok, _, _} = Token.issue("theirs", u2)

      assert {:ok, tokens} = Token.list_for(u1)
      assert Enum.map(tokens, & &1.name) == ["mine"]
    end

    test "issue/2：返回 {:ok, token, plain}，plain 以 cgc_ 开头且 token_hash 匹配" do
      user = Fixtures.register_user("mcp-token-15")

      assert {:ok, token, plain} = Token.issue("我的 Mac", user)
      assert is_binary(plain)
      assert String.starts_with?(plain, "cgc_")
      assert byte_size(plain) > 20

      # 库中只存 hash，且任何字段不含明文
      assert token.token_hash != plain
      expected_hash = :crypto.hash(:sha256, plain) |> Base.encode16(case: :lower)
      assert token.token_hash == expected_hash

      assert token.user_id == user.id

      # 明文不落库：按 hash 读回 DB 行，任何字段不含明文
      stored =
        Token
        |> Ash.Query.filter(token_hash == ^expected_hash)
        |> Ash.read_one!(authorize?: false)

      refute inspect(Map.from_struct(stored)) =~ plain
    end

    test "issue/2：active 上限达 10 返回 {:error, _}" do
      user = Fixtures.register_user("mcp-token-16")

      for i <- 1..10 do
        assert {:ok, _, _} = Token.issue("t#{i}", user)
      end

      assert {:error, %Ash.Error.Invalid{} = error} = Token.issue("over", user)
      assert Exception.message(error) =~ "active connection token limit reached"
    end

    test "issue/2：未认证 actor 返回 {:error, _}" do
      assert {:error, %Ash.Error.Forbidden{}} = Token.issue("X", nil)
    end

    test "revoke/2：本人撤销返回 {:ok, revoked}" do
      user = Fixtures.register_user("mcp-token-17")

      {:ok, token, _} = Token.issue("A", user)

      assert {:ok, revoked} = Token.revoke(token.id, user)
      assert %DateTime{} = revoked.revoked_at
    end

    test "revoke/2：他人 token → {:error, :not_found}（不泄露存在性）" do
      owner = Fixtures.register_user("mcp-token-18")
      other = Fixtures.register_user("mcp-token-19")

      {:ok, token, _} = Token.issue("A", owner)

      assert {:error, :not_found} = Token.revoke(token.id, other)
    end

    test "revoke/2：不存在 id → {:error, :not_found}" do
      user = Fixtures.register_user("mcp-token-20")

      assert {:error, :not_found} = Token.revoke(Ecto.UUID.generate(), user)
    end

    test "revoke/2：重复撤销 → {:error, {:invalid, _}}" do
      user = Fixtures.register_user("mcp-token-21")

      {:ok, token, _} = Token.issue("A", user)

      assert {:ok, _} = Token.revoke(token.id, user)
      assert {:error, {:invalid, error}} = Token.revoke(token.id, user)
      assert Exception.message(error) =~ "already been revoked"
    end
  end
end
