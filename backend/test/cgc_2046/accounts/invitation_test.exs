defmodule Cgc2046.Accounts.InvitationTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.Invitation
  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Accounts.WorkspaceMembership
  alias AshAuthentication.Info, as: AuthInfo

  @admin_email "inv-admin@example.com"
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

  defp normal_user(email \\ "inv-user-#{System.unique_integer([:positive])}@example.com") do
    register_user(email, @password)
  end

  defp create_workspace(admin, opts \\ []) do
    slug = opts[:slug] || "inv-ws-#{System.unique_integer([:positive])}"
    join_policy = opts[:join_policy] || :request

    assert {:ok, workspace} =
             Workspace
             |> Ash.Changeset.for_create(:create, %{
               slug: slug,
               name: "Inv WS",
               join_policy: join_policy
             })
             |> Ash.create(actor: admin)

    workspace
  end

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
    test "owner can create an invitation with preauthorized roles" do
      admin = admin_user()
      workspace = create_workspace(admin)

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
      admin = admin_user()
      workspace = create_workspace(admin)
      admin_member = normal_user("inv-admin2@example.com")
      add_member(workspace, admin_member, admin, [:admin])

      invitation =
        create_invitation(workspace, admin_member, %{
          preauthorized_role_names: [:member]
        })

      assert invitation.status == :active
    end

    test "volunteer can create an invitation with non-admin roles" do
      admin = admin_user()
      workspace = create_workspace(admin)
      volunteer = normal_user("inv-volunteer@example.com")
      add_member(workspace, volunteer, admin, [:volunteer])

      invitation =
        create_invitation(workspace, volunteer, %{
          preauthorized_role_names: [:learner]
        })

      assert invitation.status == :active
      assert invitation.preauthorized_role_names == [:learner]
    end

    test "volunteer cannot preauthorize admin or owner roles" do
      admin = admin_user()
      workspace = create_workspace(admin)
      volunteer = normal_user("inv-vol-pre@example.com")
      add_member(workspace, volunteer, admin, [:volunteer])

      assert {:error, %Ash.Error.Invalid{}} =
               Invitation
               |> Ash.Changeset.for_create(:create, %{
                 workspace_id: workspace.id,
                 inviter_id: volunteer.id,
                 preauthorized_role_names: [:admin]
               })
               |> Ash.create(actor: volunteer)
    end

    test "plain member cannot create invitation" do
      admin = admin_user()
      workspace = create_workspace(admin)
      member = normal_user("inv-plain@example.com")
      add_member(workspace, member, admin, [:member])

      assert {:error, %Ash.Error.Forbidden{}} =
               Invitation
               |> Ash.Changeset.for_create(:create, %{
                 workspace_id: workspace.id,
                 inviter_id: member.id
               })
               |> Ash.create(actor: member)
    end

    test "outsider cannot create invitation" do
      admin = admin_user()
      workspace = create_workspace(admin)
      outsider = normal_user("inv-outsider@example.com")

      assert {:error, %Ash.Error.Forbidden{}} =
               Invitation
               |> Ash.Changeset.for_create(:create, %{
                 workspace_id: workspace.id,
                 inviter_id: outsider.id
               })
               |> Ash.create(actor: outsider)
    end

    test "token is hashed before storage" do
      admin = admin_user()
      workspace = create_workspace(admin)

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
      admin = admin_user()
      workspace = create_workspace(admin)
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
      admin = admin_user()

      assert {:ok, nil} =
               Invitation
               |> Ash.Query.for_read(:validate, %{token: "invalid-token"})
               |> Ash.read_one(actor: admin)
    end

    test "invite_only workspace is previewable via validate by non-member" do
      admin = admin_user()
      workspace = create_workspace(admin, join_policy: :invite_only)
      invitation = create_invitation(workspace, admin)

      # Non-member (not admin, not a workspace member) should be able to validate
      # the invitation and see workspace preview fields (decision 8)
      outsider = normal_user("inv-validate-nm@example.com")

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
      admin = admin_user()
      workspace = create_workspace(admin, join_policy: :invite_only)
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
      admin = admin_user()
      workspace = create_workspace(admin)

      invitation =
        create_invitation(workspace, admin, %{
          expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
        })

      assert {:ok, validated} =
               Invitation
               |> Ash.Query.for_read(:validate, %{token: invitation.__metadata__[:plain_token]})
               |> Ash.read_one(actor: admin)

      assert validated != nil
      assert validated.status == :expired
    end

    test "used invitation returns used status" do
      admin = admin_user()
      workspace = create_workspace(admin)
      invitation = create_invitation(workspace, admin)

      # Accept the invitation first
      acceptor = normal_user("inv-used-acceptor@example.com")

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
      admin = admin_user()
      workspace = create_workspace(admin)
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
      admin = admin_user()
      workspace = create_workspace(admin)

      invitation =
        create_invitation(workspace, admin, %{
          preauthorized_role_names: [:member]
        })

      acceptor = normal_user("inv-accept@example.com")

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
      admin = admin_user()
      workspace = create_workspace(admin)
      invitation = create_invitation(workspace, admin)

      acceptor = normal_user("inv-accept-norole@example.com")

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
      admin = admin_user()
      workspace = create_workspace(admin)

      invitation =
        create_invitation(workspace, admin, %{
          preauthorized_role_names: [:admin, :member]
        })

      acceptor = normal_user("inv-accept-multi@example.com")

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
      admin = admin_user()
      workspace = create_workspace(admin)

      invitation =
        create_invitation(workspace, admin, %{
          expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
        })

      acceptor = normal_user("inv-accept-expired@example.com")

      assert {:error, %Ash.Error.Invalid{}} =
               invitation
               |> Ash.Changeset.for_update(:accept, %{
                 token: invitation.__metadata__[:plain_token]
               })
               |> Ash.update(actor: acceptor)
    end

    test "cannot accept revoked invitation" do
      admin = admin_user()
      workspace = create_workspace(admin)
      invitation = create_invitation(workspace, admin)

      assert {:ok, revoked} =
               invitation
               |> Ash.Changeset.for_update(:revoke, %{})
               |> Ash.update(actor: admin)

      assert revoked.status == :revoked

      acceptor = normal_user("inv-accept-revoked@example.com")

      assert {:error, %Ash.Error.Invalid{}} =
               invitation
               |> Ash.Changeset.for_update(:accept, %{
                 token: invitation.__metadata__[:plain_token]
               })
               |> Ash.update(actor: acceptor)
    end

    test "cannot accept already used invitation" do
      admin = admin_user()
      workspace = create_workspace(admin)
      invitation = create_invitation(workspace, admin)

      acceptor = normal_user("inv-accept-used@example.com")

      assert {:ok, _accepted} =
               invitation
               |> Ash.Changeset.for_update(:accept, %{
                 token: invitation.__metadata__[:plain_token]
               })
               |> Ash.update(actor: acceptor)

      another_acceptor = normal_user("inv-accept-used2@example.com")

      assert {:error, %Ash.Error.Invalid{}} =
               invitation
               |> Ash.Changeset.for_update(:accept, %{
                 token: invitation.__metadata__[:plain_token]
               })
               |> Ash.update(actor: another_acceptor)
    end

    test "accept with wrong token fails" do
      admin = admin_user()
      workspace = create_workspace(admin)
      invitation = create_invitation(workspace, admin)

      acceptor = normal_user("inv-accept-wrong-token@example.com")

      assert {:error, %Ash.Error.Invalid{}} =
               invitation
               |> Ash.Changeset.for_update(:accept, %{token: "wrong-token"})
               |> Ash.update(actor: acceptor)
    end
  end

  describe "revoke invitation" do
    test "inviter can revoke their own invitation" do
      admin = admin_user()
      workspace = create_workspace(admin)
      invitation = create_invitation(workspace, admin)

      assert {:ok, revoked} =
               invitation
               |> Ash.Changeset.for_update(:revoke, %{})
               |> Ash.update(actor: admin)

      assert revoked.status == :revoked
    end

    test "owner can revoke any invitation" do
      admin = admin_user()
      workspace = create_workspace(admin)
      volunteer = normal_user("inv-revoke-vol@example.com")
      add_member(workspace, volunteer, admin, [:volunteer])

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
      admin = admin_user()
      workspace = create_workspace(admin)
      admin_member = normal_user("inv-revoke-admin@example.com")
      add_member(workspace, admin_member, admin, [:admin])

      volunteer = normal_user("inv-revoke-vol2@example.com")
      add_member(workspace, volunteer, admin, [:volunteer])

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
      admin = admin_user()
      workspace = create_workspace(admin)
      invitation = create_invitation(workspace, admin)

      member = normal_user("inv-revoke-plain@example.com")
      add_member(workspace, member, admin, [:member])

      assert {:error, %Ash.Error.Forbidden{}} =
               invitation
               |> Ash.Changeset.for_update(:revoke, %{})
               |> Ash.update(actor: member)
    end

    test "outsider cannot revoke invitation" do
      admin = admin_user()
      workspace = create_workspace(admin)
      invitation = create_invitation(workspace, admin)

      outsider = normal_user("inv-revoke-out@example.com")

      assert {:error, %Ash.Error.Forbidden{}} =
               invitation
               |> Ash.Changeset.for_update(:revoke, %{})
               |> Ash.update(actor: outsider)
    end
  end

  describe "expired invitation" do
    test "invitation with past expires_at is returned as expired on validate" do
      admin = admin_user()
      workspace = create_workspace(admin)

      invitation =
        create_invitation(workspace, admin, %{
          expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
        })

      assert {:ok, validated} =
               Invitation
               |> Ash.Query.for_read(:validate, %{token: invitation.__metadata__[:plain_token]})
               |> Ash.read_one(actor: admin)

      assert validated.status == :expired
    end

    test "invitation with future expires_at stays active" do
      admin = admin_user()
      workspace = create_workspace(admin)

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
      admin = admin_user()
      workspace = create_workspace(admin)
      invitation = create_invitation(workspace, admin)

      assert {:ok, validated} =
               Invitation
               |> Ash.Query.for_read(:validate, %{token: invitation.__metadata__[:plain_token]})
               |> Ash.read_one(actor: admin)

      assert validated.status == :active
    end
  end

  describe "tenant isolation" do
    test "invitations are scoped to their workspace tenant" do
      admin = admin_user()
      ws_a = create_workspace(admin, slug: "inv-iso-a-#{System.unique_integer([:positive])}")
      ws_b = create_workspace(admin, slug: "inv-iso-b-#{System.unique_integer([:positive])}")

      inv_a = create_invitation(ws_a, admin)

      # ws_b should not see ws_a's invitations
      assert {:ok, ws_b_invitations} =
               Invitation
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: ws_b.id, actor: admin)

      refute Enum.any?(ws_b_invitations, &(&1.id == inv_a.id))
    end
  end
end
