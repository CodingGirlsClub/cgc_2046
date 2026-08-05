defmodule Cgc2046.Accounts.MembershipTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Accounts.WorkspaceMembership
  alias AshAuthentication.Info, as: AuthInfo

  @admin_email "member-admin@example.com"
  @member_email "member-normal@example.com"
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

  # 注册一个平台管理员用户（直接写库提权，模拟种子/运维操作）
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

  defp normal_user do
    register_user(@member_email, @password)
  end

  defp create_workspace(admin, slug \\ "membership-ws-#{System.unique_integer([:positive])}") do
    assert {:ok, workspace} =
             Workspace
             |> Ash.Changeset.for_create(:create, %{slug: slug, name: "Membership WS"})
             |> Ash.create(actor: admin)

    workspace
  end

  # 以 owner/admin 身份把一个用户拉进工作台（目前无 join 流程，测试直接建成员资格）
  defp add_member(workspace, user, actor, role_names \\ []) do
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

  defp load_role_names(membership) do
    Ash.load!(membership, :roles, tenant: membership.workspace_id, authorize?: false)
    |> Map.fetch!(:roles)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  describe "create workspace establishes owner membership" do
    test "platform admin becomes an owner member with owner role" do
      admin = admin_user()
      workspace = create_workspace(admin)

      assert {:ok, memberships} =
               WorkspaceMembership
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: workspace.id, actor: admin)

      assert [membership] = memberships
      assert membership.user_id == admin.id

      roles =
        Ash.load!(membership, :roles, tenant: workspace.id, authorize?: false)
        |> Map.fetch!(:roles)

      assert [%Cgc2046.Accounts.Role{name: :owner}] = roles
    end

    test "roles are seeded per workspace (owner/admin/member/tutor/volunteer/learner)" do
      admin = admin_user()
      workspace = create_workspace(admin)

      roles =
        Cgc2046.Accounts.Role
        |> Ash.Query.for_read(:read)
        |> Ash.read!(tenant: workspace.id, actor: admin)

      assert Enum.map(roles, & &1.name) |> Enum.sort() ==
               [:admin, :learner, :member, :owner, :tutor, :volunteer]
    end
  end

  describe "assign_roles" do
    setup do
      admin = admin_user()
      workspace = create_workspace(admin)
      {:ok, admin: admin, workspace: workspace}
    end

    test "owner can assign multiple roles (set semantics)", %{admin: admin, workspace: workspace} do
      user = normal_user()
      membership = add_member(workspace, user, admin)

      assert {:ok, updated} =
               membership
               |> Ash.Changeset.for_update(:assign_roles, %{role_names: [:admin, :member]})
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert load_role_names(updated) == [:admin, :member]
    end

    test "assigning again replaces the whole role set", %{admin: admin, workspace: workspace} do
      user = normal_user()
      membership = add_member(workspace, user, admin, [:admin, :member])

      assert {:ok, updated} =
               membership
               |> Ash.Changeset.for_update(:assign_roles, %{role_names: [:member]})
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert load_role_names(updated) == [:member]
    end

    test "empty role_names clears all roles", %{admin: admin, workspace: workspace} do
      user = normal_user()
      membership = add_member(workspace, user, admin, [:admin, :member])

      assert {:ok, updated} =
               membership
               |> Ash.Changeset.for_update(:assign_roles, %{role_names: []})
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert load_role_names(updated) == []
    end

    test "rejects unknown role names", %{admin: admin, workspace: workspace} do
      user = normal_user()
      membership = add_member(workspace, user, admin)

      assert {:error, %Ash.Error.Invalid{}} =
               membership
               |> Ash.Changeset.for_update(:assign_roles, %{role_names: [:superadmin]})
               |> Ash.update(tenant: workspace.id, actor: admin)
    end

    # G1 诊断复现：设计稿五角色（tutor/volunteer/learner）应可分配（P0）
    test "design roles tutor/volunteer/learner can be assigned", %{
      admin: admin,
      workspace: workspace
    } do
      user = normal_user()
      membership = add_member(workspace, user, admin)

      assert {:ok, updated} =
               membership
               |> Ash.Changeset.for_update(:assign_roles, %{
                 role_names: [:tutor, :volunteer, :learner]
               })
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert load_role_names(updated) == [:learner, :tutor, :volunteer]
    end

    test "plain member cannot assign roles", %{admin: admin, workspace: workspace} do
      user = normal_user()
      membership = add_member(workspace, user, admin, [:member])

      assert {:error, %Ash.Error.Forbidden{}} =
               membership
               |> Ash.Changeset.for_update(:assign_roles, %{role_names: [:admin]})
               |> Ash.update(tenant: workspace.id, actor: user)
    end

    test "outsider cannot assign roles", %{admin: admin, workspace: workspace} do
      outsider = register_user("outsider@example.com", @password)
      user = normal_user()
      membership = add_member(workspace, user, admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               membership
               |> Ash.Changeset.for_update(:assign_roles, %{role_names: [:admin]})
               |> Ash.update(tenant: workspace.id, actor: outsider)
    end
  end

  describe "tenant isolation" do
    test "memberships are scoped to their workspace tenant" do
      admin = admin_user()
      ws_a = create_workspace(admin, "tenant-a-#{System.unique_integer([:positive])}")
      ws_b = create_workspace(admin, "tenant-b-#{System.unique_integer([:positive])}")

      user = normal_user()
      add_member(ws_a, user, admin, [:member])

      # ws_b 里查不到 ws_a 的成员（ws_b 只应有 admin 自己的 owner membership）
      assert {:ok, ws_b_members} =
               WorkspaceMembership
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: ws_b.id, actor: admin)

      assert Enum.all?(ws_b_members, &(&1.workspace_id == ws_b.id))
      refute Enum.any?(ws_b_members, &(&1.user_id == user.id))
    end

    test "me_workspaces only returns workspaces the actor belongs to" do
      admin = admin_user()
      ws_a = create_workspace(admin, "me-a-#{System.unique_integer([:positive])}")
      ws_b = create_workspace(admin, "me-b-#{System.unique_integer([:positive])}")

      user = normal_user()
      add_member(ws_a, user, admin, [:member])

      assert {:ok, mine} =
               Workspace
               |> Ash.Query.for_read(:me_workspaces, %{}, actor: user)
               |> Ash.read(actor: user)

      assert [only] = mine
      assert only.id == ws_a.id
      refute Enum.any?(mine, &(&1.id == ws_b.id))
    end

    test "my_role_names reflects actor membership ([] for non-member)" do
      admin = admin_user()
      workspace = create_workspace(admin, "roles-me-#{System.unique_integer([:positive])}")

      user = normal_user()
      add_member(workspace, user, admin, [:member])

      assert {:ok, [fetched]} =
               Workspace
               |> Ash.Query.for_read(:get_by_id, %{id: workspace.id})
               |> Ash.read(actor: user)

      loaded = Ash.load!(fetched, :my_role_names, actor: user)
      assert loaded.my_role_names == ["member"]

      outsider = register_user("outsider2@example.com", @password)

      assert {:ok, [fetched2]} =
               Workspace
               |> Ash.Query.for_read(:get_by_id, %{id: workspace.id})
               |> Ash.read(actor: outsider)

      loaded2 = Ash.load!(fetched2, :my_role_names, actor: outsider)
      assert loaded2.my_role_names == []
    end

    test "my_membership_id and can_access reflect actor membership" do
      admin = admin_user()
      workspace = create_workspace(admin, "me-mem-#{System.unique_integer([:positive])}")

      user = normal_user()
      membership = add_member(workspace, user, admin, [:member])

      assert {:ok, [fetched]} =
               Workspace
               |> Ash.Query.for_read(:get_by_id, %{id: workspace.id})
               |> Ash.read(actor: user)

      loaded = Ash.load!(fetched, [:my_membership_id, :can_access], actor: user)
      assert loaded.my_membership_id == membership.id
      assert loaded.can_access == true

      outsider = register_user("outsider3@example.com", @password)

      assert {:ok, [fetched2]} =
               Workspace
               |> Ash.Query.for_read(:get_by_id, %{id: workspace.id})
               |> Ash.read(actor: outsider)

      loaded2 = Ash.load!(fetched2, [:my_membership_id, :can_access], actor: outsider)
      assert loaded2.my_membership_id == nil
      assert loaded2.can_access == false
    end
  end

  describe "destroy last-owner guard" do
    # plan-007 Step 4：destroy 守卫与 assign_roles 共享同一不变量（per-workspace
    # advisory lock + owner_count 读）。唯一 owner 的 destroy 必须被 before_action 拒绝。

    test "rejects destroying the sole owner (orphan protection)" do
      admin = admin_user()
      workspace = create_workspace(admin)

      # admin 是该工作台唯一 owner 成员（create_workspace 的 after_action 建立）
      membership =
        Ash.load!(workspace, :memberships, tenant: workspace.id, actor: admin, authorize?: false)
        |> Map.fetch!(:memberships)
        |> Enum.find(&(&1.user_id == admin.id))

      assert membership != nil
      assert load_role_names(membership) == [:owner]

      # 守卫在 before_action 拒绝，不触达 data layer（FK 未被破坏）
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               membership
               |> Ash.Changeset.for_destroy(:destroy)
               |> Ash.destroy(tenant: workspace.id, actor: admin)

      assert Enum.any?(errors, &(Exception.message(&1) =~ "至少保留一个 Owner"))

      # 数据库未被改动：admin 仍是 owner
      assert Cgc2046.Rbac.owner_count(workspace.id) == 1
      assert Cgc2046.Rbac.role_names(admin, workspace.id) == [:owner]
    end

    test "allows destroying a non-last owner" do
      admin = admin_user()
      workspace = create_workspace(admin)

      other =
        register_user("destroy-co-#{System.unique_integer([:positive])}@example.com", @password)

      # 第二个 owner（admin 授予 other owner 角色，admin 仍是 owner）
      membership = add_member(workspace, other, admin, [:owner])
      assert load_role_names(membership) == [:owner]
      assert Cgc2046.Rbac.owner_count(workspace.id) == 2

      # 删除 other 的 owner 成员资格：先解 FK（membership_roles 无 on_delete cascade），
      # 再 destroy。此时 owner_count 仍为 2（admin 仍在），守卫放行。
      Ecto.Adapters.SQL.query!(
        Cgc2046.Repo,
        "DELETE FROM membership_roles WHERE membership_id = $1",
        [Ecto.UUID.dump!(membership.id)]
      )

      assert :ok =
               membership
               |> Ash.Changeset.for_destroy(:destroy)
               |> Ash.destroy(tenant: workspace.id, actor: admin)

      # admin 仍是 owner，工作台未变孤儿
      assert Cgc2046.Rbac.owner_count(workspace.id) == 1
      assert Cgc2046.Rbac.role_names(admin, workspace.id) == [:owner]
    end

    # 规则 1 的镜像缺口（plan-007 收尾）：只有 Owner 能移除 Owner 成员。
    # Admin 角色的 actor 删除 owner 成员 = 等效撤销 owner，必须被拒（与 assign_roles
    # 规则1「Admin 不能碰 owner」对称）。
    test "rejects non-owner admin destroying an owner member (rule 1 mirror)" do
      owner = admin_user()
      workspace = create_workspace(owner)
      # 纯 admin 角色的 actor（非 owner）：owner 拉进来只给 admin
      admin_only =
        register_user(
          "destroy-admin-only-#{System.unique_integer([:positive])}@example.com",
          @password
        )

      admin_membership = add_member(workspace, admin_only, owner, [:admin])
      assert load_role_names(admin_membership) == [:admin]
      # 第三个 owner 成员，给 owner 角色
      third =
        register_user(
          "destroy-owner-third-#{System.unique_integer([:positive])}@example.com",
          @password
        )

      third_membership = add_member(workspace, third, owner, [:owner])
      assert load_role_names(third_membership) == [:owner]
      # owner_count=2（owner + third），删 third 不触发最后 owner 保护，
      # 但 admin_only 不是 owner → 规则1 镜像应拒绝
      assert Cgc2046.Rbac.owner_count(workspace.id) == 2

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               third_membership
               |> Ash.Changeset.for_destroy(:destroy)
               |> Ash.destroy(tenant: workspace.id, actor: admin_only)

      assert Enum.any?(errors, &(Exception.message(&1) =~ "只有 Owner 能授予或撤销 Owner 角色"))

      # 数据库未被改动：third 仍是 owner，owner_count 仍为 2
      assert Cgc2046.Rbac.owner_count(workspace.id) == 2
      assert Cgc2046.Rbac.role_names(third, workspace.id) == [:owner]
    end

    test "allows destroying a non-owner member (admin role)" do
      owner = admin_user()
      workspace = create_workspace(owner)

      # 纯 admin 角色的成员（非 owner）
      admin_only =
        register_user(
          "destroy-non-owner-#{System.unique_integer([:positive])}@example.com",
          @password
        )

      admin_membership = add_member(workspace, admin_only, owner, [:admin])
      assert load_role_names(admin_membership) == [:admin]
      assert Cgc2046.Rbac.owner_count(workspace.id) == 1

      # 先解 FK（membership_roles 无 on_delete cascade），再 destroy
      Ecto.Adapters.SQL.query!(
        Cgc2046.Repo,
        "DELETE FROM membership_roles WHERE membership_id = $1",
        [Ecto.UUID.dump!(admin_membership.id)]
      )

      # 删除 admin 成员（非 owner），守卫应放行
      assert :ok =
               admin_membership
               |> Ash.Changeset.for_destroy(:destroy)
               |> Ash.destroy(tenant: workspace.id, actor: owner)

      # owner 仍在，工作台未变孤儿
      assert Cgc2046.Rbac.owner_count(workspace.id) == 1
      assert Cgc2046.Rbac.role_names(owner, workspace.id) == [:owner]

      # admin_only 已不是成员
      assert Cgc2046.Rbac.role_names(admin_only, workspace.id) == []
    end
  end
end
