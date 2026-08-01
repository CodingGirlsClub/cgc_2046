defmodule Cgc2046Web.GraphqlRbacTest do
  use Cgc2046Web.ConnCase, async: true

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

  describe "permissionMatrix (#66 Rbac contract)" do
    test "anonymous is unauthorized" do
      res =
        graphql_post(
          build_conn(),
          "query { permissionMatrix { roles { name abilities { viewWorkspace } } } }"
        )

      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] =~ "unauthorized"))
    end

    test "authenticated user gets the 3-role × 6-ability matrix" do
      _admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      query = """
      query {
        permissionMatrix {
          roles {
            name
            abilities {
              viewWorkspace
              accessInviteOnly
              listMembers
              manageMembers
              assignRoles
              createWorkspace
            }
          }
        }
      }
      """

      res = graphql_post(build_conn(), query, token)

      assert %{"data" => %{"permissionMatrix" => %{"roles" => roles}}} = res
      assert length(roles) == 3
      assert Enum.map(roles, & &1["name"]) == ["owner", "admin", "member"]

      by_name = Map.new(roles, &{&1["name"], &1["abilities"]})

      for role <- ["owner", "admin"] do
        abilities = by_name[role]
        assert abilities["viewWorkspace"] == true
        assert abilities["accessInviteOnly"] == true
        assert abilities["listMembers"] == true
        assert abilities["manageMembers"] == true
        assert abilities["assignRoles"] == true
        assert abilities["createWorkspace"] == false
      end

      member = by_name["member"]
      assert member["viewWorkspace"] == true
      assert member["accessInviteOnly"] == true
      assert member["listMembers"] == false
      assert member["manageMembers"] == false
      assert member["assignRoles"] == false
      assert member["createWorkspace"] == false
    end
  end

  describe "myAbilities (#66 Rbac contract)" do
    test "anonymous is unauthorized" do
      res =
        graphql_post(
          build_conn(),
          """
          query {
            myAbilities(workspaceId: "00000000-0000-0000-0000-000000000000") {
              abilities
            }
          }
          """
        )

      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] =~ "unauthorized"))
    end

    test "returns the actor's ability list for a workspace" do
      admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      slug = "gql-rbac-ws-#{System.unique_integer([:positive])}"
      res = graphql_post(build_conn(), create_workspace_query(slug, "GQL Rbac WS"), token)
      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => ws_id}}}} = res

      # owner（admin 自建）的能力
      query = """
      query {
        myAbilities(workspaceId: "#{ws_id}") {
          abilities
        }
      }
      """

      res = graphql_post(build_conn(), query, token)
      assert %{"data" => %{"myAbilities" => %{"abilities" => abilities}}} = res

      # owner（平台管理员自建）拥有全部六项能力（含 create_workspace）
      assert abilities == [
               "view_workspace",
               "access_invite_only",
               "list_members",
               "manage_members",
               "assign_roles",
               "create_workspace"
             ]

      # 普通成员的能力（仅基础访问）
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
      res = graphql_post(build_conn(), query, member_token)

      assert %{"data" => %{"myAbilities" => %{"abilities" => member_abilities}}} = res
      assert member_abilities == ["view_workspace", "access_invite_only"]
    end

    test "outsider gets empty ability list" do
      _admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      slug = "gql-rbac-out-#{System.unique_integer([:positive])}"
      res = graphql_post(build_conn(), create_workspace_query(slug, "GQL Rbac Out"), token)
      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => ws_id}}}} = res

      outsider_email = "gql-rbac-outsider@example.com"
      _outsider = register_user(outsider_email, @password)
      outsider_token = sign_in_token(outsider_email, @password)

      query = """
      query {
        myAbilities(workspaceId: "#{ws_id}") {
          abilities
        }
      }
      """

      res = graphql_post(build_conn(), query, outsider_token)

      assert %{"data" => %{"myAbilities" => %{"abilities" => abilities}}} = res
      assert abilities == []
    end

    test "non-member platform admin gets view/access + create_workspace only (P2)" do
      admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      slug = "gql-rbac-nm-#{System.unique_integer([:positive])}"
      res = graphql_post(build_conn(), create_workspace_query(slug, "GQL Rbac NonMember"), token)
      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => ws_id}}}} = res

      # 平台管理员移除自己的成员资格 → 非成员场景
      workspace = Ash.get!(Workspace, ws_id, actor: admin, authorize?: false)
      remove_membership(workspace, admin)

      query = """
      query {
        myAbilities(workspaceId: "#{ws_id}") {
          abilities
        }
      }
      """

      res = graphql_post(build_conn(), query, token)

      assert %{"data" => %{"myAbilities" => %{"abilities" => abilities}}} = res
      assert abilities == ["view_workspace", "access_invite_only", "create_workspace"]
    end
  end
end
