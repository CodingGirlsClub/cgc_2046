defmodule Cgc2046.Accounts.JoinRequestTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.JoinRequest
  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Accounts.WorkspaceMembership
  alias AshAuthentication.Info, as: AuthInfo

  @admin_email "jr-admin@example.com"
  @applicant_email "jr-applicant@example.com"
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

  defp normal_user(email \\ @applicant_email) do
    register_user(email, @password)
  end

  defp create_workspace(admin, opts \\ []) do
    slug = opts[:slug] || "jr-ws-#{System.unique_integer([:positive])}"
    join_policy = opts[:join_policy] || :request

    assert {:ok, workspace} =
             Workspace
             |> Ash.Changeset.for_create(:create, %{
               slug: slug,
               name: "JR WS",
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

  defp create_join_request(workspace, user, attrs \\ %{}) do
    changes =
      Map.merge(
        %{workspace_id: workspace.id, user_id: user.id},
        attrs
      )

    {:ok, join_request} =
      JoinRequest
      |> Ash.Changeset.for_create(:create, changes)
      |> Ash.create(actor: user)

    join_request
  end

  describe "create join request" do
    test "applicant can create a pending join request when join_policy is :request" do
      admin = admin_user()
      workspace = create_workspace(admin)
      applicant = normal_user()

      join_request = create_join_request(workspace, applicant)

      assert join_request.status == :pending
      assert join_request.user_id == applicant.id
      assert join_request.workspace_id == workspace.id
      assert join_request.approval_deadline != nil
    end

    test "approval_deadline is set to 7 days from now" do
      admin = admin_user()
      workspace = create_workspace(admin)
      applicant = normal_user()

      join_request = create_join_request(workspace, applicant)

      assert DateTime.compare(join_request.approval_deadline, DateTime.utc_now()) == :gt

      # Should be roughly 7 days ahead (allow 1s tolerance)
      diff_seconds = DateTime.diff(join_request.approval_deadline, DateTime.utc_now())
      assert diff_seconds > 6 * 24 * 3600
      assert diff_seconds < 8 * 24 * 3600
    end

    test "duplicate pending join request is rejected" do
      admin = admin_user()
      workspace = create_workspace(admin)
      applicant = normal_user()

      create_join_request(workspace, applicant)

      assert {:error, %Ash.Error.Invalid{}} =
               JoinRequest
               |> Ash.Changeset.for_create(:create, %{
                 workspace_id: workspace.id,
                 user_id: applicant.id
               })
               |> Ash.create(actor: applicant)
    end

    test "rejected applicant can reapply" do
      admin = admin_user()
      workspace = create_workspace(admin)
      applicant = normal_user()

      jr = create_join_request(workspace, applicant)

      # Reject
      assert {:ok, rejected} =
               jr
               |> Ash.Changeset.for_update(:reject, %{rejection_reason: "not needed"})
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert rejected.status == :rejected

      # Reapply
      jr2 = create_join_request(workspace, applicant)
      assert jr2.status == :pending
      assert jr2.id != jr.id
    end

    test "cannot create join request when join_policy is :open" do
      admin = admin_user()
      workspace = create_workspace(admin, join_policy: :open)
      applicant = normal_user("open-applicant@example.com")

      assert {:error, %Ash.Error.Forbidden{}} =
               JoinRequest
               |> Ash.Changeset.for_create(:create, %{
                 workspace_id: workspace.id,
                 user_id: applicant.id
               })
               |> Ash.create(actor: applicant)
    end

    test "cannot create join request when join_policy is :invite_only" do
      admin = admin_user()
      workspace = create_workspace(admin, join_policy: :invite_only)
      applicant = normal_user("invite-applicant@example.com")

      assert {:error, %Ash.Error.Forbidden{}} =
               JoinRequest
               |> Ash.Changeset.for_create(:create, %{
                 workspace_id: workspace.id,
                 user_id: applicant.id
               })
               |> Ash.create(actor: applicant)
    end

    test "outsider cannot create join request on behalf of another user" do
      admin = admin_user()
      workspace = create_workspace(admin)
      applicant = normal_user()
      outsider = register_user("outsider-jr@example.com", @password)

      assert {:error, %Ash.Error.Forbidden{}} =
               JoinRequest
               |> Ash.Changeset.for_create(:create, %{
                 workspace_id: workspace.id,
                 user_id: applicant.id
               })
               |> Ash.create(actor: outsider)
    end
  end

  describe "approve join request" do
    test "owner can approve and creates membership with roles" do
      admin = admin_user()
      workspace = create_workspace(admin)
      applicant = normal_user()
      jr = create_join_request(workspace, applicant)

      assert {:ok, approved} =
               jr
               |> Ash.Changeset.for_update(:approve, %{role_names: [:member]})
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert approved.status == :approved
      assert approved.approved_by == admin.id
      assert approved.approved_at != nil

      # 重新从 DB 加载，验证 approved_by 已落库
      db_record =
        Ash.get!(JoinRequest, approved.id, tenant: workspace.id, actor: admin, authorize?: false)

      assert db_record.approved_by == admin.id
      assert db_record.status == :approved

      # Membership should exist
      assert {:ok, memberships} =
               WorkspaceMembership
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: workspace.id, actor: admin)

      membership = Enum.find(memberships, &(&1.user_id == applicant.id))
      assert membership != nil

      # MembershipRole should exist
      loaded = Ash.load!(membership, :roles, tenant: workspace.id, authorize?: false)
      assert Enum.any?(loaded.roles, &(&1.name == :member))
    end

    test "admin can approve join request" do
      admin = admin_user()
      workspace = create_workspace(admin)
      admin_member = register_user("jr-admin2@example.com", @password)
      add_member(workspace, admin_member, admin, [:admin])

      applicant = normal_user()
      jr = create_join_request(workspace, applicant)

      assert {:ok, approved} =
               jr
               |> Ash.Changeset.for_update(:approve, %{role_names: [:member]})
               |> Ash.update(tenant: workspace.id, actor: admin_member)

      assert approved.status == :approved
    end

    test "approve with multiple roles" do
      admin = admin_user()
      workspace = create_workspace(admin)
      applicant = normal_user()
      jr = create_join_request(workspace, applicant)

      assert {:ok, approved} =
               jr
               |> Ash.Changeset.for_update(:approve, %{role_names: [:admin, :member]})
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert approved.status == :approved

      # Verify roles
      assert {:ok, memberships} =
               WorkspaceMembership
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: workspace.id, actor: admin)

      membership = Enum.find(memberships, &(&1.user_id == applicant.id))
      loaded = Ash.load!(membership, :roles, tenant: workspace.id, authorize?: false)
      role_names = Enum.map(loaded.roles, & &1.name) |> Enum.sort()
      assert role_names == [:admin, :member]
    end

    test "plain member cannot approve join request" do
      admin = admin_user()
      workspace = create_workspace(admin)
      member = register_user("jr-plain@example.com", @password)
      add_member(workspace, member, admin, [:member])

      applicant = normal_user()
      jr = create_join_request(workspace, applicant)

      assert {:error, %Ash.Error.Forbidden{}} =
               jr
               |> Ash.Changeset.for_update(:approve, %{role_names: [:member]})
               |> Ash.update(tenant: workspace.id, actor: member)
    end

    test "outsider cannot approve join request" do
      admin = admin_user()
      workspace = create_workspace(admin)
      applicant = normal_user()
      jr = create_join_request(workspace, applicant)

      outsider = register_user("outsider-approve@example.com", @password)

      assert {:error, %Ash.Error.Forbidden{}} =
               jr
               |> Ash.Changeset.for_update(:approve, %{role_names: [:member]})
               |> Ash.update(tenant: workspace.id, actor: outsider)
    end
  end

  describe "reject join request" do
    test "owner can reject with reason" do
      admin = admin_user()
      workspace = create_workspace(admin)
      applicant = normal_user()
      jr = create_join_request(workspace, applicant)

      assert {:ok, rejected} =
               jr
               |> Ash.Changeset.for_update(:reject, %{rejection_reason: "not a fit"})
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert rejected.status == :rejected
      assert rejected.rejection_reason == "not a fit"
    end

    test "owner can reject without reason" do
      admin = admin_user()
      workspace = create_workspace(admin)
      applicant = normal_user()
      jr = create_join_request(workspace, applicant)

      assert {:ok, rejected} =
               jr
               |> Ash.Changeset.for_update(:reject, %{})
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert rejected.status == :rejected
      assert rejected.rejection_reason == nil
    end

    test "admin can reject join request" do
      admin = admin_user()
      workspace = create_workspace(admin)
      admin_member = register_user("jr-reject-admin@example.com", @password)
      add_member(workspace, admin_member, admin, [:admin])

      applicant = normal_user()
      jr = create_join_request(workspace, applicant)

      assert {:ok, rejected} =
               jr
               |> Ash.Changeset.for_update(:reject, %{rejection_reason: "no"})
               |> Ash.update(tenant: workspace.id, actor: admin_member)

      assert rejected.status == :rejected
    end

    test "plain member cannot reject" do
      admin = admin_user()
      workspace = create_workspace(admin)
      member = register_user("jr-reject-plain@example.com", @password)
      add_member(workspace, member, admin, [:member])

      applicant = normal_user()
      jr = create_join_request(workspace, applicant)

      assert {:error, %Ash.Error.Forbidden{}} =
               jr
               |> Ash.Changeset.for_update(:reject, %{rejection_reason: "no"})
               |> Ash.update(tenant: workspace.id, actor: member)
    end
  end

  describe "expired join request" do
    test "pending request with past approval_deadline is returned as expired on read" do
      admin = admin_user()
      workspace = create_workspace(admin)
      applicant = normal_user()
      jr = create_join_request(workspace, applicant)

      # Manually set approval_deadline to past
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE join_requests SET approval_deadline = NOW() - INTERVAL '1 day' WHERE id = $1",
          [Ecto.UUID.dump!(jr.id)]
        )

      # Read should trigger expired conversion and return expired
      assert {:ok, requests} =
               JoinRequest
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: workspace.id, actor: admin)

      expired = Enum.find(requests, &(&1.id == jr.id))
      assert expired != nil
      assert expired.status == :expired
      assert expired.expired_at != nil
    end

    test "pending request with future approval_deadline stays pending" do
      admin = admin_user()
      workspace = create_workspace(admin)
      applicant = normal_user()
      jr = create_join_request(workspace, applicant)

      # Read should not expire it
      assert {:ok, requests} =
               JoinRequest
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: workspace.id, actor: admin)

      pending = Enum.find(requests, &(&1.id == jr.id))
      assert pending != nil
      assert pending.status == :pending
    end
  end

  describe "read permissions" do
    test "applicant can read own join requests" do
      admin = admin_user()
      workspace = create_workspace(admin)
      applicant = normal_user()
      jr = create_join_request(workspace, applicant)

      assert {:ok, requests} =
               JoinRequest
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: workspace.id, actor: applicant)

      assert Enum.any?(requests, &(&1.id == jr.id))
    end

    test "owner can read all join requests in workspace" do
      admin = admin_user()
      workspace = create_workspace(admin)
      applicant = normal_user()
      jr = create_join_request(workspace, applicant)

      assert {:ok, requests} =
               JoinRequest
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: workspace.id, actor: admin)

      assert Enum.any?(requests, &(&1.id == jr.id))
    end

    test "plain member cannot read others' join requests" do
      admin = admin_user()
      workspace = create_workspace(admin)
      applicant = normal_user()
      jr = create_join_request(workspace, applicant)

      member = register_user("jr-read-member@example.com", @password)
      add_member(workspace, member, admin, [:member])

      assert {:ok, requests} =
               JoinRequest
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: workspace.id, actor: member)

      refute Enum.any?(requests, &(&1.id == jr.id))
    end

    test "outsider cannot read any join requests" do
      admin = admin_user()
      workspace = create_workspace(admin)
      applicant = normal_user()
      jr = create_join_request(workspace, applicant)

      outsider = register_user("jr-read-outsider@example.com", @password)

      assert {:ok, requests} =
               JoinRequest
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: workspace.id, actor: outsider)

      refute Enum.any?(requests, &(&1.id == jr.id))
    end
  end

  describe "tenant isolation" do
    test "join requests are scoped to their workspace tenant" do
      admin = admin_user()
      ws_a = create_workspace(admin, slug: "jr-iso-a-#{System.unique_integer([:positive])}")
      ws_b = create_workspace(admin, slug: "jr-iso-b-#{System.unique_integer([:positive])}")

      applicant = normal_user()
      create_join_request(ws_a, applicant)

      # ws_b should not see ws_a's join requests
      assert {:ok, ws_b_requests} =
               JoinRequest
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: ws_b.id, actor: admin)

      refute Enum.any?(ws_b_requests, &(&1.user_id == applicant.id))
    end
  end
end
