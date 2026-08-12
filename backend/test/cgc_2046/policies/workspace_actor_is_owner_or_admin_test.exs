defmodule Cgc2046.Policies.WorkspaceActorIsOwnerOrAdminTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.WorkspaceMembership
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin

  require Ash.Query

  describe "match?/3 适配器契约（#2 薄适配器，三 context 场景直接钉测）" do
    test "匿名 actor → 拒绝（任何 context）" do
      assert WorkspaceActorIsOwnerOrAdmin.match?(nil, %{query: %Ash.Query{}}, []) == false
    end

    test "owner + changeset（assign_roles update，tenant）→ 通过" do
      admin = Fixtures.platform_admin("pol-admin")
      workspace = Fixtures.create_workspace(admin)
      membership = Fixtures.add_member(workspace, Fixtures.register_user("pol-user"), [:member])

      changeset =
        Ash.Changeset.for_update(membership, :assign_roles, %{role_names: []},
          tenant: workspace.id
        )

      assert WorkspaceActorIsOwnerOrAdmin.match?(admin, %{changeset: changeset}, [])
    end

    test "owner + changeset（无 tenant，从 changeset.data 取）→ 通过" do
      admin = Fixtures.platform_admin("pol-admin")
      workspace = Fixtures.create_workspace(admin)
      membership = Fixtures.add_member(workspace, Fixtures.register_user("pol-user"), [:member])

      changeset = Ash.Changeset.for_update(membership, :assign_roles, %{role_names: []})
      assert WorkspaceActorIsOwnerOrAdmin.match?(admin, %{changeset: changeset}, [])
    end

    test "admin 角色 + list query（workspace_id filter）→ 通过" do
      admin = Fixtures.platform_admin("pol-admin")
      workspace = Fixtures.create_workspace(admin)
      admin_member = Fixtures.register_user("pol-admin-member")
      Fixtures.add_member(workspace, admin_member, [:admin])

      query = Ash.Query.filter(WorkspaceMembership, workspace_id == ^workspace.id)
      assert WorkspaceActorIsOwnerOrAdmin.match?(admin_member, %{query: query}, [])
    end

    test "普通成员 + list query → 拒绝" do
      admin = Fixtures.platform_admin("pol-admin")
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("pol-member")
      Fixtures.add_member(workspace, member, [:member])

      query = Ash.Query.filter(WorkspaceMembership, workspace_id == ^workspace.id)
      refute WorkspaceActorIsOwnerOrAdmin.match?(member, %{query: query}, [])
    end

    test "非成员 + changeset → 拒绝" do
      admin = Fixtures.platform_admin("pol-admin")
      workspace = Fixtures.create_workspace(admin)
      outsider = Fixtures.register_user("pol-outsider")

      # 用 outsider 自己作 actor，context 里是目标工作台的 changeset
      membership = Fixtures.add_member(workspace, Fixtures.register_user("pol-user"), [:member])

      changeset =
        Ash.Changeset.for_update(membership, :assign_roles, %{role_names: []},
          tenant: workspace.id
        )

      refute WorkspaceActorIsOwnerOrAdmin.match?(outsider, %{changeset: changeset}, [])
    end

    test "get-by-id context（id-only filter 回查）→ 通过" do
      admin = Fixtures.platform_admin("pol-admin")
      workspace = Fixtures.create_workspace(admin)
      membership = Fixtures.add_member(workspace, Fixtures.register_user("pol-user"), [:member])

      query = Ash.Query.filter(WorkspaceMembership, id == ^membership.id)
      assert WorkspaceActorIsOwnerOrAdmin.match?(admin, %{query: query}, [])
    end

    test "未知 context（%{data: ...}）→ 拒绝（resolve 返回 nil，fail-closed）" do
      admin = Fixtures.platform_admin("pol-admin")
      refute WorkspaceActorIsOwnerOrAdmin.match?(admin, %{data: %{}}, [])
    end
  end
end
