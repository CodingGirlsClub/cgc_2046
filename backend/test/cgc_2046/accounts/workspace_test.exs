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
  # 注（#78 review SUGGESTED-2）：for_update 必须携带 actor/tenant（Owner 角色
  # 授予校验读 changeset context；tenant 供多租户 update），与 #64 的 P0 grant
  # scope 约定一致；authorize?: false 仅旁路授权、不旁路 action 校验。
  defp add_member(workspace, user, actor, role_names) do
    {:ok, membership} =
      WorkspaceMembership
      |> Ash.Changeset.for_create(:create, %{user_id: user.id})
      |> Ash.create(tenant: workspace.id, actor: actor, authorize?: false)

    if role_names != [] do
      assert {:ok, _membership} =
               membership
               |> Ash.Changeset.for_update(
                 :assign_roles,
                 %{role_names: role_names},
                 actor: actor,
                 tenant: workspace.id
               )
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

  describe "create workspace with designated owner (Phase 4 / D1)" do
    test "owner_user_id specified -> Owner membership is created for that user, not the actor" do
      admin = admin_user()
      owner = register_user("ws-owner-id@example.com", @password)

      assert {:ok, workspace} =
               Workspace
               |> Ash.Changeset.for_create(:create, %{
                 slug: "ws-owner-id-#{System.unique_integer([:positive])}",
                 name: "Owner ID WS",
                 owner_user_id: owner.id
               })
               |> Ash.create(actor: admin)

      # Owner membership 建给指定用户
      assert Cgc2046.Accounts.MembershipContext.role_names(owner, workspace.id) == [:owner]
      # actor（platform_admin）不再是 Owner
      assert Cgc2046.Accounts.MembershipContext.role_names(admin, workspace.id) == []
    end

    test "owner_email specified -> active Invitation created with preauthorized [:owner]" do
      admin = admin_user()

      assert {:ok, workspace} =
               Workspace
               |> Ash.Changeset.for_create(:create, %{
                 slug: "ws-owner-email-#{System.unique_integer([:positive])}",
                 name: "Owner Email WS",
                 owner_email: "future-owner@example.com"
               })
               |> Ash.create(actor: admin)

      require Ash.Query

      assert {:ok, invitations} =
               Cgc2046.Accounts.Invitation
               |> Ash.Query.for_read(:read)
               |> Ash.Query.filter(target_email == "future-owner@example.com")
               |> Ash.read(tenant: workspace.id, actor: admin)

      assert [invitation] = invitations
      assert invitation.status == :active
      assert invitation.preauthorized_role_names == [:owner]
      assert invitation.workspace_id == workspace.id
      assert invitation.inviter_id == admin.id
      # 明文 token 经 workspace create metadata 一次性交付（R5）
      refute is_nil(workspace.__metadata__[:owner_invitation_token])
      # pending-owner：Owner membership 尚未建立（接受邀请后才有）
      assert Cgc2046.Accounts.MembershipContext.role_names(admin, workspace.id) == []
    end

    test "owner_email invitation accept -> Owner membership is created" do
      admin = admin_user()

      assert {:ok, workspace} =
               Workspace
               |> Ash.Changeset.for_create(:create, %{
                 slug: "ws-owner-accept-#{System.unique_integer([:positive])}",
                 name: "Owner Accept WS",
                 owner_email: "owner-accept@example.com"
               })
               |> Ash.create(actor: admin)

      require Ash.Query

      assert {:ok, invitations} =
               Cgc2046.Accounts.Invitation
               |> Ash.Query.for_read(:read)
               |> Ash.Query.filter(target_email == "owner-accept@example.com")
               |> Ash.read(tenant: workspace.id, actor: admin)

      assert [invitation] = invitations

      # 明文 token 经 workspace create 的 metadata 一次性交付（R5）
      token = workspace.__metadata__[:owner_invitation_token]
      refute is_nil(token)

      acceptor = register_user("owner-accept@example.com", @password)

      assert {:ok, accepted} =
               invitation
               |> Ash.Changeset.for_update(:accept, %{
                 token: token
               })
               |> Ash.update(actor: acceptor)

      assert accepted.status == :used

      # 接受邀请后 Owner membership + owner 角色建立
      assert Cgc2046.Accounts.MembershipContext.role_names(acceptor, workspace.id) == [:owner]
    end

    test "no owner arguments -> fallback to actor.id as Owner" do
      admin = admin_user()

      assert {:ok, workspace} =
               Workspace
               |> Ash.Changeset.for_create(:create, %{
                 slug: "ws-owner-fallback-#{System.unique_integer([:positive])}",
                 name: "Owner Fallback WS"
               })
               |> Ash.create(actor: admin)

      assert Cgc2046.Accounts.MembershipContext.role_names(admin, workspace.id) == [:owner]
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

    test "invite_only 工作台：outsider 读不到行 → member_count 数据不可达（policy 门控契约）" do
      admin = admin_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "mc-invite-#{System.unique_integer([:positive])}",
          name: "MC Invite",
          join_policy: :invite_only
        })
        |> Ash.create(actor: admin)

      member =
        register_user("mc-invite-m-#{System.unique_integer([:positive])}@example.com", @password)

      add_member(workspace, member, admin, [:member])

      outsider =
        register_user("mc-invite-o-#{System.unique_integer([:positive])}@example.com", @password)

      # 安全契约（BypassReads moduledoc）：主查询仍受 policy 门控——旁路聚合
      # 数据只在可读的 workspace 行上计算；读不到行即 count 数据不可达
      result =
        Workspace
        |> Ash.Query.for_read(:get_by_slug, %{slug: workspace.slug})
        |> Ash.read_one(actor: outsider, load: [:member_count])

      assert result == {:ok, nil} or match?({:error, %Ash.Error.Forbidden{}}, result)
    end
  end

  describe "my_abilities calculation (#1 能力接口，与 Rbac.abilities/2 语义一致)" do
    test "owner member gets all seven abilities (incl. create_workspace)" do
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
               "update_join_policy",
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

    test "non-member platform admin gets view/access + update_join_policy + create_workspace (matches Rbac.abilities/2)" do
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

      # 与 Rbac.abilities/2 非成员平台管理员分支一致（#1 语义单源；#78 豁免）
      assert fetched.my_abilities == [
               "view_workspace",
               "access_invite_only",
               "update_join_policy",
               "create_workspace"
             ]

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

      # 给 member 设置 display_name（ADR-0004：User 收窄为全局身份，displayName 经 update_display_name）
      {:ok, member} =
        member
        |> Ash.Changeset.for_update(:update_display_name, %{display_name: "Calc Member"})
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
          load: [:user_email, :user_display_name, :joined_at, :user],
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
      # 旁路存在的理由：平铺字段（userEmail/userDisplayName）对非 owner 可见，
      # 无需嵌套 load user 关系（Phase 2 起 platform_admin 可读 User 全部记录，
      # 此处 admin 是 platform_admin，嵌套 user 可见）。
      assert not is_nil(member_ms.user)

      # owner 行：joined_at = inserted_at；嵌套 user 是本人，可见
      owner_ms = by_email[to_string(admin.email)]
      assert not is_nil(owner_ms.joined_at)
      assert owner_ms.user.email == admin.email
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

    test "owner can update join_policy（#78）" do
      admin = admin_user()
      owner = normal_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{slug: "owner-policy-ws", name: "Owner Policy"})
        |> Ash.create(actor: admin)

      add_member(workspace, owner, admin, [:owner])

      assert {:ok, updated} =
               workspace
               |> Ash.Changeset.for_update(:update, %{join_policy: :invite_only})
               |> Ash.update(actor: owner)

      assert updated.join_policy == :invite_only
    end

    test "admin can update join_policy（#78）" do
      admin = admin_user()
      workspace_admin = normal_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{slug: "admin-policy-ws", name: "Admin Policy"})
        |> Ash.create(actor: admin)

      add_member(workspace, workspace_admin, admin, [:admin])

      assert {:ok, updated} =
               workspace
               |> Ash.Changeset.for_update(:update, %{join_policy: :invite_only})
               |> Ash.update(actor: workspace_admin)

      assert updated.join_policy == :invite_only
    end

    test "regular member cannot update join_policy（#78）" do
      admin = admin_user()
      member = normal_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{slug: "member-policy-ws", name: "Member Policy"})
        |> Ash.create(actor: admin)

      add_member(workspace, member, admin, [:member])

      assert {:error, %Ash.Error.Forbidden{}} =
               workspace
               |> Ash.Changeset.for_update(:update, %{join_policy: :invite_only})
               |> Ash.update(actor: member)
    end

    test "non-member cannot update join_policy（#78）" do
      admin = admin_user()
      outsider = normal_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "outsider-policy-ws",
          name: "Outsider Policy"
        })
        |> Ash.create(actor: admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               workspace
               |> Ash.Changeset.for_update(:update, %{join_policy: :invite_only})
               |> Ash.update(actor: outsider)
    end
  end

  describe "join workspace (G13)" do
    test "open workspace: user can join and gets learner role" do
      admin = admin_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "join-open-#{System.unique_integer([:positive])}",
          name: "Join Open",
          join_policy: :open
        })
        |> Ash.create(actor: admin)

      user = normal_user()

      assert {:ok, joined} =
               Workspace
               |> Ash.ActionInput.for_action(:join, %{workspace_id: workspace.id}, actor: user)
               |> Ash.run_action(actor: user)

      assert joined.id == workspace.id

      # Verify membership exists
      assert {:ok, memberships} =
               WorkspaceMembership
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: workspace.id, actor: admin)

      membership = Enum.find(memberships, &(&1.user_id == user.id))
      assert membership != nil

      # Verify learner role was assigned
      loaded = Ash.load!(membership, :roles, tenant: workspace.id, authorize?: false)
      assert Enum.any?(loaded.roles, &(&1.name == :learner))
    end

    test "request workspace: join action returns error" do
      admin = admin_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "join-request-#{System.unique_integer([:positive])}",
          name: "Join Request",
          join_policy: :request
        })
        |> Ash.create(actor: admin)

      user = normal_user()

      result =
        Workspace
        |> Ash.ActionInput.for_action(:join, %{workspace_id: workspace.id}, actor: user)
        |> Ash.run_action(actor: user)

      # Should return error because join_policy is :request
      assert match?({:error, _}, result) or result == {:ok, nil}
    end

    test "invite_only workspace: join action returns error" do
      admin = admin_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "join-invite-#{System.unique_integer([:positive])}",
          name: "Join Invite",
          join_policy: :invite_only
        })
        |> Ash.create(actor: admin)

      user = normal_user()

      result =
        Workspace
        |> Ash.ActionInput.for_action(:join, %{workspace_id: workspace.id}, actor: user)
        |> Ash.run_action(actor: user)

      # Should return error because join_policy is :invite_only
      assert match?({:error, _}, result) or result == {:ok, nil}
    end

    test "anonymous user cannot join open workspace" do
      admin = admin_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "join-anon-#{System.unique_integer([:positive])}",
          name: "Join Anon",
          join_policy: :open
        })
        |> Ash.create(actor: admin)

      result =
        Workspace
        |> Ash.ActionInput.for_action(:join, %{workspace_id: workspace.id})
        |> Ash.run_action()

      # Anonymous user should be forbidden
      assert match?({:error, %Ash.Error.Forbidden{}}, result)
    end

    test "ownerless (pending-owner) open workspace: join blocked until owner accepts invitation (#115)" do
      admin = admin_user()

      # owner_email 创建 → pending-owner：角色已 seed 但无 Owner membership
      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "join-ownerless-#{System.unique_integer([:positive])}",
          name: "Join Ownerless",
          join_policy: :open,
          owner_email: "pending-owner-join@example.com"
        })
        |> Ash.create(actor: admin)

      user = normal_user()

      # ownerless：join 被门控拒绝（Owner 未就位）
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Workspace
               |> Ash.ActionInput.for_action(:join, %{workspace_id: workspace.id}, actor: user)
               |> Ash.run_action(actor: user)

      assert Enum.any?(errors, fn e -> Exception.message(e) =~ "Owner 未就位" end)

      # Owner 接受邀请入座 → owner_count > 0 → 门控自动解除
      token = workspace.__metadata__[:owner_invitation_token]
      refute is_nil(token)

      require Ash.Query

      {:ok, [invitation]} =
        Cgc2046.Accounts.Invitation
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(target_email == "pending-owner-join@example.com")
        |> Ash.read(tenant: workspace.id, actor: admin)

      owner = register_user("pending-owner-join@example.com", @password)

      assert {:ok, _} =
               invitation
               |> Ash.Changeset.for_update(:accept, %{token: token})
               |> Ash.update(actor: owner)

      assert {:ok, joined} =
               Workspace
               |> Ash.ActionInput.for_action(:join, %{workspace_id: workspace.id}, actor: user)
               |> Ash.run_action(actor: user)

      assert joined.id == workspace.id
    end

    test "open workspace: already a member returns workspace without creating duplicate membership" do
      admin = admin_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "join-idemp-#{System.unique_integer([:positive])}",
          name: "Join Idemp",
          join_policy: :open
        })
        |> Ash.create(actor: admin)

      user = normal_user()

      # First join - should create membership
      assert {:ok, joined} =
               Workspace
               |> Ash.ActionInput.for_action(:join, %{workspace_id: workspace.id}, actor: user)
               |> Ash.run_action(actor: user)

      assert joined.id == workspace.id

      # Count memberships before second join
      assert {:ok, memberships_before} =
               WorkspaceMembership
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: workspace.id, actor: admin)

      count_before = length(memberships_before)

      # Second join - should be idempotent, return workspace without error
      assert {:ok, joined_again} =
               Workspace
               |> Ash.ActionInput.for_action(:join, %{workspace_id: workspace.id}, actor: user)
               |> Ash.run_action(actor: user)

      assert joined_again.id == workspace.id

      # Count memberships after second join - should be the same (no duplicate)
      assert {:ok, memberships_after} =
               WorkspaceMembership
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: workspace.id, actor: admin)

      assert length(memberships_after) == count_before
    end

    # 回归 P1：并发 join 同一用户到同一 workspace，DB unique 约束兜底，
    # 两个请求都应成功返回（幂等），DB 最终只一条 membership + learner 角色。
    test "open workspace: concurrent join by same user is idempotent, no 500" do
      admin = admin_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "join-conc-#{System.unique_integer([:positive])}",
          name: "Join Concurrent",
          join_policy: :open
        })
        |> Ash.create(actor: admin)

      user = normal_user()

      tasks =
        for _ <- 1..4 do
          Task.async(fn ->
            Workspace
            |> Ash.ActionInput.for_action(:join, %{workspace_id: workspace.id}, actor: user)
            |> Ash.run_action(actor: user)
          end)
        end

      results = Task.await_many(tasks, 5000)

      # 全部成功返回 workspace，无 MatchError/500
      assert Enum.all?(results, &match?({:ok, %Workspace{}}, &1))

      require Ash.Query

      # DB 层只落一条 membership
      {:ok, memberships} =
        WorkspaceMembership
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(user_id == ^user.id)
        |> Ash.read(tenant: workspace.id, actor: admin, authorize?: false)

      assert length(memberships) == 1

      # 且该 membership 有 learner 角色（无孤儿）
      loaded = Ash.load!(hd(memberships), :roles, tenant: workspace.id, authorize?: false)
      assert Enum.any?(loaded.roles, &(&1.name == :learner))
    end
  end

  describe "platform_admin bypass on membership read (Phase 10 P2)" do
    test "platform_admin non-member can read all workspace memberships (R13 详情页)" do
      admin = admin_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "padm-mbr-#{System.unique_integer([:positive])}",
          name: "PADM MBR"
        })
        |> Ash.create(actor: admin)

      owner =
        register_user(
          "padm-mbr-owner-#{System.unique_integer([:positive])}@example.com",
          @password
        )

      add_member(workspace, owner, admin, [:owner])

      # 另一个 platform_admin（非该 workspace 成员）读 memberships
      other_admin =
        register_user(
          "padm-mbr-admin-#{System.unique_integer([:positive])}@example.com",
          @password
        )

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE users SET is_platform_admin = true WHERE id = $1",
          [Ecto.UUID.dump!(other_admin.id)]
        )

      other_admin =
        Ash.get!(User, other_admin.id,
          actor: other_admin,
          authorize?: false,
          domain: Cgc2046.GlobalApi
        )

      require Ash.Query

      {:ok, memberships} =
        WorkspaceMembership
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(workspace_id == ^workspace.id)
        |> Ash.read(
          actor: other_admin,
          tenant: workspace.id,
          domain: Cgc2046.GlobalApi
        )

      # platform_admin 非成员应可见全部成员（含 owner 行）
      assert Enum.any?(memberships, &(&1.user_id == owner.id))
    end
  end
end
