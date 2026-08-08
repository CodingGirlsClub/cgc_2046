defmodule Cgc2046.Accounts.PortfolioItemTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.PortfolioItem
  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Accounts.WorkspaceMembership
  alias AshAuthentication.Info, as: AuthInfo

  @admin_email "portfolio-admin@example.com"
  @owner_email "portfolio-owner@example.com"
  @other_email "portfolio-other@example.com"
  @password "sup3r-secret-password"

  defp password_strategy do
    AuthInfo.strategy!(User, :password)
  end

  defp register_user(email, password) do
    strategy = password_strategy()

    assert {:ok, user} =
             AshAuthentication.Strategy.action(strategy, :register, %{email: email, password: password})

    user
  end

  defp admin_user do
    user = register_user(@admin_email, @password)

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE users SET is_platform_admin = true WHERE id = $1",
        [Ecto.UUID.dump!(user.id)]
      )

    Ash.get!(User, user.id, actor: user, authorize?: false, domain: Cgc2046.GlobalApi)
  end

  defp create_workspace(admin, slug \\ "portfolio-ws-#{System.unique_integer([:positive])}") do
    assert {:ok, workspace} =
             Workspace
             |> Ash.Changeset.for_create(:create, %{slug: slug, name: "Portfolio WS"})
             |> Ash.create(actor: admin)

    workspace
  end

  defp add_member(workspace, user, actor) do
    assert {:ok, membership} =
             WorkspaceMembership
             |> Ash.Changeset.for_create(:create, %{user_id: user.id})
             |> Ash.create(tenant: workspace.id, actor: actor, authorize?: false)

    membership
  end

  defp owner_user do
    register_user(@owner_email, @password)
  end

  defp other_user do
    register_user(@other_email, @password)
  end

  describe "PortfolioItem resource (ADR-0004 per-workspace)" do
    test "create auto-fills user_id + workspace_id (tenant) and defaults icon to document" do
      admin = admin_user()
      ws = create_workspace(admin)
      user = owner_user()
      add_member(ws, user, admin)

      assert {:ok, item} =
               PortfolioItem
               |> Ash.Changeset.for_create(:create, %{title: "我的作品", description: "描述"})
               |> Ash.create(tenant: ws.id, actor: user)

      assert item.user_id == user.id
      assert item.workspace_id == ws.id
      assert item.title == "我的作品"
      assert item.description == "描述"
      assert item.icon == :document
      assert is_nil(item.url)
    end

    test "create requires title" do
      admin = admin_user()
      ws = create_workspace(admin)
      user = owner_user()
      add_member(ws, user, admin)

      assert {:error, %Ash.Error.Invalid{}} =
               PortfolioItem
               |> Ash.Changeset.for_create(:create, %{description: "没有标题"})
               |> Ash.create(tenant: ws.id, actor: user)
    end

    test "create cannot forge another user_id (writable?: false + accept whitelist)" do
      admin = admin_user()
      ws = create_workspace(admin)
      _user = owner_user()
      other = other_user()
      add_member(ws, other, admin)

      changeset =
        PortfolioItem
        |> Ash.Changeset.for_create(:create, %{title: "伪造", user_id: other.id})

      # user_id 不在 accept 白名单中 → 被忽略，不产生 user_id 属性变更
      refute Ash.Changeset.changing_attribute?(changeset, :user_id)
      # workspace_id 亦不可从客户端传入
      refute Ash.Changeset.changing_attribute?(changeset, :workspace_id)
    end

    test "update only allows own items" do
      admin = admin_user()
      ws = create_workspace(admin)
      user = owner_user()
      add_member(ws, user, admin)

      {:ok, item} =
        PortfolioItem
        |> Ash.Changeset.for_create(:create, %{title: "作品 A"})
        |> Ash.create(tenant: ws.id, actor: user)

      assert {:ok, updated} =
               item
               |> Ash.Changeset.for_update(:update, %{
                 title: "作品 A 改名",
                 url: "https://example.com/a"
               })
               |> Ash.update(tenant: ws.id, actor: user)

      assert updated.title == "作品 A 改名"
      assert updated.url == "https://example.com/a"
    end

    test "other user cannot update or destroy someone else's item" do
      admin = admin_user()
      ws = create_workspace(admin)
      user = owner_user()
      other = other_user()
      add_member(ws, user, admin)
      add_member(ws, other, admin)

      {:ok, item} =
        PortfolioItem
        |> Ash.Changeset.for_create(:create, %{title: "作品 A"})
        |> Ash.create(tenant: ws.id, actor: user)

      assert {:error, %Ash.Error.Forbidden{}} =
               item
               |> Ash.Changeset.for_update(:update, %{title: "篡改"})
               |> Ash.update(tenant: ws.id, actor: other)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.destroy(item, tenant: ws.id, actor: other)

      # 原条目仍在
      assert {:ok, still} = Ash.get(PortfolioItem, item.id, tenant: ws.id, actor: user)
      assert still.title == "作品 A"
    end

    test "anonymous cannot create" do
      admin = admin_user()
      ws = create_workspace(admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               PortfolioItem
               |> Ash.Changeset.for_create(:create, %{title: "匿名作品"})
               |> Ash.create(tenant: ws.id, actor: nil)
    end

    test "tenant isolation: same user portfolio not visible in another workspace" do
      admin = admin_user()
      ws1 = create_workspace(admin, "portfolio-iso-ws1")
      ws2 = create_workspace(admin, "portfolio-iso-ws2")
      user = owner_user()
      add_member(ws1, user, admin)
      add_member(ws2, user, admin)

      {:ok, _item_ws1} =
        PortfolioItem
        |> Ash.Changeset.for_create(:create, %{title: "ws1 作品"})
        |> Ash.create(tenant: ws1.id, actor: user)

      # ws2 的 my_portfolio 看不到 ws1 的条目
      assert {:ok, ws2_items} = Ash.read(PortfolioItem, action: :my_portfolio, tenant: ws2.id, actor: user)
      assert ws2_items == []

      assert {:ok, ws1_items} = Ash.read(PortfolioItem, action: :my_portfolio, tenant: ws1.id, actor: user)
      assert Enum.map(ws1_items, & &1.title) == ["ws1 作品"]
    end

    test "my_portfolio only returns the actor's items within the tenant" do
      admin = admin_user()
      ws = create_workspace(admin)
      user = owner_user()
      other = other_user()
      add_member(ws, user, admin)
      add_member(ws, other, admin)

      {:ok, _mine} =
        PortfolioItem
        |> Ash.Changeset.for_create(:create, %{title: "我的作品"})
        |> Ash.create(tenant: ws.id, actor: user)

      {:ok, _theirs} =
        PortfolioItem
        |> Ash.Changeset.for_create(:create, %{title: "别人的作品"})
        |> Ash.create(tenant: ws.id, actor: other)

      assert {:ok, mine} = Ash.read(PortfolioItem, action: :my_portfolio, tenant: ws.id, actor: user)
      assert Enum.map(mine, & &1.title) == ["我的作品"]

      assert {:ok, theirs} = Ash.read(PortfolioItem, action: :my_portfolio, tenant: ws.id, actor: other)
      assert Enum.map(theirs, & &1.title) == ["别人的作品"]
    end

    test "destroy removes own item" do
      admin = admin_user()
      ws = create_workspace(admin)
      user = owner_user()
      add_member(ws, user, admin)

      {:ok, item} =
        PortfolioItem
        |> Ash.Changeset.for_create(:create, %{title: "要删的作品"})
        |> Ash.create(tenant: ws.id, actor: user)

      assert :ok = Ash.destroy(item, tenant: ws.id, actor: user)
      assert {:error, _} = Ash.get(PortfolioItem, item.id, tenant: ws.id, actor: user, authorize?: true)
    end
  end
end
