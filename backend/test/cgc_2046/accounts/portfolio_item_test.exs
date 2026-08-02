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
          token
        }
      }
      """

      res = graphql_post(build_conn(), query)
      assert %{"data" => %{"signIn" => %{"token" => token}}} = res
      token
    end

    defp create_item_mutation(title, opts \\ []) do
      url_arg = Keyword.get(opts, :url)
      icon_arg = Keyword.get(opts, :icon)

      args =
        ["title: \"#{title}\""]
        |> maybe_append("url: \"#{url_arg}\"", url_arg)
        |> maybe_append("icon: #{icon_arg}", icon_arg)
        |> Enum.join(", ")

      """
      mutation {
        createPortfolioItem(input: { #{args} }) {
          result { id title description url icon }
          errors { message }
        }
      }
      """
    end

    defp maybe_append(list, _arg, nil), do: list
    defp maybe_append(list, arg, _value), do: list ++ [arg]

    test "createPortfolioItem via GraphQL fills user_id automatically" do
      _user = owner_user()
      token = sign_in_token(@owner_email, @password)

      res =
        graphql_post(
          build_conn(),
          create_item_mutation("GraphQL 作品", url: "https://example.com"),
          token
        )

      assert %{"data" => %{"createPortfolioItem" => %{"result" => result, "errors" => []}}} = res
      assert result["title"] == "GraphQL 作品"
      assert result["url"] == "https://example.com"
      assert result["icon"] == "document"
      refute is_nil(result["id"])
    end

    test "anonymous cannot createPortfolioItem" do
      res = graphql_post(build_conn(), create_item_mutation("匿名作品"))

      assert %{"data" => %{"createPortfolioItem" => %{"result" => result, "errors" => errors}}} =
               res

      assert is_nil(result)
      assert Enum.any?(errors, &(&1["message"] =~ "forbidden"))
    end

    test "myPortfolio query returns only own items" do
      user = owner_user()
      token = sign_in_token(@owner_email, @password)

      {:ok, _} =
        PortfolioItem
        |> Ash.Changeset.for_create(:create, %{title: "API 作品"})
        |> Ash.create(actor: user)

      query = """
      query {
        myPortfolio { id title icon }
      }
      """

      res = graphql_post(build_conn(), query, token)
      assert %{"data" => %{"myPortfolio" => items}} = res
      assert Enum.map(items, & &1["title"]) == ["API 作品"]
    end

    test "updatePortfolioItem and deletePortfolioItem via GraphQL" do
      user = owner_user()
      token = sign_in_token(@owner_email, @password)

      {:ok, item} =
        PortfolioItem
        |> Ash.Changeset.for_create(:create, %{title: "待更新"})
        |> Ash.create(actor: user)

      update_query = """
      mutation {
        updatePortfolioItem(id: "#{item.id}", input: { title: "更新后" }) {
          result { id title }
          errors { message }
        }
      }
      """

      res = graphql_post(build_conn(), update_query, token)
      assert %{"data" => %{"updatePortfolioItem" => %{"result" => updated, "errors" => []}}} = res
      assert updated["id"] == item.id
      assert updated["title"] == "更新后"

      delete_query = """
      mutation {
        deletePortfolioItem(id: "#{item.id}") {
          result { id title }
          errors { message }
        }
      }
      """

      res = graphql_post(build_conn(), delete_query, token)
      assert %{"data" => %{"deletePortfolioItem" => %{"result" => deleted, "errors" => []}}} = res
      assert deleted["id"] == item.id

      assert {:error, _} = Ash.get(PortfolioItem, item.id, actor: user, authorize?: true)
    end
  end
end
