defmodule Cgc2046.Accounts.WorkspaceTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Accounts.WorkspaceMembership
  alias Cgc2046.Rbac
  alias AshAuthentication.Info, as: AuthInfo

  @admin_email "admin@example.com"
  @normal_email "normal@example.com"
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
    register_user(@normal_email, @password)
  end

  # 以 owner/admin 身份把一个用户拉进工作台（测试直接建成员资格）
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

  describe "create workspace" do
    test "platform admin can create a workspace with defaults" do
      admin = admin_user()

      assert {:ok, workspace} =
               Workspace
               |> Ash.Changeset.for_create(:create, %{slug: "my-workspace", name: "My Workspace"})
               |> Ash.create(actor: admin)

      assert workspace.slug == "my-workspace"
      assert workspace.name == "My Workspace"
      assert workspace.join_policy == :request
      assert workspace.sponsorship_enabled == true
    end

    test "non-admin cannot create a workspace" do
      user = normal_user()

      assert {:error, %Ash.Error.Forbidden{}} =
               Workspace
               |> Ash.Changeset.for_create(:create, %{slug: "my-workspace", name: "My Workspace"})
               |> Ash.create(actor: user)
    end

    test "anonymous user cannot create a workspace" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Workspace
               |> Ash.Changeset.for_create(:create, %{slug: "my-workspace", name: "My Workspace"})
               |> Ash.create()
    end
  end

  describe "slug" do
    setup do
      {:ok, admin: admin_user()}
    end

    test "slug must be unique", %{admin: admin} do
      assert {:ok, _workspace} =
               Workspace
               |> Ash.Changeset.for_create(:create, %{slug: "unique-slug", name: "One"})
               |> Ash.create(actor: admin)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Workspace
               |> Ash.Changeset.for_create(:create, %{slug: "unique-slug", name: "Two"})
               |> Ash.create(actor: admin)

      assert Enum.any?(errors, fn error -> Exception.message(error) =~ "already been taken" end)
    end

    test "rejects invalid slug formats", %{admin: admin} do
      for bad <- ["Uppercase", "has space", "has_underscore", "中文", ""] do
        assert {:error, %Ash.Error.Invalid{errors: errors}} =
                 Workspace
                 |> Ash.Changeset.for_create(:create, %{slug: bad, name: "Bad"})
                 |> Ash.create(actor: admin)

        assert Enum.any?(errors, fn error -> Exception.message(error) =~ "slug" end),
               "expected slug #{inspect(bad)} to be rejected"
      end
    end

    test "accepts valid slug formats", %{admin: admin} do
      for good <- ["a", "a-b", "abc-123", "my-workspace-2"] do
        assert {:ok, workspace} =
                 Workspace
                 |> Ash.Changeset.for_create(:create, %{slug: good, name: "Good"})
                 |> Ash.create(actor: admin)

        assert workspace.slug == good
      end
    end
  end

  describe "join_policy" do
    setup do
      {:ok, admin: admin_user()}
    end

    test "accepts the three allowed values", %{admin: admin} do
      for policy <- [:open, :request, :invite_only] do
        slug = "ws-#{policy}" |> String.replace("_", "-")

        assert {:ok, workspace} =
                 Workspace
                 |> Ash.Changeset.for_create(:create, %{
                   slug: slug,
                   name: "WS",
                   join_policy: policy
                 })
                 |> Ash.create(actor: admin)

        assert workspace.join_policy == policy
      end
    end

    test "rejects invalid join_policy values", %{admin: admin} do
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Workspace
               |> Ash.Changeset.for_create(:create, %{
                 slug: "bad-policy",
                 name: "WS",
                 join_policy: :public
               })
               |> Ash.create(actor: admin)

      assert Enum.any?(errors, fn error -> Exception.message(error) =~ "join_policy" end)
    end
  end

  describe "sponsorship_enabled" do
    test "defaults to true" do
      admin = admin_user()

      assert {:ok, workspace} =
               Workspace
               |> Ash.Changeset.for_create(:create, %{slug: "sponsorship-default", name: "WS"})
               |> Ash.create(actor: admin)

      assert workspace.sponsorship_enabled == true
    end

    test "can be set to false by admin" do
      admin = admin_user()

      assert {:ok, workspace} =
               Workspace
               |> Ash.Changeset.for_create(:create, %{
                 slug: "sponsorship-off",
                 name: "WS",
                 sponsorship_enabled: false
               })
               |> Ash.create(actor: admin)

      assert workspace.sponsorship_enabled == false
    end
  end

  describe "read workspace" do
    test "any authenticated user can get a workspace by slug" do
      admin = admin_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{slug: "readable-ws", name: "Readable"})
        |> Ash.create(actor: admin)

      user = normal_user()

      assert {:ok, fetched} =
               Workspace
               |> Ash.Query.for_read(:get_by_slug, %{slug: "readable-ws"})
               |> Ash.read_one(actor: user)

      assert fetched.id == workspace.id
    end

    test "anonymous user cannot read a workspace" do
      admin = admin_user()

      {:ok, _workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{slug: "secret-ws", name: "Secret"})
        |> Ash.create(actor: admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               Workspace
               |> Ash.Query.for_read(:get_by_slug, %{slug: "secret-ws"})
               |> Ash.read_one()
    end

    test "invite_only workspace: outsider cannot read (null/forbidden)" do
      admin = admin_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "invite-read-only-#{System.unique_integer([:positive])}",
          name: "Invite Only",
          join_policy: :invite_only
        })
        |> Ash.create(actor: admin)

      outsider = register_user("invite-out@example.com", @password)

      result =
        Workspace
        |> Ash.Query.for_read(:get_by_slug, %{slug: workspace.slug})
        |> Ash.read_one(actor: outsider)

      # 非成员读不到 invite_only：要么被过滤为 nil，要么被 forbid
      assert result == {:ok, nil} or match?({:error, %Ash.Error.Forbidden{}}, result)
    end

    test "invite_only workspace: member can read" do
      admin = admin_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "invite-read-member-#{System.unique_integer([:positive])}",
          name: "Invite Only",
          join_policy: :invite_only
        })
        |> Ash.create(actor: admin)

      member = register_user("invite-member@example.com", @password)
      add_member(workspace, member, admin, [:member])

      assert {:ok, fetched} =
               Workspace
               |> Ash.Query.for_read(:get_by_slug, %{slug: workspace.slug})
               |> Ash.read_one(actor: member)

      assert fetched.id == workspace.id
    end

    test "invite_only workspace: platform admin can read" do
      admin = admin_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "invite-read-admin-#{System.unique_integer([:positive])}",
          name: "Invite Only",
          join_policy: :invite_only
        })
        |> Ash.create(actor: admin)

      assert {:ok, fetched} =
               Workspace
               |> Ash.Query.for_read(:get_by_slug, %{slug: workspace.slug})
               |> Ash.read_one(actor: admin)

      assert fetched.id == workspace.id
    end
  end

  describe "member_count calculation (P1)" do
    test "returns member count including the owner creator" do
      admin = admin_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "mc-#{System.unique_integer([:positive])}",
          name: "MC"
        })
        |> Ash.create(actor: admin)

      # 创建者自动成为 owner 成员 → 1
      fetched =
        Ash.get!(Workspace, workspace.id,
          actor: admin,
          load: [:member_count],
          domain: Cgc2046.GlobalApi
        )

      assert fetched.member_count == 1

      # 拉入 2 个普通成员 → 3
      for i <- 1..2 do
        user =
          register_user(
            "mc-user-#{i}-#{System.unique_integer([:positive])}@example.com",
            @password
          )

        add_member(workspace, user, admin, [:member])
      end

      fetched =
        Ash.get!(Workspace, workspace.id,
          actor: admin,
          load: [:member_count],
          domain: Cgc2046.GlobalApi
        )

      assert fetched.member_count == 3
    end
  end

  describe "my_abilities calculation (#1 能力接口，与 Rbac.abilities/2 语义一致)" do
    test "owner member gets all six abilities (incl. create_workspace)" do
      admin = admin_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "abil-#{System.unique_integer([:positive])}",
          name: "ABIL"
        })
        |> Ash.create(actor: admin)

      fetched =
        Ash.get!(Workspace, workspace.id,
          actor: admin,
          load: [:my_abilities],
          domain: Cgc2046.GlobalApi
        )

      assert fetched.my_abilities == [
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

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "abil-m-#{System.unique_integer([:positive])}",
          name: "ABILM"
        })
        |> Ash.create(actor: admin)

      member =
        register_user("abil-m-#{System.unique_integer([:positive])}@example.com", @password)

      add_member(workspace, member, admin, [:member])

      fetched =
        Ash.get!(Workspace, workspace.id,
          actor: member,
          load: [:my_abilities],
          domain: Cgc2046.GlobalApi
        )

      assert fetched.my_abilities == ["view_workspace", "access_invite_only"]
    end

    test "non-member platform admin gets view/access + create_workspace (matches Rbac.abilities/2)" do
      admin = admin_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "abil-nm-#{System.unique_integer([:positive])}",
          name: "ABILNM"
        })
        |> Ash.create(actor: admin)

      # 移除 admin 自己的成员资格（先删 membership_roles，避免外键保护）
      loaded =
        Ash.load!(workspace, :memberships,
          tenant: workspace.id,
          actor: admin,
          authorize?: false
        )

      membership = Enum.find(loaded.memberships, &(&1.user_id == admin.id))

      Ecto.Adapters.SQL.query!(
        Cgc2046.Repo,
        "DELETE FROM membership_roles WHERE membership_id = $1",
        [Ecto.UUID.dump!(membership.id)]
      )

      Ash.destroy!(membership, tenant: workspace.id, actor: admin, authorize?: false)

      fetched =
        Ash.get!(Workspace, workspace.id,
          actor: admin,
          load: [:my_abilities],
          domain: Cgc2046.GlobalApi
        )

      # 与 Rbac.abilities/2 非成员平台管理员分支一致（#1 语义单源）
      assert fetched.my_abilities == ["view_workspace", "access_invite_only", "create_workspace"]

      # 对照 Rbac.abilities/2 直调结果完全一致
      assert Rbac.abilities(admin, workspace_id: workspace.id) ==
               Enum.map(fetched.my_abilities, &String.to_atom/1)
    end

    test "non-member non-admin gets []" do
      admin = admin_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "abil-out-#{System.unique_integer([:positive])}",
          name: "ABILOUT"
        })
        |> Ash.create(actor: admin)

      outsider =
        register_user("abil-out-#{System.unique_integer([:positive])}@example.com", @password)

      fetched =
        Ash.get!(Workspace, workspace.id,
          actor: outsider,
          load: [:my_abilities],
          domain: Cgc2046.GlobalApi
        )

      assert fetched.my_abilities == []
    end
  end

  describe "membership user_* / joined_at calculations (P1 G6/G7)" do
    test "owner reading memberships gets userEmail/userDisplayName/joinedAt (flattened, bypassing user read policy)" do
      admin = admin_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "mbr-calc-#{System.unique_integer([:positive])}",
          name: "MBRCALC"
        })
        |> Ash.create(actor: admin)

      member =
        register_user("mbr-calc-m-#{System.unique_integer([:positive])}@example.com", @password)

      # 给 member 设置 display_name
      {:ok, member} =
        member
        |> Ash.Changeset.for_update(:update_profile, %{display_name: "Calc Member"})
        |> Ash.update(actor: member)

      add_member(workspace, member, admin, [:member])

      require Ash.Query

      {:ok, memberships} =
        WorkspaceMembership
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(workspace_id == ^workspace.id)
        |> Ash.read(
          actor: admin,
          tenant: workspace.id,
          load: [:user_email, :user_display_name, :joined_at],
          domain: Cgc2046.GlobalApi
        )

      by_email = Map.new(memberships, &{&1.user_email, &1})
      assert Map.has_key?(by_email, to_string(admin.email))
      assert Map.has_key?(by_email, to_string(member.email))

      # member 行：userEmail / userDisplayName 平铺字段可见（即使不是本人读）
      member_ms = by_email[to_string(member.email)]
      assert member_ms.user_email == to_string(member.email)
      assert member_ms.user_display_name == "Calc Member"
      assert not is_nil(member_ms.joined_at)

      # owner 行：joined_at = inserted_at
      owner_ms = by_email[to_string(admin.email)]
      assert not is_nil(owner_ms.joined_at)
    end

    test "regular member only sees own membership row (cannot read others' emails)" do
      admin = admin_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "mbr-neg-#{System.unique_integer([:positive])}",
          name: "MBRNEG"
        })
        |> Ash.create(actor: admin)

      member_a =
        register_user("mbr-neg-a-#{System.unique_integer([:positive])}@example.com", @password)

      member_b =
        register_user("mbr-neg-b-#{System.unique_integer([:positive])}@example.com", @password)

      add_member(workspace, member_a, admin, [:member])
      add_member(workspace, member_b, admin, [:member])

      require Ash.Query

      {:ok, memberships} =
        WorkspaceMembership
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(workspace_id == ^workspace.id)
        |> Ash.read(
          actor: member_a,
          tenant: workspace.id,
          load: [:user_email, :user_display_name],
          domain: Cgc2046.GlobalApi
        )

      # read policy 只放行本人行 → 只返回自己的成员资格
      assert [own] = memberships
      assert own.user_id == member_a.id
      assert own.user_email == to_string(member_a.email)

      # 负向：看不到其他成员（含 owner/admin）的 email / 行
      refute Enum.any?(memberships, &(&1.user_email == to_string(member_b.email)))
      refute Enum.any?(memberships, &(&1.user_id == member_b.id))
      refute Enum.any?(memberships, &(&1.user_email == to_string(admin.email)))
    end
  end

  describe "update workspace" do
    test "platform admin can update join_policy" do
      admin = admin_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{slug: "updatable-ws", name: "Updatable"})
        |> Ash.create(actor: admin)

      assert {:ok, updated} =
               workspace
               |> Ash.Changeset.for_update(:update, %{join_policy: :invite_only})
               |> Ash.update(actor: admin)

      assert updated.join_policy == :invite_only
    end

    test "non-admin cannot update a workspace" do
      admin = admin_user()
      user = normal_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{slug: "locked-ws", name: "Locked"})
        |> Ash.create(actor: admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               workspace
               |> Ash.Changeset.for_update(:update, %{join_policy: :invite_only})
               |> Ash.update(actor: user)
    end
  end

  describe "GraphQL createWorkspace mutation" do
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

    defp create_workspace_query(slug, name, join_policy \\ nil) do
      policy_arg =
        case join_policy do
          nil -> ""
          value -> ", joinPolicy: \"#{value}\""
        end

      """
      mutation {
        createWorkspace(input: { slug: "#{slug}", name: "#{name}"#{policy_arg} }) {
          result { id slug name joinPolicy sponsorshipEnabled }
          errors { message }
        }
      }
      """
    end

    test "platform admin can create a workspace via GraphQL" do
      admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      res = graphql_post(build_conn(), create_workspace_query("graphql-ws", "GraphQL WS"), token)

      assert %{"data" => %{"createWorkspace" => %{"result" => result, "errors" => []}}} = res
      assert result["slug"] == "graphql-ws"
      assert result["name"] == "GraphQL WS"
      assert result["joinPolicy"] == "request"
      assert result["sponsorshipEnabled"] == true
      refute is_nil(admin.id)
    end

    test "non-admin cannot create a workspace via GraphQL" do
      _user = normal_user()
      token = sign_in_token(@normal_email, @password)

      res =
        graphql_post(
          build_conn(),
          create_workspace_query("forbidden-ws", "Forbidden"),
          token
        )

      assert %{"data" => %{"createWorkspace" => %{"result" => result, "errors" => errors}}} = res
      assert is_nil(result)
      assert Enum.any?(errors, &(&1["message"] =~ "forbidden"))
    end

    test "anonymous cannot create a workspace via GraphQL" do
      res = graphql_post(build_conn(), create_workspace_query("anon-ws", "Anon"))

      assert %{"data" => %{"createWorkspace" => %{"result" => result, "errors" => errors}}} = res
      assert is_nil(result)
      assert Enum.any?(errors, &(&1["message"] =~ "forbidden"))
    end

    test "platform admin can create workspace with joinPolicy invite_only via GraphQL" do
      _admin = admin_user()
      token = sign_in_token(@admin_email, @password)

      res =
        graphql_post(
          build_conn(),
          create_workspace_query("invite-only-ws", "Invite Only", "invite_only"),
          token
        )

      assert %{"data" => %{"createWorkspace" => %{"result" => result}}} = res
      assert result["joinPolicy"] == "invite_only"
    end
  end
end
