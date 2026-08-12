defmodule Cgc2046.Accounts.InvitationTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.Invitation
  alias Cgc2046.Accounts.WorkspaceMembership
  alias Cgc2046.AccountsFixtures, as: Fixtures

  defp create_invitation(workspace, inviter, attrs \\ %{}) do
    changes =
      Map.merge(
        %{workspace_id: workspace.id, inviter_id: inviter.id},
        attrs
      )

    {:ok, invitation} =
      Invitation
      |> Ash.Changeset.for_create(:create, changes)
      |> Ash.create(actor: inviter)

    invitation
  end

  defp hash_token(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  describe "create invitation" do
    test "platform admin can create a pending-owner invitation with [:owner] preauthorized role (Phase 4)" do
      # workspace 由 admin_a 创建（其成为 Owner）；admin_b 是另一 platform_admin、
      # 非该 workspace 成员，验证 create policy 的 platform_admin bypass +
      # ValidateInviterRolePreauthorization 豁免。
      admin_a = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin_a)

      admin_b = Fixtures.platform_admin("inv-padmin-b")

      invitation =
        create_invitation(workspace, admin_b, %{
          target_email: "pending-owner@example.com",
          preauthorized_role_names: [:owner]
        })

      assert invitation.status == :active
      assert invitation.preauthorized_role_names == [:owner]
      assert invitation.target_email == "pending-owner@example.com"
      assert invitation.inviter_id == admin_b.id
    end

    test "owner can create an invitation with preauthorized roles" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)

      invitation =
        create_invitation(workspace, admin, %{
          preauthorized_role_names: [:member],
          expires_at: DateTime.add(DateTime.utc_now(), 7, :day)
        })

      assert invitation.status == :active
      assert invitation.workspace_id == workspace.id
      assert invitation.inviter_id == admin.id
      assert invitation.preauthorized_role_names == [:member]
      assert invitation.expires_at != nil
      assert invitation.token_hash != nil
      # 明文 token 仅存在于 create action 返回的 metadata，不落库
      assert invitation.__metadata__[:plain_token] != nil
    end

    test "admin can create an invitation" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      admin_member = Fixtures.register_user("inv-admin2")
      Fixtures.add_member(workspace, admin_member, [:admin])

      invitation =
        create_invitation(workspace, admin_member, %{
          preauthorized_role_names: [:member]
        })

      assert invitation.status == :active
    end

    test "volunteer can create an invitation with non-admin roles" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      volunteer = Fixtures.register_user("inv-volunteer")
      Fixtures.add_member(workspace, volunteer, [:volunteer])

      invitation =
        create_invitation(workspace, volunteer, %{
          preauthorized_role_names: [:learner]
        })

      assert invitation.status == :active
      assert invitation.preauthorized_role_names == [:learner]
    end

    test "volunteer cannot preauthorize admin or owner roles" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      volunteer = Fixtures.register_user("inv-vol-pre")
      Fixtures.add_member(workspace, volunteer, [:volunteer])

      assert {:error, %Ash.Error.Invalid{}} =
               Invitation
               |> Ash.Changeset.for_create(:create, %{
                 workspace_id: workspace.id,
                 inviter_id: volunteer.id,
                 preauthorized_role_names: [:admin]
               })
               |> Ash.create(actor: volunteer)
    end

    # 回归 #1：Volunteer 伪造 inviter_id 为某 Owner/Admin 的 ID，企图借其角色放行
    # admin 预授权。两层防御：
    #   - policy forbid_unless(inviter_id == actor.id)：inviter_id 与 actor 不符即拒
    #   - change 用真实 actor 查角色：即便 inviter_id 伪造，也按 volunteer 实际角色拦
    # 用 learner（非 admin 级）预授权测 policy 守卫——避免触发 change 的 admin 校验，
    # 纯验 forbid_unless。Volunteer 传 admin 的 inviter_id 须被拒（Forbidden）。
    test "volunteer cannot forge inviter_id (policy forbid_unless)" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      volunteer = Fixtures.register_user("inv-vol-forge")
      Fixtures.add_member(workspace, volunteer, [:volunteer])

      assert {:error, %Ash.Error.Forbidden{}} =
               Invitation
               |> Ash.Changeset.for_create(:create, %{
                 workspace_id: workspace.id,
                 inviter_id: admin.id,
                 preauthorized_role_names: [:learner]
               })
               |> Ash.create(actor: volunteer)
    end

    # 回归 #1 纵深防御：即便绕过 policy，change 用真实 actor（volunteer）查角色，
    # 传 admin 预授权仍被 change 的 admin 级角色校验拦截（InvalidAttribute error）。
    test "volunteer cannot forge inviter_id to escalate preauthorized roles (change guard)" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      volunteer = Fixtures.register_user("inv-vol-forge2")
      Fixtures.add_member(workspace, volunteer, [:volunteer])

      assert {:error, %Ash.Error.Invalid{}} =
               Invitation
               |> Ash.Changeset.for_create(:create, %{
                 workspace_id: workspace.id,
                 inviter_id: admin.id,
                 preauthorized_role_names: [:admin]
               })
               |> Ash.create(actor: volunteer)
    end

    test "plain member cannot create invitation" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("inv-plain")
      Fixtures.add_member(workspace, member)

      assert {:error, %Ash.Error.Forbidden{}} =
               Invitation
               |> Ash.Changeset.for_create(:create, %{
                 workspace_id: workspace.id,
                 inviter_id: member.id
               })
               |> Ash.create(actor: member)
    end

    test "outsider cannot create invitation" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      outsider = Fixtures.register_user("inv-outsider")

      assert {:error, %Ash.Error.Forbidden{}} =
               Invitation
               |> Ash.Changeset.for_create(:create, %{
                 workspace_id: workspace.id,
                 inviter_id: outsider.id
               })
               |> Ash.create(actor: outsider)
    end

    test "token is hashed before storage" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)

      invitation = create_invitation(workspace, admin)
      plain_token = invitation.__metadata__[:plain_token]

      # plain_token should not equal token_hash
      assert plain_token != invitation.token_hash
      # token_hash should be the SHA256 hash of plain_token
      assert invitation.token_hash == hash_token(plain_token)
    end
  end

  describe "validate invitation" do
    test "valid token returns invitation with workspace preview" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      invitation = create_invitation(workspace, admin)

      assert {:ok, validated} =
               Invitation
               |> Ash.Query.for_read(:validate, %{token: invitation.__metadata__[:plain_token]})
               |> Ash.read_one(actor: admin)

      assert validated != nil
      assert validated.id == invitation.id
      assert validated.status == :active
    end

    test "invalid token returns nil" do
      admin = Fixtures.platform_admin("inv-admin")

      assert {:ok, nil} =
               Invitation
               |> Ash.Query.for_read(:validate, %{token: "invalid-token"})
               |> Ash.read_one(actor: admin)
    end

    test "invite_only workspace is previewable via validate by non-member" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin, %{join_policy: :invite_only})
      invitation = create_invitation(workspace, admin)

      # Non-member (not admin, not a workspace member) should be able to validate
      # the invitation and see workspace preview fields (decision 8)
      outsider = Fixtures.register_user("inv-validate-nm")

      assert {:ok, validated} =
               Invitation
               |> Ash.Query.for_read(:validate, %{token: invitation.__metadata__[:plain_token]})
               |> Ash.read_one(actor: outsider)

      assert validated != nil
      assert validated.id == invitation.id
      assert validated.status == :active
      # Workspace preview fields should be accessible to non-member
      assert validated.workspace_name == workspace.name
      assert validated.workspace_slug == workspace.slug
      assert validated.workspace_join_policy == "invite_only"
    end

    test "invite_only workspace is previewable via validate by admin" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin, %{join_policy: :invite_only})
      invitation = create_invitation(workspace, admin)

      assert {:ok, validated} =
               Invitation
               |> Ash.Query.for_read(:validate, %{token: invitation.__metadata__[:plain_token]})
               |> Ash.read_one(actor: admin)

      assert validated != nil
      assert validated.id == invitation.id
      assert validated.status == :active
      assert validated.workspace_name == workspace.name
      assert validated.workspace_slug == workspace.slug
    end

    test "expired invitation returns expired status" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)

      invitation =
        create_invitation(workspace, admin, %{
          expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
        })

      assert {:ok, validated} =
               Invitation
               |> Ash.Query.for_read(:validate, %{token: invitation.__metadata__[:plain_token]})
               |> Ash.read_one(actor: admin)

      assert validated != nil
      assert validated.status == :active
      assert validated.effective_status == "expired"
    end

    test "used invitation returns used status" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      invitation = create_invitation(workspace, admin)

      # Accept the invitation first
      acceptor = Fixtures.register_user("inv-used-acceptor")

      assert {:ok, _accepted} =
               invitation
               |> Ash.Changeset.for_update(:accept, %{
                 token: invitation.__metadata__[:plain_token]
               })
               |> Ash.update(actor: acceptor)

      # Now validate should return used
      assert {:ok, validated} =
               Invitation
               |> Ash.Query.for_read(:validate, %{token: invitation.__metadata__[:plain_token]})
               |> Ash.read_one(actor: admin)

      assert validated != nil
      assert validated.status == :used
    end

    test "revoked invitation returns revoked status" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      invitation = create_invitation(workspace, admin)

      assert {:ok, revoked} =
               invitation
               |> Ash.Changeset.for_update(:revoke, %{})
               |> Ash.update(actor: admin)

      assert revoked.status == :revoked

      assert {:ok, validated} =
               Invitation
               |> Ash.Query.for_read(:validate, %{token: invitation.__metadata__[:plain_token]})
               |> Ash.read_one(actor: admin)

      assert validated != nil
      assert validated.status == :revoked
    end
  end

  describe "accept invitation" do
    test "accept creates membership with preauthorized roles" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)

      invitation =
        create_invitation(workspace, admin, %{
          preauthorized_role_names: [:member]
        })

      acceptor = Fixtures.register_user("inv-accept")

      assert {:ok, accepted} =
               invitation
               |> Ash.Changeset.for_update(:accept, %{
                 token: invitation.__metadata__[:plain_token]
               })
               |> Ash.update(actor: acceptor)

      assert accepted.status == :used
      assert accepted.accepted_by == acceptor.id
      assert accepted.accepted_at != nil

      # Verify membership exists
      assert {:ok, memberships} =
               WorkspaceMembership
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: workspace.id, actor: admin)

      membership = Enum.find(memberships, &(&1.user_id == acceptor.id))
      assert membership != nil

      # Verify role was assigned
      loaded = Ash.load!(membership, :roles, tenant: workspace.id, authorize?: false)
      assert Enum.any?(loaded.roles, &(&1.name == :member))
    end

    test "accept without preauthorized roles creates membership without roles" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      invitation = create_invitation(workspace, admin)

      acceptor = Fixtures.register_user("inv-accept-norole")

      assert {:ok, accepted} =
               invitation
               |> Ash.Changeset.for_update(:accept, %{
                 token: invitation.__metadata__[:plain_token]
               })
               |> Ash.update(actor: acceptor)

      assert accepted.status == :used
      assert accepted.accepted_by == acceptor.id

      # Verify membership exists
      assert {:ok, memberships} =
               WorkspaceMembership
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: workspace.id, actor: admin)

      membership = Enum.find(memberships, &(&1.user_id == acceptor.id))
      assert membership != nil

      # Verify no roles assigned
      loaded = Ash.load!(membership, :roles, tenant: workspace.id, authorize?: false)
      assert loaded.roles == []
    end

    test "accept with multiple preauthorized roles" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)

      invitation =
        create_invitation(workspace, admin, %{
          preauthorized_role_names: [:admin, :member]
        })

      acceptor = Fixtures.register_user("inv-accept-multi")

      assert {:ok, accepted} =
               invitation
               |> Ash.Changeset.for_update(:accept, %{
                 token: invitation.__metadata__[:plain_token]
               })
               |> Ash.update(actor: acceptor)

      assert accepted.status == :used

      # Verify roles
      assert {:ok, memberships} =
               WorkspaceMembership
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: workspace.id, actor: admin)

      membership = Enum.find(memberships, &(&1.user_id == acceptor.id))
      loaded = Ash.load!(membership, :roles, tenant: workspace.id, authorize?: false)
      role_names = Enum.map(loaded.roles, & &1.name) |> Enum.sort()
      assert role_names == [:admin, :member]
    end

    test "cannot accept expired invitation" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)

      invitation =
        create_invitation(workspace, admin, %{
          expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
        })

      acceptor = Fixtures.register_user("inv-accept-expired")

      assert {:error, %Ash.Error.Invalid{}} =
               invitation
               |> Ash.Changeset.for_update(:accept, %{
                 token: invitation.__metadata__[:plain_token]
               })
               |> Ash.update(actor: acceptor)
    end

    test "cannot accept revoked invitation" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      invitation = create_invitation(workspace, admin)

      assert {:ok, revoked} =
               invitation
               |> Ash.Changeset.for_update(:revoke, %{})
               |> Ash.update(actor: admin)

      assert revoked.status == :revoked

      acceptor = Fixtures.register_user("inv-accept-revoked")

      assert {:error, %Ash.Error.Invalid{}} =
               invitation
               |> Ash.Changeset.for_update(:accept, %{
                 token: invitation.__metadata__[:plain_token]
               })
               |> Ash.update(actor: acceptor)
    end

    test "cannot accept already used invitation" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      invitation = create_invitation(workspace, admin)

      acceptor = Fixtures.register_user("inv-accept-used")

      assert {:ok, _accepted} =
               invitation
               |> Ash.Changeset.for_update(:accept, %{
                 token: invitation.__metadata__[:plain_token]
               })
               |> Ash.update(actor: acceptor)

      another_acceptor = Fixtures.register_user("inv-accept-used2")

      assert {:error, %Ash.Error.Invalid{}} =
               invitation
               |> Ash.Changeset.for_update(:accept, %{
                 token: invitation.__metadata__[:plain_token]
               })
               |> Ash.update(actor: another_acceptor)
    end

    test "accept with wrong token fails" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      invitation = create_invitation(workspace, admin)

      acceptor = Fixtures.register_user("inv-accept-wrong-token")

      assert {:error, %Ash.Error.Invalid{}} =
               invitation
               |> Ash.Changeset.for_update(:accept, %{token: "wrong-token"})
               |> Ash.update(actor: acceptor)
    end

    test "cannot accept when already a member of this workspace" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      invitation = create_invitation(workspace, admin, %{preauthorized_role_names: [:member]})

      acceptor = Fixtures.register_user("inv-accept-already-member")
      # 受邀人已是该工作台成员
      Fixtures.add_member(workspace, acceptor)

      assert {:error, %Ash.Error.Invalid{}} =
               invitation
               |> Ash.Changeset.for_update(:accept, %{
                 token: invitation.__metadata__[:plain_token]
               })
               |> Ash.update(actor: acceptor)

      # invitation 仍为 active（after_action 抛错回滚，未进 used 终态）
      assert {:ok, reloaded} = Ash.get(Invitation, invitation.id, actor: admin)
      assert reloaded.status == :active
    end

    # 回归：同一用户并发 accept 同一邀请，DB unique constraint 拒绝第二个时，
    # after_action 不得抛 MatchError/500，须转成业务错误。
    # 两个并发请求都越过 existing 检查 → 一个建 membership 成功，一个撞 unique index。
    test "concurrent accept by same user returns business error, not 500" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      invitation = create_invitation(workspace, admin, %{preauthorized_role_names: [:member]})

      acceptor = Fixtures.register_user("inv-accept-concurrent")
      token = invitation.__metadata__[:plain_token]

      results =
        [1, 2]
        |> Task.async_stream(
          fn _ ->
            invitation
            |> Ash.Changeset.for_update(:accept, %{token: token})
            |> Ash.update(actor: acceptor)
          end,
          max_concurrency: 2,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      oks = Enum.filter(results, &match?({:ok, _}, &1))
      errors = Enum.filter(results, &match?({:error, %Ash.Error.Invalid{}}, &1))

      # 一个成功，一个返回业务错误；没有任何 MatchError/异常外泄
      assert length(oks) == 1
      assert length(errors) == 1
    end
  end

  describe "revoke invitation" do
    test "inviter can revoke their own invitation" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      invitation = create_invitation(workspace, admin)

      assert {:ok, revoked} =
               invitation
               |> Ash.Changeset.for_update(:revoke, %{})
               |> Ash.update(actor: admin)

      assert revoked.status == :revoked
    end

    test "owner can revoke any invitation" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      volunteer = Fixtures.register_user("inv-revoke-vol")
      Fixtures.add_member(workspace, volunteer, [:volunteer])

      invitation =
        create_invitation(workspace, volunteer, %{
          preauthorized_role_names: [:learner]
        })

      # Owner revokes volunteer's invitation
      assert {:ok, revoked} =
               invitation
               |> Ash.Changeset.for_update(:revoke, %{})
               |> Ash.update(actor: admin)

      assert revoked.status == :revoked
    end

    test "admin can revoke any invitation" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      admin_member = Fixtures.register_user("inv-revoke-admin")
      Fixtures.add_member(workspace, admin_member, [:admin])

      volunteer = Fixtures.register_user("inv-revoke-vol2")
      Fixtures.add_member(workspace, volunteer, [:volunteer])

      invitation =
        create_invitation(workspace, volunteer, %{
          preauthorized_role_names: [:learner]
        })

      # Admin revokes volunteer's invitation
      assert {:ok, revoked} =
               invitation
               |> Ash.Changeset.for_update(:revoke, %{})
               |> Ash.update(actor: admin_member)

      assert revoked.status == :revoked
    end

    test "plain member cannot revoke invitation" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      invitation = create_invitation(workspace, admin)

      member = Fixtures.register_user("inv-revoke-plain")
      Fixtures.add_member(workspace, member)

      assert {:error, %Ash.Error.Forbidden{}} =
               invitation
               |> Ash.Changeset.for_update(:revoke, %{})
               |> Ash.update(actor: member)
    end

    test "outsider cannot revoke invitation" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      invitation = create_invitation(workspace, admin)

      outsider = Fixtures.register_user("inv-revoke-out")

      assert {:error, %Ash.Error.Forbidden{}} =
               invitation
               |> Ash.Changeset.for_update(:revoke, %{})
               |> Ash.update(actor: outsider)
    end

    test "cannot revoke an already used invitation" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      invitation = create_invitation(workspace, admin, %{preauthorized_role_names: [:member]})

      acceptor = Fixtures.register_user("inv-revoke-used")

      assert {:ok, _accepted} =
               invitation
               |> Ash.Changeset.for_update(:accept, %{
                 token: invitation.__metadata__[:plain_token]
               })
               |> Ash.update(actor: acceptor)

      # revoke 已 used 的邀请是非法状态转换：membership 已建立，revoke 是假动作且会
      # 把 status 从 used 改成 revoked，篡改 accept 的状态判断语义
      assert {:error, %Ash.Error.Invalid{}} =
               invitation
               |> Ash.Changeset.for_update(:revoke, %{})
               |> Ash.update(actor: admin)

      # status 仍为 used，未被改写成 revoked
      assert {:ok, reloaded} = Ash.get(Invitation, invitation.id, actor: admin)
      assert reloaded.status == :used
    end

    test "cannot revoke an already revoked invitation" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      invitation = create_invitation(workspace, admin)

      assert {:ok, _revoked} =
               invitation
               |> Ash.Changeset.for_update(:revoke, %{})
               |> Ash.update(actor: admin)

      assert {:error, %Ash.Error.Invalid{}} =
               invitation
               |> Ash.Changeset.for_update(:revoke, %{})
               |> Ash.update(actor: admin)
    end
  end

  describe "expired invitation" do
    test "invitation with past expires_at is returned as expired on validate" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)

      invitation =
        create_invitation(workspace, admin, %{
          expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
        })

      assert {:ok, validated} =
               Invitation
               |> Ash.Query.for_read(:validate, %{token: invitation.__metadata__[:plain_token]})
               |> Ash.read_one(actor: admin)

      assert validated.status == :active
      assert validated.effective_status == "expired"
    end

    test "invitation with future expires_at stays active" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)

      invitation =
        create_invitation(workspace, admin, %{
          expires_at: DateTime.add(DateTime.utc_now(), 7, :day)
        })

      assert {:ok, validated} =
               Invitation
               |> Ash.Query.for_read(:validate, %{token: invitation.__metadata__[:plain_token]})
               |> Ash.read_one(actor: admin)

      assert validated.status == :active
    end

    test "invitation without expires_at never expires" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      invitation = create_invitation(workspace, admin)

      assert {:ok, validated} =
               Invitation
               |> Ash.Query.for_read(:validate, %{token: invitation.__metadata__[:plain_token]})
               |> Ash.read_one(actor: admin)

      assert validated.status == :active
    end

    test "revoked invitation with past expires_at stays revoked (effective_status 不覆盖显式终结状态)" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)

      invitation =
        create_invitation(workspace, admin, %{
          expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
        })

      assert {:ok, revoked} =
               invitation
               |> Ash.Changeset.for_update(:revoke, %{}, actor: admin, tenant: workspace.id)
               |> Ash.update()

      assert revoked.status == :revoked

      assert {:ok, validated} =
               Invitation
               |> Ash.Query.for_read(:validate, %{token: invitation.__metadata__[:plain_token]})
               |> Ash.read_one(actor: admin)

      assert validated.status == :revoked
      assert validated.effective_status == "revoked"
    end
  end

  describe "tenant isolation" do
    test "invitations are scoped to their workspace tenant" do
      admin = Fixtures.platform_admin("inv-admin")

      ws_a =
        Fixtures.create_workspace(admin, %{
          slug: "inv-iso-a-#{System.unique_integer([:positive])}"
        })

      ws_b =
        Fixtures.create_workspace(admin, %{
          slug: "inv-iso-b-#{System.unique_integer([:positive])}"
        })

      inv_a = create_invitation(ws_a, admin)

      # ws_b should not see ws_a's invitations
      assert {:ok, ws_b_invitations} =
               Invitation
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: ws_b.id, actor: admin)

      refute Enum.any?(ws_b_invitations, &(&1.id == inv_a.id))
    end
  end

  describe ":expire action (#114)" do
    test "active invitation -> expired" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      invitation = create_invitation(workspace, admin)

      assert {:ok, expired} =
               invitation
               |> Ash.Changeset.for_update(:expire, %{})
               |> Ash.update(tenant: workspace.id, authorize?: false)

      assert expired.status == :expired
    end

    test "revoked invitation -> expire rejected (terminal state guard)" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)
      invitation = create_invitation(workspace, admin)

      assert {:ok, revoked} =
               invitation
               |> Ash.Changeset.for_update(:revoke, %{})
               |> Ash.update(actor: admin)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               revoked
               |> Ash.Changeset.for_update(:expire, %{})
               |> Ash.update(tenant: workspace.id, authorize?: false)

      assert Enum.any?(errors, fn e -> Exception.message(e) =~ "Cannot expire" end)
    end
  end

  describe "platform_admin bypass on read/revoke (#114)" do
    test "non-inviter platform admin can read and revoke pending-owner invitation" do
      admin = Fixtures.platform_admin("inv-admin")
      workspace = Fixtures.create_workspace(admin)

      invitation =
        create_invitation(workspace, admin, %{
          target_email: "pending-owner@example.com",
          preauthorized_role_names: [:owner]
        })

      # 第二个 platform admin（非 inviter、非成员），经 Fixtures 域 action 提权
      other_admin = Fixtures.platform_admin("inv-other-admin")

      # read bypass：非 inviter 的 platform admin 也能读到（admin 详情页 badge 前提）
      assert {:ok, read_back} = Ash.get(Invitation, invitation.id, actor: other_admin)
      assert read_back.id == invitation.id

      # revoke bypass：任意 platform admin 可取消 pending-owner 邀请
      assert {:ok, revoked} =
               read_back
               |> Ash.Changeset.for_update(:revoke, %{})
               |> Ash.update(actor: other_admin)

      assert revoked.status == :revoked
    end
  end
end
