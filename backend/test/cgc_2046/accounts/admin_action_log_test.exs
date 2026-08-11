defmodule Cgc2046.Accounts.AdminActionLogTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Accounts.WorkspaceApplication
  alias AshAuthentication.Info, as: AuthInfo

  require Ash.Query

  @password "Test1234!"

  # 断言纪律：admin_action_logs 是全局表，测试 DB 跨用例累积（部分用例经非沙箱
  # 上下文写日志且提交），所有断言按 target_id 收敛，不断言全局行数。

  defp register_user(email) do
    strategy = AuthInfo.strategy!(User, :password)

    assert {:ok, user} =
             AshAuthentication.Strategy.action(strategy, :register, %{
               email: email,
               password: @password
             })

    user
  end

  # 注册一个平台管理员用户（直接写库提权，模拟种子/运维操作）
  defp admin_user(email \\ "aal-admin@example.com") do
    user = register_user(email)

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE users SET is_platform_admin = true WHERE id = $1",
        [Ecto.UUID.dump!(user.id)]
      )

    Ash.get!(User, user.id, actor: user, authorize?: false, domain: Cgc2046.GlobalApi)
  end

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
      admin = admin_user()
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
      admin = admin_user()
      applicant = register_user("aal-applicant-approve@example.com")
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
      admin = admin_user()
      applicant = register_user("aal-applicant-reject@example.com")
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
      admin = admin_user()
      target = register_user("aal-target@example.com")

      assert {:ok, promoted} =
               target
               |> Ash.Changeset.for_update(:set_platform_admin, %{is_platform_admin: true})
               |> Ash.update(actor: admin)

      assert [promote_log] = read_logs_for(admin, :admin_promote, target.id)
      assert promote_log.actor_id == admin.id
      assert promote_log.target_type == :user
      assert promote_log.metadata["email"] == "aal-target@example.com"

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
      admin = admin_user()

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "aal-policy-#{System.unique_integer([:positive])}",
          name: "AAL Policy"
        })
        |> Ash.create(actor: admin)

      assert [_] = read_logs_for(admin, :workspace_create, workspace.id)

      outsider = register_user("aal-outsider@example.com")

      assert {:error, %Ash.Error.Forbidden{}} =
               AdminActionLog
               |> Ash.Query.for_read(:read)
               |> Ash.read(actor: outsider)
    end
  end
end
