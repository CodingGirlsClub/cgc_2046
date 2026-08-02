defmodule Cgc2046Web.GraphqlRbacTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.Role
  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Accounts.WorkspaceMembership
  alias AshAuthentication.Info, as: AuthInfo

  @admin_email "gql-rbac-admin@example.com"
  @member_email "gql-rbac-member@example.com"
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

  # 以 owner/admin 身份把一个用户拉进工作台（测试直接建成员资格，可指定初始角色）
  defp add_member(workspace, user, actor, role_names \\ []) do
    {:ok, membership} =
      WorkspaceMembership
      |> Ash.Changeset.for_create(:create, %{user_id: user.id})
      |> Ash.create(tenant: workspace.id, actor: actor, authorize?: false)

    if role_names != [] do
      assert {:ok, _membership} =
               membership
               |> Ash.Changeset.for_update(:assign_roles, %{role_names: role_names}, actor: actor)
               |> Ash.update(tenant: workspace.id, actor: actor, authorize?: false)
    end

    membership
  end

  defp find_membership(workspace, user) do
    loaded =
      Ash.load!(workspace, :memberships, tenant: workspace.id, actor: user, authorize?: false)

    Enum.find(loaded.memberships, &(&1.user_id == user.id))
  end

  defp load_role_names(membership) do
    Ash.load!(membership, :roles, tenant: membership.workspace_id, authorize?: false)
    |> Map.fetch!(:roles)
    |> Enum.map(& &1.name)
  end

  defp assign_roles_query(membership_id, role_names) do
    names = role_names |> Enum.map(&("\"" <> to_string(&1) <> "\"")) |> Enum.join(", ")

    """
    mutation {
      assignRoles(id: "#{membership_id}", input: { roleNames: [#{names}] }) {
        result { id }
        errors { message }
      }
    }
    """
  end

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

  defp create_workspace_query(slug, name) do
    """
    mutation {
      createWorkspace(input: { slug: "#{slug}", name: "#{name}" }) {
        result { id }
        errors { message }
      }
    }
    """
  end

  describe "permissionMatrix (#66 Rbac contract, #1 abilities as generic list)" do
    test "anonymous is unauthorized" do
      res =
        graphql_post(
          build_conn(),
          "query { permissionMatrix { roles { name abilities { name allowed } } } }"
        )

      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] =~ "unauthorized"))
    end

    test "authenticated user gets the 6-role × 6-ability matrix (G1)" do
      _admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      query = """
      query {
        permissionMatrix {
          roles {
            name
            abilities {
              name
              allowed
            }
          }
        }
      }
      """

      res = graphql_post(build_conn(), query, token)

      assert %{"data" => %{"permissionMatrix" => %{"roles" => roles}}} = res
      assert length(roles) == 6

      assert Enum.map(roles, & &1["name"]) ==
               ["owner", "admin", "member", "tutor", "volunteer", "learner"]

      by_name =
        Map.new(
          roles,
          &{&1["name"], Map.new(&1["abilities"], fn a -> {a["name"], a["allowed"]} end)}
        )

      for role <- Enum.map(Role.manage_roles(), &to_string/1) do
        abilities = by_name[role]
        assert abilities["view_workspace"] == true
        assert abilities["access_invite_only"] == true
        assert abilities["list_members"] == true
        assert abilities["manage_members"] == true
        assert abilities["assign_roles"] == true
        assert abilities["create_workspace"] == false
      end

      for role <- ["member", "tutor", "volunteer", "learner"] do
        abilities = by_name[role]
        assert abilities["view_workspace"] == true
        assert abilities["access_invite_only"] == true
        assert abilities["list_members"] == false
        assert abilities["manage_members"] == false
        assert abilities["assign_roles"] == false
        assert abilities["create_workspace"] == false
      end
    end
  end

  describe "meWorkspaces.myAbilities (#1 能力接口收敛，替代退役的 myAbilities query)" do
    defp me_workspaces_query do
      """
      query {
        meWorkspaces {
          slug
          myAbilities
        }
      }
      """
    end

    test "owner (platform admin) gets all six abilities" do
      _admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      slug = "gql-rbac-ws-#{System.unique_integer([:positive])}"
      res = graphql_post(build_conn(), create_workspace_query(slug, "GQL Rbac WS"), token)
      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => _ws_id}}}} = res

      res = graphql_post(build_conn(), me_workspaces_query(), token)

      assert %{"data" => %{"meWorkspaces" => workspaces}} = res
      ws = Enum.find(workspaces, &(&1["slug"] == slug))

      assert ws["myAbilities"] == [
               "view_workspace",
               "access_invite_only",
               "list_members",
               "manage_members",
               "assign_roles",
               "create_workspace"
             ]
    end

    test "plain member gets view/access only" do
      admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      slug = "gql-rbac-member-ws-#{System.unique_integer([:positive])}"
      res = graphql_post(build_conn(), create_workspace_query(slug, "GQL Rbac Member WS"), token)
      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => ws_id}}}} = res

      member = register_user(@member_email, @password)
      workspace = Ash.get!(Workspace, ws_id, actor: admin, authorize?: false)

      {:ok, membership} =
        WorkspaceMembership
        |> Ash.Changeset.for_create(:create, %{user_id: member.id})
        |> Ash.create(tenant: workspace.id, actor: admin, authorize?: false)

      assert {:ok, _} =
               membership
               |> Ash.Changeset.for_update(:assign_roles, %{role_names: [:member]})
               |> Ash.update(tenant: workspace.id, actor: admin, authorize?: false)

      member_token = sign_in_token(@member_email, @password)
      res = graphql_post(build_conn(), me_workspaces_query(), member_token)

      assert %{"data" => %{"meWorkspaces" => workspaces}} = res
      ws = Enum.find(workspaces, &(&1["slug"] == slug))
      assert ws["myAbilities"] == ["view_workspace", "access_invite_only"]
    end

    test "outsider's meWorkspaces does not include the workspace" do
      _admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      slug = "gql-rbac-out-#{System.unique_integer([:positive])}"
      res = graphql_post(build_conn(), create_workspace_query(slug, "GQL Rbac Out"), token)
      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => _ws_id}}}} = res

      outsider_email = "gql-rbac-outsider@example.com"
      _outsider = register_user(outsider_email, @password)
      outsider_token = sign_in_token(outsider_email, @password)

      res = graphql_post(build_conn(), me_workspaces_query(), outsider_token)

      assert %{"data" => %{"meWorkspaces" => workspaces}} = res
      refute Enum.any?(workspaces, &(&1["slug"] == slug))
    end

    test "non-member platform admin is not listed (P2: no manage exemption, list is membership-scoped)" do
      admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      slug = "gql-rbac-nm-#{System.unique_integer([:positive])}"
      res = graphql_post(build_conn(), create_workspace_query(slug, "GQL Rbac NonMember"), token)
      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => ws_id}}}} = res

      # 平台管理员移除自己的成员资格 → 非成员场景
      workspace = Ash.get!(Workspace, ws_id, actor: admin, authorize?: false)
      remove_membership(workspace, admin)

      res = graphql_post(build_conn(), me_workspaces_query(), token)

      assert %{"data" => %{"meWorkspaces" => workspaces}} = res
      refute Enum.any?(workspaces, &(&1["slug"] == slug))
    end
  end

  describe "assignRoles grant scope (P0 越权修复)" do
    test "admin (non-owner) cannot grant owner role" do
      owner = admin_user()
      owner_token = sign_in_token(@admin_email, @password)

      slug = "gql-grant-owner-#{System.unique_integer([:positive])}"
      res = graphql_post(build_conn(), create_workspace_query(slug, "Grant Owner"), owner_token)
      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => ws_id}}}} = res

      admin_member_email = "gql-grant-adm#{System.unique_integer([:positive])}@example.com"
      victim_email = "gql-grant-vic#{System.unique_integer([:positive])}@example.com"
      admin_member = register_user(admin_member_email, @password)
      victim = register_user(victim_email, @password)

      workspace = Ash.get!(Workspace, ws_id, actor: owner, authorize?: false)
      add_member(workspace, admin_member, owner, [:admin])
      victim_membership = add_member(workspace, victim, owner)

      # admin（非 owner）尝试授予 owner → 拒绝
      admin_member_token = sign_in_token(admin_member_email, @password)

      res =
        graphql_post(
          build_conn(),
          assign_roles_query(victim_membership.id, [:owner]),
          admin_member_token
        )

      assert %{"data" => %{"assignRoles" => %{"result" => nil, "errors" => errors}}} = res
      assert Enum.any?(errors, &(&1["message"] =~ "只有 Owner 能授予或撤销 Owner 角色"))

      # 数据库未被改动：victim 仍无 owner 角色
      refute :owner in load_role_names(victim_membership)
    end

    test "owner can grant owner role" do
      owner = admin_user()
      owner_token = sign_in_token(@admin_email, @password)

      slug = "gql-grant-owner-ok-#{System.unique_integer([:positive])}"

      res =
        graphql_post(build_conn(), create_workspace_query(slug, "Grant Owner OK"), owner_token)

      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => ws_id}}}} = res

      new_owner_email = "gql-grant-newo#{System.unique_integer([:positive])}@example.com"
      new_owner = register_user(new_owner_email, @password)
      workspace = Ash.get!(Workspace, ws_id, actor: owner, authorize?: false)
      membership = add_member(workspace, new_owner, owner)

      res = graphql_post(build_conn(), assign_roles_query(membership.id, [:owner]), owner_token)
      assert %{"data" => %{"assignRoles" => %{"errors" => []}}} = res

      assert load_role_names(membership) == [:owner]
    end

    test "cannot remove the last owner (orphan protection)" do
      owner = admin_user()
      owner_token = sign_in_token(@admin_email, @password)

      slug = "gql-last-owner-#{System.unique_integer([:positive])}"
      res = graphql_post(build_conn(), create_workspace_query(slug, "Last Owner"), owner_token)
      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => ws_id}}}} = res

      workspace = Ash.get!(Workspace, ws_id, actor: owner, authorize?: false)
      owner_membership = find_membership(workspace, owner)

      # owner 自降 admin（唯一 owner）→ 孤儿保护拒绝
      res =
        graphql_post(
          build_conn(),
          assign_roles_query(owner_membership.id, [:admin]),
          owner_token
        )

      assert %{"data" => %{"assignRoles" => %{"result" => nil, "errors" => errors}}} = res
      assert Enum.any?(errors, &(&1["message"] =~ "至少保留一个 Owner"))

      # 数据库未被改动：owner 仍是 owner
      assert load_role_names(owner_membership) == [:owner]
    end

    test "owner can self-demote when another owner remains" do
      owner = admin_user()
      owner_token = sign_in_token(@admin_email, @password)

      slug = "gql-two-owner-#{System.unique_integer([:positive])}"
      res = graphql_post(build_conn(), create_workspace_query(slug, "Two Owner"), owner_token)
      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => ws_id}}}} = res

      co_owner_email = "gql-two-owner2#{System.unique_integer([:positive])}@example.com"
      co_owner = register_user(co_owner_email, @password)
      workspace = Ash.get!(Workspace, ws_id, actor: owner, authorize?: false)
      co_membership = add_member(workspace, co_owner, owner, [:owner])

      owner_membership = find_membership(workspace, owner)

      # 2 个 owner：owner 自降 admin 允许
      res =
        graphql_post(
          build_conn(),
          assign_roles_query(owner_membership.id, [:admin]),
          owner_token
        )

      assert %{"data" => %{"assignRoles" => %{"errors" => []}}} = res

      assert load_role_names(owner_membership) == [:admin]
      assert load_role_names(co_membership) == [:owner]
    end
  end
end
