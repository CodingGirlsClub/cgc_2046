defmodule Cgc2046.Accounts.AdminActionLogTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Accounts.WorkspaceApplication
  alias Cgc2046.AccountsFixtures, as: Fixtures

  require Ash.Query

  # 断言纪律：admin_action_logs 是全局表，测试 DB 跨用例累积（部分用例经非沙箱
  # 上下文写日志且提交），所有断言按 target_id 收敛，不断言全局行数。

  defp create_application(user) do
    {:ok, application} =
      WorkspaceApplication
      |> Ash.Changeset.for_create(:create, %{
        name: "AAL App",
        slug: "aal-app-#{System.unique_integer([:positive])}",
        purpose: "admin action log test",
        applicant_id: user.id
      })
      |> Ash.create(actor: user)

    application
  end

  # 按 action + target_id 收敛读日志（admin 视角）
  defp read_logs_for(actor, action, target_id) do
    AdminActionLog
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(action == ^action and target_id == ^target_id)
    |> Ash.read!(actor: actor)
  end

  describe "workspace_create hook" do
    test "direct workspace create with actor -> one workspace_create row for that workspace" do
      admin = Fixtures.platform_admin("aal-admin")
      slug = "aal-ws-#{System.unique_integer([:positive])}"

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{slug: slug, name: "AAL WS"})
        |> Ash.create(actor: admin)

      assert [log] = read_logs_for(admin, :workspace_create, workspace.id)
      assert log.actor_id == admin.id
      assert log.target_type == :workspace
      assert log.result == :success
      assert log.metadata["slug"] == slug
      assert log.metadata["name"] == "AAL WS"
    end
  end

  describe "application approve/reject hooks" do
    test "approve -> application_approve row for the application and NO workspace_create row for the created workspace (#116 不双记不变量)" do
      admin = Fixtures.platform_admin("aal-admin")
      applicant = Fixtures.register_user("aal-applicant-approve")
      application = create_application(applicant)

      assert {:ok, approved} =
               application
               |> Ash.Changeset.for_update(:approve, %{})
               |> Ash.update(actor: admin)

      assert approved.status == :approved

      workspace =
        Workspace
        |> Ash.Query.filter(slug == ^application.slug)
        |> Ash.read_one!(authorize?: false)

      # approve 内部以无 actor 调 Workspace create → 不得为该 workspace 产生 workspace_create 行
      assert read_logs_for(admin, :workspace_create, workspace.id) == []

      assert [log] = read_logs_for(admin, :application_approve, application.id)
      assert log.actor_id == admin.id
      assert log.target_type == :workspace_application
      assert log.metadata["applicant_id"] == applicant.id
      # 创建的 workspace id 进 metadata 快照
      assert log.metadata["workspace_id"] == workspace.id
    end

    test "reject -> application_reject row + rejected_by/rejected_at set on application" do
      admin = Fixtures.platform_admin("aal-admin")
      applicant = Fixtures.register_user("aal-applicant-reject")
      application = create_application(applicant)

      assert {:ok, rejected} =
               application
               |> Ash.Changeset.for_update(:reject, %{rejection_reason: "slug 重复"})
               |> Ash.update(actor: admin)

      assert rejected.rejected_by == admin.id
      assert rejected.rejected_at != nil

      assert [log] = read_logs_for(admin, :application_reject, application.id)
      assert log.actor_id == admin.id
      assert log.metadata["rejection_reason"] == "slug 重复"
    end
  end

  describe "promote/demote hooks" do
    test "set_platform_admin(true) -> admin_promote row; demote_platform_admin -> admin_demote row" do
      admin = Fixtures.platform_admin("aal-admin")
      target = Fixtures.register_user("aal-target")

      assert {:ok, promoted} =
               target
               |> Ash.Changeset.for_update(:set_platform_admin, %{is_platform_admin: true})
               |> Ash.update(actor: admin)

      assert [promote_log] = read_logs_for(admin, :admin_promote, target.id)
      assert promote_log.actor_id == admin.id
      assert promote_log.target_type == :user
      assert promote_log.metadata["email"] == to_string(target.email)

      # 此时有 2 个 admin（admin + promoted），demote 不触发 last-admin 不变量
      assert {:ok, _demoted} =
               promoted
               |> Ash.Changeset.for_update(:demote_platform_admin, %{})
               |> Ash.update(actor: admin)

      assert [demote_log] = read_logs_for(admin, :admin_demote, target.id)
      assert demote_log.actor_id == admin.id
    end
  end

  describe "read policy" do
    test "platform_admin can read; non-admin is denied" do
      admin = Fixtures.platform_admin("aal-admin")

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "aal-policy-#{System.unique_integer([:positive])}",
          name: "AAL Policy"
        })
        |> Ash.create(actor: admin)

      assert [_] = read_logs_for(admin, :workspace_create, workspace.id)

      outsider = Fixtures.register_user("aal-outsider")

      assert {:error, %Ash.Error.Forbidden{}} =
               AdminActionLog
               |> Ash.Query.for_read(:read)
               |> Ash.read(actor: outsider)
    end
  end

  describe "owner reassign / invitation cancel hooks (#114)" do
    test "reassign_owner -> one owner_reassign row for that workspace" do
      admin = Fixtures.platform_admin("aal-admin")
      new_owner = Fixtures.register_user("aal-reassign-owner")

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "aal-reassign-#{System.unique_integer([:positive])}",
          name: "AAL Reassign",
          owner_email: "aal-old-owner@example.com"
        })
        |> Ash.create(actor: admin)

      {:ok, _workspace} =
        workspace
        |> Ash.Changeset.for_update(:reassign_owner, %{owner_user_id: new_owner.id})
        |> Ash.update(actor: admin)

      assert [log] = read_logs_for(admin, :owner_reassign, workspace.id)
      assert log.actor_id == admin.id
      assert log.target_type == :workspace
      assert log.metadata["owner_user_id"] == new_owner.id
    end

    test "platform admin revoking owner-preauthorized invitation -> owner_invitation_cancel row" do
      admin = Fixtures.platform_admin("aal-admin")

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "aal-cancel-#{System.unique_integer([:positive])}",
          name: "AAL Cancel",
          owner_email: "aal-cancel-owner@example.com"
        })
        |> Ash.create(actor: admin)

      [invitation] =
        Cgc2046.Accounts.Invitation
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(workspace_id == ^workspace.id)
        |> Ash.read!(tenant: workspace.id, actor: admin)

      {:ok, _revoked} =
        invitation
        |> Ash.Changeset.for_update(:revoke, %{})
        |> Ash.update(actor: admin)

      assert [log] = read_logs_for(admin, :owner_invitation_cancel, workspace.id)
      assert log.actor_id == admin.id
      assert log.metadata["invitation_id"] == invitation.id
      assert log.metadata["target_email"] == "aal-cancel-owner@example.com"
    end

    test "non-admin inviter revoking plain invitation -> no owner_invitation_cancel row" do
      admin = Fixtures.platform_admin("aal-admin")
      owner = Fixtures.register_user("aal-plain-owner")

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "aal-nolog-#{System.unique_integer([:positive])}",
          name: "AAL NoLog",
          owner_user_id: owner.id
        })
        |> Ash.create(actor: admin)

      {:ok, invitation} =
        Cgc2046.Accounts.Invitation
        |> Ash.Changeset.for_create(:create, %{
          workspace_id: workspace.id,
          inviter_id: owner.id,
          target_email: "aal-member-invite@example.com"
        })
        |> Ash.create(actor: owner)

      {:ok, _revoked} =
        invitation
        |> Ash.Changeset.for_update(:revoke, %{})
        |> Ash.update(actor: owner)

      # owner（非 platform_admin）撤销普通成员邀请 → 不记治理留痕
      assert [] = read_logs_for(admin, :owner_invitation_cancel, workspace.id)
    end
  end
end
