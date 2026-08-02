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

  describe "GraphQL members contract" do
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

    test "owner can list members with roles filtered by workspace" do
      admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      slug = "gql-members-#{System.unique_integer([:positive])}"
      res = graphql_post(build_conn(), create_workspace_query(slug, "GQL Members"), token)
      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => ws_id}}}} = res

      # 加入一个普通成员并分配角色
      user = normal_user()
      workspace = Ash.get!(Workspace, ws_id, actor: admin, authorize?: false)
      add_member(workspace, user, admin, [:admin, :member])

      members_query = """
      query {
        workspaceMembers(filter: { workspaceId: { eq: "#{ws_id}" } }) {
          count
          results {
            id
            userId
            roles { id name }
          }
        }
      }
      """

      res = graphql_post(build_conn(), members_query, token)

      assert %{
               "data" => %{
                 "workspaceMembers" => %{"count" => 2, "results" => results}
               }
             } = res

      assert length(results) == 2

      member_result =
        Enum.find(results, fn r -> r["userId"] == user.id end)

      assert member_result != nil
      assert Enum.map(member_result["roles"], & &1["name"]) |> Enum.sort() == ["admin", "member"]

      owner_result =
        Enum.find(results, fn r -> r["userId"] == admin.id end)

      assert Enum.map(owner_result["roles"], & &1["name"]) == ["owner"]
    end

    test "member can only see their own membership record" do
      admin = admin_user()
      user = normal_user()
      admin_token = sign_in_token(@admin_email, @password)
      token = sign_in_token(@member_email, @password)

      slug = "gql-self-#{System.unique_integer([:positive])}"
      res = graphql_post(build_conn(), create_workspace_query(slug, "GQL Self"), admin_token)
      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => ws_id}}}} = res

      workspace = Ash.get!(Workspace, ws_id, actor: admin, authorize?: false)
      add_member(workspace, user, admin, [:member])

      members_query = """
      query {
        workspaceMembers(filter: { workspaceId: { eq: "#{ws_id}" } }) {
          count
          results { id userId roles { name } }
        }
      }
      """

      res = graphql_post(build_conn(), members_query, token)

      assert %{
               "data" => %{
                 "workspaceMembers" => %{"count" => 1, "results" => [own]}
               }
             } = res

      assert own["userId"] == user.id
    end

    test "assignRoles via GraphQL replaces roles for owner" do
      admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      slug = "gql-assign-#{System.unique_integer([:positive])}"
      res = graphql_post(build_conn(), create_workspace_query(slug, "GQL Assign"), token)
      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => ws_id}}}} = res

      user = normal_user()
      workspace = Ash.get!(Workspace, ws_id, actor: admin, authorize?: false)
      membership = add_member(workspace, user, admin, [:member])

      assign_query = """
      mutation {
        assignRoles(
          id: "#{membership.id}"
          input: { roleNames: ["admin", "member"] }
        ) {
          result { id }
          errors { message }
        }
      }
      """

      res = graphql_post(build_conn(), assign_query, token)
      assert %{"data" => %{"assignRoles" => %{"errors" => []}}} = res

      updated = Ash.get!(WorkspaceMembership, membership.id, tenant: ws_id, actor: admin)
      assert load_role_names(updated) == [:admin, :member]
    end

    test "plain member assignRoles via GraphQL is forbidden" do
      admin = admin_user()
      user = normal_user()
      admin_token = sign_in_token(@admin_email, @password)
      token = sign_in_token(@member_email, @password)

      slug = "gql-forbid-#{System.unique_integer([:positive])}"
      res = graphql_post(build_conn(), create_workspace_query(slug, "GQL Forbid"), admin_token)
      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => ws_id}}}} = res

      workspace = Ash.get!(Workspace, ws_id, actor: admin, authorize?: false)
      add_member(workspace, user, admin, [:member])

      members_query = """
      query {
        workspaceMembers(filter: { workspaceId: { eq: "#{ws_id}" } }) {
          results { id }
        }
      }
      """

      # 普通成员只能看到自己的 membership
      res = graphql_post(build_conn(), members_query, token)
      assert %{"data" => %{"workspaceMembers" => %{"results" => [own]}}} = res

      assign_query = """
      mutation {
        assignRoles(id: "#{own["id"]}", input: { roleNames: ["admin"] }) {
          result { id }
          errors { message }
        }
      }
      """

      res = graphql_post(build_conn(), assign_query, token)
      assert %{"data" => %{"assignRoles" => %{"result" => nil, "errors" => errors}}} = res
      assert Enum.any?(errors, &(&1["message"] =~ "forbidden"))
    end
  end
end
