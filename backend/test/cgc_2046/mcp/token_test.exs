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

  defp register_user(email) do
    strategy = AshAuthentication.Info.strategy!(Cgc2046.Accounts.User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :register, %{
        email: email,
        password: "sup3r-secret-password"
      })

    user
  end

  describe "issue（签发）" do
    test "签发成功：hash 落库，明文仅在 metadata.plain_token 一次性返回" do
      user = register_user("mcp-token-1@example.com")

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
      user = register_user("mcp-token-2@example.com")

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
      user = register_user("mcp-token-cap@example.com")

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
      user = register_user("mcp-token-3@example.com")

      {:ok, token} =
        Token |> Ash.Changeset.for_create(:issue, %{name: "A"}, actor: user) |> Ash.create()

      assert {:ok, found} = Token.validate_token(token.__metadata__[:plain_token])
      assert found.id == user.id
    end

    test "错误 token → :error" do
      assert :error = Token.validate_token("not-a-real-token")
    end

    test "已撤销 token → :error" do
      user = register_user("mcp-token-4@example.com")

      {:ok, token} =
        Token |> Ash.Changeset.for_create(:issue, %{name: "A"}, actor: user) |> Ash.create()

      plain = token.__metadata__[:plain_token]

      assert {:ok, _} =
               token |> Ash.Changeset.for_update(:revoke, %{}, actor: user) |> Ash.update()

      assert :error = Token.validate_token(plain)
    end

    test "validate_token 触碰 last_used_at" do
      user = register_user("mcp-token-5@example.com")

      {:ok, token} =
        Token |> Ash.Changeset.for_create(:issue, %{name: "A"}, actor: user) |> Ash.create()

      assert {:ok, _user} = Token.validate_token(token.__metadata__[:plain_token])

      updated = Ash.get!(Token, token.id, authorize?: false)
      assert %DateTime{} = updated.last_used_at
    end
  end

  describe "revoke（撤销）" do
    test "本人可撤销自己的 token" do
      user = register_user("mcp-token-6@example.com")

      {:ok, token} =
        Token |> Ash.Changeset.for_create(:issue, %{name: "A"}, actor: user) |> Ash.create()

      assert {:ok, revoked} =
               token |> Ash.Changeset.for_update(:revoke, %{}, actor: user) |> Ash.update()

      assert %DateTime{} = revoked.revoked_at
    end

    test "他人不可撤销（Forbidden）" do
      owner = register_user("mcp-token-7@example.com")
      other = register_user("mcp-token-8@example.com")

      {:ok, token} =
        Token |> Ash.Changeset.for_create(:issue, %{name: "A"}, actor: owner) |> Ash.create()

      assert {:error, %Ash.Error.Forbidden{}} =
               token |> Ash.Changeset.for_update(:revoke, %{}, actor: other) |> Ash.update()
    end

    test "重复撤销被拒绝" do
      user = register_user("mcp-token-9@example.com")

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
      u1 = register_user("mcp-token-10@example.com")
      u2 = register_user("mcp-token-11@example.com")

      {:ok, _} =
        Token |> Ash.Changeset.for_create(:issue, %{name: "u1"}, actor: u1) |> Ash.create()

      {:ok, _} =
        Token |> Ash.Changeset.for_create(:issue, %{name: "u2"}, actor: u2) |> Ash.create()

      mine = Token |> Ash.read!(actor: u1)
      assert length(mine) == 1
      assert hd(mine).name == "u1"
    end
  end
end
