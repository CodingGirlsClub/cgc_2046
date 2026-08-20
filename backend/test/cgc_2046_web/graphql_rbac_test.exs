defmodule Cgc2046Web.GraphqlRbacTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.Role
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.AccountsFixtures, as: Fixtures

  @password Fixtures.password()

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
      signIn(login: "#{email}", password: "#{password}") {
        id
      }
    }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => query})

    assert %{"data" => %{"signIn" => %{"id" => _id}}} = json_response(conn, 200)
    # token 由后端 before_send 写 httpOnly cookie，从 Set-Cookie 头提取
    token = conn.resp_cookies["cgc_token"].value
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

  defp create_join_request_query(workspace_id, user_id) do
    """
    mutation {
      createJoinRequest(input: { workspaceId: "#{workspace_id}", userId: "#{user_id}" }) {
        result { id }
        errors { message code }
      }
    }
    """
  end

  defp approve_join_request_query(join_request_id, role_names) do
    names = role_names |> Enum.map(&("\"" <> to_string(&1) <> "\"")) |> Enum.join(", ")

    """
    mutation {
      approveJoinRequest(id: "#{join_request_id}", input: { roleNames: [#{names}] }) {
        result { id status }
        errors { message }
      }
    }
    """
  end

  defp update_workspace_query(workspace_id, join_policy) do
    """
    mutation {
      updateWorkspace(id: "#{workspace_id}", input: { joinPolicy: "#{join_policy}" }) {
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

    test "authenticated user gets the 5-role × 8-ability matrix (G1)" do
      admin = Fixtures.platform_admin("gql-rbac-admin")
      token = sign_in_token(admin.email, @password)

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
      assert length(roles) == 5

      assert Enum.map(roles, & &1["name"]) ==
               ["owner", "admin", "tutor", "volunteer", "learner"]

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
        assert abilities["manage_events"] == true
      end

      for role <- ["tutor", "volunteer", "learner"] do
        abilities = by_name[role]
        assert abilities["view_workspace"] == true
        assert abilities["access_invite_only"] == true
        assert abilities["list_members"] == false
        assert abilities["manage_members"] == false
        assert abilities["assign_roles"] == false
        assert abilities["manage_events"] == false
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

    test "owner (platform admin) gets all eight abilities" do
      admin = Fixtures.platform_admin("gql-rbac-admin")
      token = sign_in_token(admin.email, @password)

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
               "update_join_policy",
               "manage_events",
               "create_workspace"
             ]
    end

    test "plain member gets view/access only" do
      admin = Fixtures.platform_admin("gql-rbac-admin")
      token = sign_in_token(admin.email, @password)

      slug = "gql-rbac-member-ws-#{System.unique_integer([:positive])}"
      res = graphql_post(build_conn(), create_workspace_query(slug, "GQL Rbac Member WS"), token)
      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => ws_id}}}} = res

      member = Fixtures.register_user("gql-rbac-member")
      workspace = Ash.get!(Workspace, ws_id, actor: admin, authorize?: false)
      Fixtures.add_member(workspace, member)

      member_token = sign_in_token(member.email, @password)
      res = graphql_post(build_conn(), me_workspaces_query(), member_token)

      assert %{"data" => %{"meWorkspaces" => workspaces}} = res
      ws = Enum.find(workspaces, &(&1["slug"] == slug))
      assert ws["myAbilities"] == ["view_workspace", "access_invite_only"]
    end

    test "outsider's meWorkspaces does not include the workspace" do
      admin = Fixtures.platform_admin("gql-rbac-admin")
      token = sign_in_token(admin.email, @password)

      slug = "gql-rbac-out-#{System.unique_integer([:positive])}"
      res = graphql_post(build_conn(), create_workspace_query(slug, "GQL Rbac Out"), token)
      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => _ws_id}}}} = res

      outsider = Fixtures.register_user("gql-rbac-outsider")
      outsider_token = sign_in_token(outsider.email, @password)

      res = graphql_post(build_conn(), me_workspaces_query(), outsider_token)

      assert %{"data" => %{"meWorkspaces" => workspaces}} = res
      refute Enum.any?(workspaces, &(&1["slug"] == slug))
    end

    test "non-member platform admin is not listed (P2: no manage exemption, list is membership-scoped)" do
      admin = Fixtures.platform_admin("gql-rbac-admin")
      token = sign_in_token(admin.email, @password)

      slug = "gql-rbac-nm-#{System.unique_integer([:positive])}"
      res = graphql_post(build_conn(), create_workspace_query(slug, "GQL Rbac NonMember"), token)
      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => ws_id}}}} = res

      # 平台管理员移除自己的成员资格 → 非成员场景
      workspace = Ash.get!(Workspace, ws_id, actor: admin, authorize?: false)
      Fixtures.remove_membership(workspace, admin)

      res = graphql_post(build_conn(), me_workspaces_query(), token)

      assert %{"data" => %{"meWorkspaces" => workspaces}} = res
      refute Enum.any?(workspaces, &(&1["slug"] == slug))
    end
  end

  describe "assignRoles grant scope (P0 越权修复)" do
    test "admin (non-owner) cannot grant owner role" do
      owner = Fixtures.platform_admin("gql-rbac-admin")
      owner_token = sign_in_token(owner.email, @password)

      slug = "gql-grant-owner-#{System.unique_integer([:positive])}"
      res = graphql_post(build_conn(), create_workspace_query(slug, "Grant Owner"), owner_token)
      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => ws_id}}}} = res

      admin_member = Fixtures.register_user("gql-grant-adm")
      victim = Fixtures.register_user("gql-grant-vic")

      workspace = Ash.get!(Workspace, ws_id, actor: owner, authorize?: false)
      Fixtures.add_member(workspace, admin_member, [:admin])
      victim_membership = Fixtures.add_member(workspace, victim)

      # admin（非 owner）尝试授予 owner → 拒绝
      admin_member_token = sign_in_token(admin_member.email, @password)

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
      owner = Fixtures.platform_admin("gql-rbac-admin")
      owner_token = sign_in_token(owner.email, @password)

      slug = "gql-grant-owner-ok-#{System.unique_integer([:positive])}"

      res =
        graphql_post(build_conn(), create_workspace_query(slug, "Grant Owner OK"), owner_token)

      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => ws_id}}}} = res

      new_owner = Fixtures.register_user("gql-grant-newo")
      workspace = Ash.get!(Workspace, ws_id, actor: owner, authorize?: false)
      membership = Fixtures.add_member(workspace, new_owner)

      res = graphql_post(build_conn(), assign_roles_query(membership.id, [:owner]), owner_token)
      assert %{"data" => %{"assignRoles" => %{"errors" => []}}} = res

      assert load_role_names(membership) == [:owner]
    end

    test "cannot remove the last owner (orphan protection)" do
      owner = Fixtures.platform_admin("gql-rbac-admin")
      owner_token = sign_in_token(owner.email, @password)

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
      owner = Fixtures.platform_admin("gql-rbac-admin")
      owner_token = sign_in_token(owner.email, @password)

      slug = "gql-two-owner-#{System.unique_integer([:positive])}"
      res = graphql_post(build_conn(), create_workspace_query(slug, "Two Owner"), owner_token)
      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => ws_id}}}} = res

      co_owner = Fixtures.register_user("gql-two-owner2")
      workspace = Ash.get!(Workspace, ws_id, actor: owner, authorize?: false)
      co_membership = Fixtures.add_member(workspace, co_owner, [:owner])

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

  describe "approveJoinRequest get-by-id workspace_id resolution" do
    # 回归守卫：approveJoinRequest 经 GraphQL update mutation 触发 ash_graphql get-by-id
    # 预读（query.resource=JoinRequest, filter=id==jr_id, tenant=nil），policy
    # WorkspaceActorIsOwnerOrAdmin → resolve_workspace_id → workspace_id_by_id_filter。
    # 旧实现硬编码 Ash.get(WorkspaceMembership, id) 用 join_request id 查 membership
    # → nil → policy 误拒。修复后按 query.resource 动态读 JoinRequest → record.workspace_id。
    test "owner can approve join request via GraphQL (get-by-id resolves JoinRequest workspace_id)" do
      owner = Fixtures.platform_admin("gql-rbac-admin")
      owner_token = sign_in_token(owner.email, @password)

      slug = "gql-approve-jr-#{System.unique_integer([:positive])}"

      res = graphql_post(build_conn(), create_workspace_query(slug, "Approve JR WS"), owner_token)
      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => ws_id}}}} = res

      workspace = Ash.get!(Workspace, ws_id, actor: owner, authorize?: false)

      applicant = Fixtures.register_user("gql-approve-app")

      # 创建工作台需 join_policy:request 才能 createJoinRequest（非 open 直接 join）
      {:ok, _} =
        workspace
        |> Ash.Changeset.for_update(:update, %{join_policy: :request}, actor: owner)
        |> Ash.update(actor: owner)

      applicant_token = sign_in_token(applicant.email, @password)

      res =
        graphql_post(
          build_conn(),
          create_join_request_query(ws_id, applicant.id),
          applicant_token
        )

      assert %{"data" => %{"createJoinRequest" => %{"result" => %{"id" => jr_id}}}} = res

      # owner 经 GraphQL approve——这是 get-by-id 预读 + policy 的真实 HTTP 路径
      res =
        graphql_post(build_conn(), approve_join_request_query(jr_id, []), owner_token)

      assert %{
               "data" => %{
                 "approveJoinRequest" => %{"result" => %{"status" => "approved"}, "errors" => []}
               }
             } =
               res

      # membership 已建，applicant 无标签
      membership = find_membership(workspace, applicant)
      assert membership != nil
      assert load_role_names(membership) == []
    end
  end

  describe "createJoinRequest join_policy 拒绝错误形态 (#206)" do
    # 旧实现抛空 Forbidden（无 message/code），AshGraphql unwrap_errors 拍平后
    # errors: []，前端无从得知被拒原因。修复后经 BusinessError 携带稳定 code。
    test "invite_only 工作台 createJoinRequest 返回非空 message + 稳定 code" do
      owner = Fixtures.platform_admin("gql-rbac-admin")
      owner_token = sign_in_token(owner.email, @password)

      slug = "gql-jr-invite-#{System.unique_integer([:positive])}"

      res =
        graphql_post(build_conn(), create_workspace_query(slug, "Invite Only WS"), owner_token)

      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => ws_id}}}} = res

      workspace = Ash.get!(Workspace, ws_id, actor: owner, authorize?: false)

      {:ok, _} =
        workspace
        |> Ash.Changeset.for_update(:update, %{join_policy: :invite_only}, actor: owner)
        |> Ash.update(actor: owner)

      applicant = Fixtures.register_user("gql-jr-invite-app")
      applicant_token = sign_in_token(applicant.email, @password)

      res =
        graphql_post(
          build_conn(),
          create_join_request_query(ws_id, applicant.id),
          applicant_token
        )

      assert %{
               "data" => %{
                 "createJoinRequest" => %{"result" => nil, "errors" => [error | _]}
               }
             } = res

      assert error["code"] == "join_request_invite_only",
             "invite_only 拒绝 code 应为 join_request_invite_only，实际 #{inspect(error)}"

      assert is_binary(error["message"]) and error["message"] != "",
             "invite_only 拒绝 message 应非空，实际 #{inspect(error)}"
    end
  end

  describe "updateWorkspace non-platform-admin owner (#88)" do
    # 守卫「非平台管理员 Owner 经 GraphQL 更新工作台」用户契约。此前所有 GraphQL
    # 测试的 owner 都是平台管理员（is_platform_admin fallback 掩盖 policy 路径），
    # 本测试是唯一覆盖普通用户 owner 经 GraphQL 改工作台（如 join_policy）的。
    #
    # #88 背景：旧版 ash_graphql update resolver 用 get-by-id 预读（query 形态 policy
    # 求值），workspace_id_by_id_filter 点访问 %Workspace{}.workspace_id（Workspace
    # 无该字段）抛 KeyError。当前版本 resolver 改用 Ash.bulk_update
    # （deps/ash_graphql resolver.ex:1716），update policy 在 changeset 形态求值，
    # #78 workspace_self_id 已覆盖 Workspace 自身更新——故本测试在 #88 修复前后均绿，
    # 不直接守卫 query 分支（该分支由 membership_context_test.exs「场景3 Workspace
    # 资源自身」钉测守卫）。若未来 ash_graphql 行为回退至 get-by-id 预读，本测试
    # 将转红并指向 #88 修复点，起到未来防御作用。
    # 关键：owner 必须是非平台管理员普通用户，否则平台管理员 fallback 恒绿。
    test "non-platform-admin owner can update workspace via GraphQL" do
      admin = Fixtures.platform_admin("gql-rbac-admin")
      admin_token = sign_in_token(admin.email, @password)

      slug = "gql-upd-ws-#{System.unique_integer([:positive])}"
      res = graphql_post(build_conn(), create_workspace_query(slug, "GQL Update WS"), admin_token)
      assert %{"data" => %{"createWorkspace" => %{"result" => %{"id" => ws_id}}}} = res

      workspace = Ash.get!(Workspace, ws_id, actor: admin, authorize?: false)

      # 普通用户（非平台管理员）成为 owner
      owner = Fixtures.register_user("gql-updws-owner")
      Fixtures.add_member(workspace, owner, [:owner])

      owner_token = sign_in_token(owner.email, @password)

      # owner 经 GraphQL updateWorkspace 改 join_policy——get-by-id 预读 + policy 的真实 HTTP 路径
      res =
        graphql_post(build_conn(), update_workspace_query(ws_id, "invite_only"), owner_token)

      assert %{
               "data" => %{
                 "updateWorkspace" => %{"result" => %{"id" => ^ws_id}, "errors" => []}
               }
             } = res

      # DB 生效
      updated = Ash.get!(Workspace, ws_id, actor: admin, authorize?: false)
      assert updated.join_policy == :invite_only
    end
  end
end
