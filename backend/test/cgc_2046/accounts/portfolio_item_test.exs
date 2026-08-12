defmodule Cgc2046.Accounts.PortfolioItemTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.PortfolioItem
  alias Cgc2046.AccountsFixtures, as: Fixtures

  describe "PortfolioItem resource (ADR-0004 per-workspace)" do
    test "create auto-fills user_id + workspace_id (tenant) and defaults icon to document" do
      admin = Fixtures.platform_admin("portfolio-admin")
      ws = Fixtures.create_workspace(admin)
      user = Fixtures.register_user("portfolio-owner")
      Fixtures.add_member(ws, user)

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
      admin = Fixtures.platform_admin("portfolio-admin")
      ws = Fixtures.create_workspace(admin)
      user = Fixtures.register_user("portfolio-owner")
      Fixtures.add_member(ws, user)

      assert {:error, %Ash.Error.Invalid{}} =
               PortfolioItem
               |> Ash.Changeset.for_create(:create, %{description: "没有标题"})
               |> Ash.create(tenant: ws.id, actor: user)
    end

    test "create cannot forge another user_id (writable?: false + accept whitelist)" do
      admin = Fixtures.platform_admin("portfolio-admin")
      ws = Fixtures.create_workspace(admin)
      _user = Fixtures.register_user("portfolio-owner")
      other = Fixtures.register_user("portfolio-other")
      Fixtures.add_member(ws, other)

      changeset =
        PortfolioItem
        |> Ash.Changeset.for_create(:create, %{title: "伪造", user_id: other.id})

      # user_id 不在 accept 白名单中 → 被忽略，不产生 user_id 属性变更
      refute Ash.Changeset.changing_attribute?(changeset, :user_id)
      # workspace_id 亦不可从客户端传入
      refute Ash.Changeset.changing_attribute?(changeset, :workspace_id)
    end

    test "update only allows own items" do
      admin = Fixtures.platform_admin("portfolio-admin")
      ws = Fixtures.create_workspace(admin)
      user = Fixtures.register_user("portfolio-owner")
      Fixtures.add_member(ws, user)

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
      admin = Fixtures.platform_admin("portfolio-admin")
      ws = Fixtures.create_workspace(admin)
      user = Fixtures.register_user("portfolio-owner")
      other = Fixtures.register_user("portfolio-other")
      Fixtures.add_member(ws, user)
      Fixtures.add_member(ws, other)

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
      admin = Fixtures.platform_admin("portfolio-admin")
      ws = Fixtures.create_workspace(admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               PortfolioItem
               |> Ash.Changeset.for_create(:create, %{title: "匿名作品"})
               |> Ash.create(tenant: ws.id, actor: nil)
    end

    test "tenant isolation: same user portfolio not visible in another workspace" do
      admin = Fixtures.platform_admin("portfolio-admin")
      ws1 = Fixtures.create_workspace(admin, %{slug: "portfolio-iso-ws1"})
      ws2 = Fixtures.create_workspace(admin, %{slug: "portfolio-iso-ws2"})
      user = Fixtures.register_user("portfolio-owner")
      Fixtures.add_member(ws1, user)
      Fixtures.add_member(ws2, user)

      {:ok, _item_ws1} =
        PortfolioItem
        |> Ash.Changeset.for_create(:create, %{title: "ws1 作品"})
        |> Ash.create(tenant: ws1.id, actor: user)

      # ws2 的 my_portfolio 看不到 ws1 的条目
      assert {:ok, ws2_items} =
               Ash.read(PortfolioItem, action: :my_portfolio, tenant: ws2.id, actor: user)

      assert ws2_items == []

      assert {:ok, ws1_items} =
               Ash.read(PortfolioItem, action: :my_portfolio, tenant: ws1.id, actor: user)

      assert Enum.map(ws1_items, & &1.title) == ["ws1 作品"]
    end

    test "my_portfolio only returns the actor's items within the tenant" do
      admin = Fixtures.platform_admin("portfolio-admin")
      ws = Fixtures.create_workspace(admin)
      user = Fixtures.register_user("portfolio-owner")
      other = Fixtures.register_user("portfolio-other")
      Fixtures.add_member(ws, user)
      Fixtures.add_member(ws, other)

      {:ok, _mine} =
        PortfolioItem
        |> Ash.Changeset.for_create(:create, %{title: "我的作品"})
        |> Ash.create(tenant: ws.id, actor: user)

      {:ok, _theirs} =
        PortfolioItem
        |> Ash.Changeset.for_create(:create, %{title: "别人的作品"})
        |> Ash.create(tenant: ws.id, actor: other)

      assert {:ok, mine} =
               Ash.read(PortfolioItem, action: :my_portfolio, tenant: ws.id, actor: user)

      assert Enum.map(mine, & &1.title) == ["我的作品"]

      assert {:ok, theirs} =
               Ash.read(PortfolioItem, action: :my_portfolio, tenant: ws.id, actor: other)

      assert Enum.map(theirs, & &1.title) == ["别人的作品"]
    end

    test "destroy removes own item" do
      admin = Fixtures.platform_admin("portfolio-admin")
      ws = Fixtures.create_workspace(admin)
      user = Fixtures.register_user("portfolio-owner")
      Fixtures.add_member(ws, user)

      {:ok, item} =
        PortfolioItem
        |> Ash.Changeset.for_create(:create, %{title: "要删的作品"})
        |> Ash.create(tenant: ws.id, actor: user)

      assert :ok = Ash.destroy(item, tenant: ws.id, actor: user)

      assert {:error, _} =
               Ash.get(PortfolioItem, item.id, tenant: ws.id, actor: user, authorize?: true)
    end
  end
end
