defmodule Cgc2046.Sponsorship.Policies.SponsorshipApproverTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.Role
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Sponsorship.Sponsorship
  alias Cgc2046.Sponsorship.Policies.SponsorshipApprover

  describe "approver_roles/1 规则唯一真源（拍板 #4）" do
    test ":event 委托 Role.manage_roles/0（owner/admin，角色清单变更自动跟随）" do
      assert SponsorshipApprover.approver_roles(:event) == Role.manage_roles()
      assert SponsorshipApprover.approver_roles(:event) == [:owner, :admin]
    end

    test ":workspace 仅 Owner（长期承诺加严；平台 Admin 备案二期不参与审批）" do
      assert SponsorshipApprover.approver_roles(:workspace) == [:owner]
    end
  end

  describe "match?/3 委托 approver_roles（#2 薄适配器，直接钉测）" do
    test "admin：Event 级通过 / Workspace 级拒绝（拍板 #4）" do
      admin = Fixtures.platform_admin("sapprover-admin")
      workspace = Fixtures.create_workspace(admin)
      admin_member = Fixtures.register_user("sapprover-admin-member")
      Fixtures.add_member(workspace, admin_member, [:admin])

      event_cs = %Ash.Changeset{data: %Sponsorship{level: :event, workspace_id: workspace.id}}
      assert SponsorshipApprover.match?(admin_member, %{changeset: event_cs}, [])

      ws_cs = %Ash.Changeset{data: %Sponsorship{level: :workspace, workspace_id: workspace.id}}
      refute SponsorshipApprover.match?(admin_member, %{changeset: ws_cs}, [])
    end

    test "owner：Event 级与 Workspace 级都通过" do
      owner = Fixtures.platform_admin("sapprover-owner")
      workspace = Fixtures.create_workspace(owner)
      owner_member = Fixtures.register_user("sapprover-owner-member")
      Fixtures.add_member(workspace, owner_member, [:owner])

      for level <- [:event, :workspace] do
        changeset = %Ash.Changeset{data: %Sponsorship{level: level, workspace_id: workspace.id}}
        assert SponsorshipApprover.match?(owner_member, %{changeset: changeset}, [])
      end
    end

    test "非成员 → 拒绝（任何 level）" do
      admin = Fixtures.platform_admin("sapprover-outsider")
      workspace = Fixtures.create_workspace(admin)
      outsider = Fixtures.register_user("sapprover-outsider-user")

      for level <- [:event, :workspace] do
        changeset = %Ash.Changeset{data: %Sponsorship{level: level, workspace_id: workspace.id}}
        refute SponsorshipApprover.match?(outsider, %{changeset: changeset}, [])
      end
    end

    test "匿名 actor → 拒绝" do
      refute SponsorshipApprover.match?(nil, %{changeset: %Ash.Changeset{}}, [])
    end
  end
end
