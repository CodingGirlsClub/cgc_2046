defmodule Cgc2046.Accounts.PortfolioItemTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.PortfolioItem
  alias Cgc2046.Accounts.User
  alias AshAuthentication.Info, as: AuthInfo

  @owner_email "portfolio-owner@example.com"
  @other_email "portfolio-other@example.com"
  @password "sup3r-secret-password"

  defp password_strategy do
    AuthInfo.strategy!(User, :password)
  end

  defp register_user(email, password) do
    strategy = password_strategy()

    assert {:ok, user} =
             AshAuthentication.Strategy.action(strategy, :register, %{
               email: email,
               password: password
             })

    user
  end

  defp owner_user do
    register_user(@owner_email, @password)
  end

  defp other_user do
    register_user(@other_email, @password)
  end

  describe "PortfolioItem resource (P1-4 G9)" do
    test "create auto-fills user_id from actor and defaults icon to document" do
      user = owner_user()

      assert {:ok, item} =
               PortfolioItem
               |> Ash.Changeset.for_create(:create, %{title: "我的作品", description: "描述"})
               |> Ash.create(actor: user)

      assert item.user_id == user.id
      assert item.title == "我的作品"
      assert item.description == "描述"
      assert item.icon == :document
      assert is_nil(item.url)
    end

    test "create requires title" do
      user = owner_user()

      assert {:error, %Ash.Error.Invalid{}} =
               PortfolioItem
               |> Ash.Changeset.for_create(:create, %{description: "没有标题"})
               |> Ash.create(actor: user)
    end

    test "create cannot forge another user_id (writable?: false + accept whitelist)" do
      _user = owner_user()
      other = other_user()

      changeset =
        PortfolioItem
        |> Ash.Changeset.for_create(:create, %{title: "伪造", user_id: other.id})

      # user_id 不在 accept 白名单中 → 被忽略，不产生 user_id 属性变更
      refute Ash.Changeset.changing_attribute?(changeset, :user_id)
    end

    test "update only allows own items" do
      user = owner_user()

      {:ok, item} =
        PortfolioItem
        |> Ash.Changeset.for_create(:create, %{title: "作品 A"})
        |> Ash.create(actor: user)

      assert {:ok, updated} =
               item
               |> Ash.Changeset.for_update(:update, %{
                 title: "作品 A 改名",
                 url: "https://example.com/a"
               })
               |> Ash.update(actor: user)

      assert updated.title == "作品 A 改名"
      assert updated.url == "https://example.com/a"
    end

    test "other user cannot update or destroy someone else's item" do
      user = owner_user()
      other = other_user()

      {:ok, item} =
        PortfolioItem
        |> Ash.Changeset.for_create(:create, %{title: "作品 A"})
        |> Ash.create(actor: user)

      assert {:error, %Ash.Error.Forbidden{}} =
               item
               |> Ash.Changeset.for_update(:update, %{title: "篡改"})
               |> Ash.update(actor: other)

      assert {:error, %Ash.Error.Forbidden{}} =
               item
               |> Ash.destroy(actor: other)

      # 原条目仍在
      assert {:ok, still} = Ash.get(PortfolioItem, item.id, actor: user)
      assert still.title == "作品 A"
    end

    test "anonymous cannot create" do
      assert {:error, %Ash.Error.Forbidden{}} =
               PortfolioItem
               |> Ash.Changeset.for_create(:create, %{title: "匿名作品"})
               |> Ash.create(actor: nil)
    end

    test "my_portfolio only returns the actor's items" do
      user = owner_user()
      other = other_user()

      {:ok, _mine} =
        PortfolioItem
        |> Ash.Changeset.for_create(:create, %{title: "我的作品"})
        |> Ash.create(actor: user)

      {:ok, _theirs} =
        PortfolioItem
        |> Ash.Changeset.for_create(:create, %{title: "别人的作品"})
        |> Ash.create(actor: other)

      assert {:ok, mine} = Ash.read(PortfolioItem, action: :my_portfolio, actor: user)
      assert Enum.map(mine, & &1.title) == ["我的作品"]

      assert {:ok, theirs} = Ash.read(PortfolioItem, action: :my_portfolio, actor: other)
      assert Enum.map(theirs, & &1.title) == ["别人的作品"]
    end

    test "destroy removes own item" do
      user = owner_user()

      {:ok, item} =
        PortfolioItem
        |> Ash.Changeset.for_create(:create, %{title: "要删的作品"})
        |> Ash.create(actor: user)

      assert :ok = Ash.destroy(item, actor: user)
      assert {:error, _} = Ash.get(PortfolioItem, item.id, actor: user, authorize?: true)
    end
  end

  describe "PortfolioItem GraphQL contract" do
    defp graphql_post(conn, query, token \\ nil) do
      conn =
        if token do
          put_req_header(conn, "authorization", "Bearer #{token}")
        else
          conn
        end

      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => query})
      |> json_response(200)
    end

    defp sign_in_token(email, password) do
      query = """
      mutation {
        signIn(email: "#{email}", password: "#{password}") {
          id
        }
      }
      """

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/graphql", %{"query" => query})

      assert %{"data" => %{"signIn" => %{"id" => _id}}} = json_response(conn, 200)
      # token 由后端 before_send 写 httpOnly cookie，从 Set-Cookie 头提取
      token = conn.resp_cookies["cgc_token"].value
      token
    end
  end
end
