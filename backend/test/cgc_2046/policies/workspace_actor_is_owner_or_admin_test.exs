defmodule Cgc2046.Policies.WorkspaceActorIsOwnerOrAdminTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Accounts.WorkspaceMembership
  alias Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin
  alias AshAuthentication.Info, as: AuthInfo

  @password "sup3r-secret-password"

  require Ash.Query

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

  defp admin_user do
    user = register_user("pol-admin-#{System.unique_integer([:positive])}@example.com", @password)

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE users SET is_platform_admin = true WHERE id = $1",
        [Ecto.UUID.dump!(user.id)]
      )

    Ash.get!(User, user.id, actor: user, authorize?: false, domain: Cgc2046.GlobalApi)
  end

  defp new_user do
    register_user("pol-user-#{System.unique_integer([:positive])}@example.com", @password)
  end

  defp create_workspace(admin) do
    {:ok, workspace} =
      Workspace
      |> Ash.Changeset.for_create(:create, %{
        slug: "pol-#{System.unique_integer([:positive])}",
        name: "POL"
      })
      |> Ash.create(actor: admin)

    workspace
  end

  defp add_member(workspace, user, actor, role_names) do
    {:ok, membership} =
      WorkspaceMembership
      |> Ash.Changeset.for_create(:create, %{user_id: user.id})
      |> Ash.create(tenant: workspace.id, actor: actor, authorize?: false)

    if role_names != [] do
      # P0 grant scope 校验依赖 context.actor：actor/tenant 在 for_update 阶段传
      assert {:ok, _membership} =
               membership
               |> Ash.Changeset.for_update(
                 :assign_roles,
                 %{role_names: role_names},
                 actor: actor,
                 tenant: workspace.id
               )
               |> Ash.update()
    end

    membership
  end

  describe "match?/3 适配器契约（#2 薄适配器，三 context 场景直接钉测）" do
    test "匿名 actor → 拒绝（任何 context）" do
      assert WorkspaceActorIsOwnerOrAdmin.match?(nil, %{query: %Ash.Query{}}, []) == false
    end

    test "owner + changeset（assign_roles update，tenant）→ 通过" do
      admin = admin_user()
      workspace = create_workspace(admin)
      membership = add_member(workspace, new_user(), admin, [:member])

      changeset =
        Ash.Changeset.for_update(membership, :assign_roles, %{role_names: []},
          tenant: workspace.id
        )

      assert WorkspaceActorIsOwnerOrAdmin.match?(admin, %{changeset: changeset}, [])
    end

    test "owner + changeset（无 tenant，从 changeset.data 取）→ 通过" do
      admin = admin_user()
      workspace = create_workspace(admin)
      membership = add_member(workspace, new_user(), admin, [:member])

      changeset = Ash.Changeset.for_update(membership, :assign_roles, %{role_names: []})
      assert WorkspaceActorIsOwnerOrAdmin.match?(admin, %{changeset: changeset}, [])
    end

    test "admin 角色 + list query（workspace_id filter）→ 通过" do
      admin = admin_user()
      workspace = create_workspace(admin)
      admin_member = new_user()
      add_member(workspace, admin_member, admin, [:admin])

      query = Ash.Query.filter(WorkspaceMembership, workspace_id == ^workspace.id)
      assert WorkspaceActorIsOwnerOrAdmin.match?(admin_member, %{query: query}, [])
    end

    test "普通成员 + list query → 拒绝" do
      admin = admin_user()
      workspace = create_workspace(admin)
      member = new_user()
      add_member(workspace, member, admin, [:member])

      query = Ash.Query.filter(WorkspaceMembership, workspace_id == ^workspace.id)
      refute WorkspaceActorIsOwnerOrAdmin.match?(member, %{query: query}, [])
    end

    test "非成员 + changeset → 拒绝" do
      admin = admin_user()
      workspace = create_workspace(admin)
      outsider = new_user()

      # 用 outsider 自己作 actor，context 里是目标工作台的 changeset
      membership = add_member(workspace, new_user(), admin, [:member])

      changeset =
        Ash.Changeset.for_update(membership, :assign_roles, %{role_names: []},
          tenant: workspace.id
        )

      refute WorkspaceActorIsOwnerOrAdmin.match?(outsider, %{changeset: changeset}, [])
    end

    test "get-by-id context（id-only filter 回查）→ 通过" do
      admin = admin_user()
      workspace = create_workspace(admin)
      membership = add_member(workspace, new_user(), admin, [:member])

      query = Ash.Query.filter(WorkspaceMembership, id == ^membership.id)
      assert WorkspaceActorIsOwnerOrAdmin.match?(admin, %{query: query}, [])
    end

    test "未知 context（%{data: ...}）→ 拒绝（resolve 返回 nil，fail-closed）" do
      admin = admin_user()
      refute WorkspaceActorIsOwnerOrAdmin.match?(admin, %{data: %{}}, [])
    end
  end
end
