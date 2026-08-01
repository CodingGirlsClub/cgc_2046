defmodule Cgc2046.RbacTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Accounts.WorkspaceMembership
  alias Cgc2046.Rbac
  alias AshAuthentication.Info, as: AuthInfo

  @admin_email "rbac-admin@example.com"
  @member_email "rbac-member@example.com"
  @outsider_email "rbac-outsider@example.com"
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

  # 移除用户的成员资格（先删 membership_roles 关联记录，避免外键保护 "would leave records behind"）
  defp remove_membership(workspace, user) do
    loaded =
      Ash.load!(workspace, :memberships, tenant: workspace.id, actor: user, authorize?: false)

    membership = Enum.find(loaded.memberships, &(&1.user_id == user.id))
    assert membership != nil

    Ecto.Adapters.SQL.query!(
      Cgc2046.Repo,
      "DELETE FROM membership_roles WHERE membership_id = $1",
      [Ecto.UUID.dump!(membership.id)]
    )

    Ash.destroy!(membership, tenant: workspace.id, actor: user, authorize?: false)
    :ok
  end

  defp create_workspace(admin, join_policy \\ :request) do
    slug = "rbac-ws-#{System.unique_integer([:positive])}"

    assert {:ok, workspace} =
             Workspace
             |> Ash.Changeset.for_create(:create, %{
               slug: slug,
               name: "Rbac WS",
               join_policy: join_policy
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
      assert {:ok, _membership} =
               membership
               |> Ash.Changeset.for_update(:assign_roles, %{role_names: role_names})
               |> Ash.update(tenant: workspace.id, actor: actor, authorize?: false)
    end

    membership
  end

  describe "can?/3" do
    test "anonymous actor has no abilities" do
      assert Rbac.can?(nil, :view_workspace, workspace_id: "any")
             |> Kernel.not()

      for ability <- Rbac.abilities_list() do
        refute Rbac.can?(nil, ability, workspace_id: "any"),
               "expected anonymous to be denied #{ability}"
      end
    end

    test "platform admin who is a member (owner) has all abilities" do
      admin = admin_user()

      # 平台管理员自建工作台时自动成为 owner 成员
      workspace = create_workspace(admin)

      for ability <- Rbac.abilities_list() do
        assert Rbac.can?(admin, ability, workspace_id: workspace.id),
               "expected platform admin (owner member) to have #{ability}"
      end

      assert Rbac.can?(admin, :create_workspace, [])
    end

    test "platform admin who is NOT a member only gets view/access (P2: no manage exemption)" do
      # 平台管理员建工作台后移除自己的成员资格 → 模拟他人 workspace 的非成员平台管理员
      admin = admin_user()
      workspace = create_workspace(admin)

      remove_membership(workspace, admin)

      assert Rbac.can?(admin, :view_workspace, workspace_id: workspace.id)
      assert Rbac.can?(admin, :access_invite_only, workspace_id: workspace.id)

      for ability <- [:list_members, :manage_members, :assign_roles] do
        refute Rbac.can?(admin, ability, workspace_id: workspace.id),
               "expected platform admin (non-member) to be denied #{ability}"
      end

      # 平台级能力仍保留
      assert Rbac.can?(admin, :create_workspace, workspace_id: workspace.id)
    end

    test "owner member abilities match #67 matrix" do
      admin = admin_user()
      workspace = create_workspace(admin)

      # 普通用户被授予 owner 角色（非平台管理员），验证 owner 成员能力
      owner = register_user("rbac-owner@example.com", @password)
      add_member(workspace, owner, admin, [:owner])

      assert Rbac.can?(owner, :view_workspace, workspace_id: workspace.id)
      assert Rbac.can?(owner, :access_invite_only, workspace_id: workspace.id)
      assert Rbac.can?(owner, :list_members, workspace_id: workspace.id)
      assert Rbac.can?(owner, :manage_members, workspace_id: workspace.id)
      assert Rbac.can?(owner, :assign_roles, workspace_id: workspace.id)
      refute Rbac.can?(owner, :create_workspace, workspace_id: workspace.id)
    end

    test "admin member abilities match #67 matrix" do
      admin = admin_user()
      workspace = create_workspace(admin)

      user = register_user("rbac-admin-role@example.com", @password)
      add_member(workspace, user, admin, [:admin])

      for ability <- [
            :view_workspace,
            :access_invite_only,
            :list_members,
            :manage_members,
            :assign_roles
          ] do
        assert Rbac.can?(user, ability, workspace_id: workspace.id),
               "expected admin member to have #{ability}"
      end

      refute Rbac.can?(user, :create_workspace, workspace_id: workspace.id)
    end

    test "member abilities match #67 matrix" do
      admin = admin_user()
      workspace = create_workspace(admin)

      user = register_user(@member_email, @password)
      add_member(workspace, user, admin, [:member])

      assert Rbac.can?(user, :view_workspace, workspace_id: workspace.id)
      assert Rbac.can?(user, :access_invite_only, workspace_id: workspace.id)
      refute Rbac.can?(user, :list_members, workspace_id: workspace.id)
      refute Rbac.can?(user, :manage_members, workspace_id: workspace.id)
      refute Rbac.can?(user, :assign_roles, workspace_id: workspace.id)
      refute Rbac.can?(user, :create_workspace, workspace_id: workspace.id)
    end

    test "outsider (authenticated non-member) has no workspace abilities" do
      admin = admin_user()
      workspace = create_workspace(admin)

      outsider = register_user(@outsider_email, @password)

      for ability <- [
            :view_workspace,
            :access_invite_only,
            :list_members,
            :manage_members,
            :assign_roles
          ] do
        refute Rbac.can?(outsider, ability, workspace_id: workspace.id),
               "expected outsider to be denied #{ability}"
      end
    end

    test "opts can take a workspace struct or a membership with roles" do
      admin = admin_user()
      workspace = create_workspace(admin)

      # workspace struct 形式
      assert Rbac.can?(admin, :manage_members, workspace: workspace)

      # membership 形式（避免重复查询）
      user = register_user("rbac-membership-opt@example.com", @password)
      membership = add_member(workspace, user, admin, [:member])

      loaded = Ash.load!(membership, :roles, tenant: workspace.id, authorize?: false)
      assert Rbac.can?(user, :view_workspace, membership: loaded)
      refute Rbac.can?(user, :manage_members, membership: loaded)
    end

    test "invite_only workspace: member can access, outsider cannot" do
      admin = admin_user()
      workspace = create_workspace(admin, :invite_only)

      user = register_user("rbac-invite@example.com", @password)
      add_member(workspace, user, admin, [:member])

      outsider = register_user("rbac-invite-out@example.com", @password)

      assert Rbac.can?(user, :access_invite_only, workspace_id: workspace.id)
      assert Rbac.can?(user, :view_workspace, workspace_id: workspace.id)
      refute Rbac.can?(outsider, :access_invite_only, workspace_id: workspace.id)
      refute Rbac.can?(outsider, :view_workspace, workspace_id: workspace.id)
      # 平台管理员始终可访问 invite_only
      assert Rbac.can?(admin, :access_invite_only, workspace_id: workspace.id)
    end
  end

  describe "authorize/3" do
    test "returns :ok when allowed, {:error, :forbidden} otherwise" do
      admin = admin_user()
      workspace = create_workspace(admin)

      assert :ok = Rbac.authorize(admin, :manage_members, workspace_id: workspace.id)

      outsider = register_user("rbac-authorize-out@example.com", @password)

      assert {:error, :forbidden} =
               Rbac.authorize(outsider, :manage_members, workspace_id: workspace.id)

      assert {:error, :forbidden} =
               Rbac.authorize(nil, :view_workspace, workspace_id: workspace.id)
    end
  end

  describe "abilities/2" do
    test "returns the sorted ability list for the actor in workspace context" do
      admin = admin_user()
      workspace = create_workspace(admin)

      user = register_user("rbac-abilities@example.com", @password)
      add_member(workspace, user, admin, [:member])

      assert Rbac.abilities(user, workspace_id: workspace.id) ==
               [:view_workspace, :access_invite_only]

      outsider = register_user("rbac-abilities-out@example.com", @password)
      assert Rbac.abilities(outsider, workspace_id: workspace.id) == []

      # 平台管理员（自建 workspace，owner 成员）拥有全部六项能力（含 create_workspace）
      assert Rbac.abilities(admin, workspace_id: workspace.id) ==
               [
                 :view_workspace,
                 :access_invite_only,
                 :list_members,
                 :manage_members,
                 :assign_roles,
                 :create_workspace
               ]

      # 非成员平台管理员：仅 view/access + create_workspace（P2 判定侧收敛）
      remove_membership(workspace, admin)

      assert Rbac.abilities(admin, workspace_id: workspace.id) ==
               [:view_workspace, :access_invite_only, :create_workspace]
    end
  end

  describe "matrix/0" do
    test "matches the frontend #67 MOCK_PERMISSION_MATRIX" do
      matrix = Rbac.matrix()

      assert length(matrix) == 3
      assert Enum.map(matrix, & &1.role) == [:owner, :admin, :member]

      for row <- matrix, row.role in [:owner, :admin] do
        assert row.abilities.view_workspace == true
        assert row.abilities.access_invite_only == true
        assert row.abilities.list_members == true
        assert row.abilities.manage_members == true
        assert row.abilities.assign_roles == true
        assert row.abilities.create_workspace == false
      end

      member = Enum.find(matrix, &(&1.role == :member))
      assert member.abilities.view_workspace == true
      assert member.abilities.access_invite_only == true
      assert member.abilities.list_members == false
      assert member.abilities.manage_members == false
      assert member.abilities.assign_roles == false
      assert member.abilities.create_workspace == false
    end
  end
end
