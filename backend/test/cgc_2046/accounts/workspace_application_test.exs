defmodule Cgc2046.Accounts.WorkspaceApplicationTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Accounts.WorkspaceApplication
  alias Cgc2046.Accounts.WorkspaceMembership
  alias AshAuthentication.Info, as: AuthInfo

  @admin_email "wapp-admin@example.com"
  @applicant_email "wapp-applicant@example.com"
  @password "sup3r-secret-password"

  defp password_strategy, do: AuthInfo.strategy!(User, :password)

  defp register_user(email) do
    strategy = password_strategy()

    assert {:ok, user} =
             AshAuthentication.Strategy.action(strategy, :register, %{
               email: email,
               password: @password
             })

    user
  end

  defp platform_admin do
    user = register_user(@admin_email)

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE users SET is_platform_admin = true WHERE id = $1",
        [Ecto.UUID.dump!(user.id)]
      )

    Ash.get!(User, user.id, actor: user, authorize?: false, domain: Cgc2046.GlobalApi)
  end

  defp normal_user(email \\ @applicant_email), do: register_user(email)

  defp create_application(user, attrs \\ %{}) do
    changes =
      Map.merge(
        %{
          applicant_id: user.id,
          name: "My Workspace",
          slug: "wapp-ws-#{System.unique_integer([:positive])}",
          purpose: "研究协作"
        },
        attrs
      )

    {:ok, application} =
      WorkspaceApplication
      |> Ash.Changeset.for_create(:create, changes)
      |> Ash.create(actor: user)

    application
  end

  defp set_status(application, status) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE workspace_applications SET status = $2 WHERE id = $1",
        [Ecto.UUID.dump!(application.id), Atom.to_string(status)]
      )

    Ash.get!(WorkspaceApplication, application.id, authorize?: false)
  end

  defp backdate_deadline(application, interval) do
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE workspace_applications SET approval_deadline = NOW() - INTERVAL '#{interval}' WHERE id = $1",
        [Ecto.UUID.dump!(application.id)]
      )
  end

  describe "create workspace application" do
    test "applicant can create a pending application with 7-day deadline" do
      applicant = normal_user()
      application = create_application(applicant)

      assert application.status == :pending
      assert application.applicant_id == applicant.id
      assert application.approval_deadline != nil
      assert application.approved_by == nil
      assert application.approved_at == nil
      assert application.expired_at == nil
    end

    test "approval_deadline is set to roughly 7 days from now" do
      applicant = normal_user()
      application = create_application(applicant)

      assert DateTime.compare(application.approval_deadline, DateTime.utc_now()) == :gt

      diff_seconds = DateTime.diff(application.approval_deadline, DateTime.utc_now())
      assert diff_seconds > 6 * 24 * 3600
      assert diff_seconds < 8 * 24 * 3600
    end

    test "slug must match workspace slug format" do
      applicant = normal_user()

      assert {:error, %Ash.Error.Invalid{}} =
               WorkspaceApplication
               |> Ash.Changeset.for_create(:create, %{
                 name: "My Workspace",
                 slug: "Bad Slug!",
                 purpose: "研究"
               })
               |> Ash.create(actor: applicant)
    end

    test "outsider cannot create application on behalf of another user" do
      applicant = normal_user()
      outsider = register_user("wapp-outsider@example.com")

      assert {:error, %Ash.Error.Forbidden{}} =
               WorkspaceApplication
               |> Ash.Changeset.for_create(:create, %{
                 name: "My Workspace",
                 slug: "wapp-ws-#{System.unique_integer([:positive])}",
                 purpose: "研究",
                 applicant_id: applicant.id
               })
               |> Ash.create(actor: outsider)
    end
  end

  describe "approve workspace application" do
    test "platform_admin approve creates workspace with applicant as Owner" do
      admin = platform_admin()
      applicant = normal_user()
      application = create_application(applicant)

      assert {:ok, approved} =
               application
               |> Ash.Changeset.for_update(:approve, %{})
               |> Ash.update(actor: admin)

      assert approved.status == :approved
      assert approved.approved_by == admin.id
      assert approved.approved_at != nil

      # workspace 已创建（slug 匹配）
      assert {:ok, workspace} =
               Workspace
               |> Ash.Query.for_read(:get_by_slug, %{slug: application.slug})
               |> Ash.read_one(authorize?: false)

      assert workspace.name == application.name

      # applicant 是 Owner（membership + owner role）
      assert {:ok, memberships} =
               WorkspaceMembership
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: workspace.id, authorize?: false)

      membership = Enum.find(memberships, &(&1.user_id == applicant.id))
      assert membership != nil

      loaded = Ash.load!(membership, :roles, tenant: workspace.id, authorize?: false)
      assert Enum.any?(loaded.roles, &(&1.name == :owner))
    end

    test "non-platform-admin cannot approve" do
      applicant = normal_user()
      application = create_application(applicant)
      outsider = register_user("wapp-nonadmin@example.com")

      assert {:error, %Ash.Error.Forbidden{}} =
               application
               |> Ash.Changeset.for_update(:approve, %{})
               |> Ash.update(actor: outsider)
    end

    test "approve fails and rolls back when slug is already taken" do
      admin = platform_admin()
      applicant = normal_user()
      application = create_application(applicant)

      # 预占 slug：platform_admin 直接创建同名 workspace
      assert {:ok, _} =
               Workspace
               |> Ash.Changeset.for_create(:create, %{
                 slug: application.slug,
                 name: "Taken",
                 join_policy: :request
               })
               |> Ash.create(actor: admin)

      assert {:error, %Ash.Error.Invalid{}} =
               application
               |> Ash.Changeset.for_update(:approve, %{})
               |> Ash.update(actor: admin)

      # 事务回滚：application 保持 pending，未产生第二个 workspace
      reloaded = Ash.get!(WorkspaceApplication, application.id, authorize?: false)
      assert reloaded.status == :pending
    end

    test "approve on application past approval_deadline is rejected (atomic WHERE guards expiry)" do
      admin = platform_admin()
      applicant = normal_user()
      application = create_application(applicant)
      backdate_deadline(application, "1 day")

      assert {:error, %Ash.Error.Invalid{}} =
               application
               |> Ash.Changeset.for_update(:approve, %{})
               |> Ash.update(actor: admin)

      reloaded = Ash.get!(WorkspaceApplication, application.id, authorize?: false)
      assert reloaded.status == :pending
    end
  end

  describe "reject workspace application" do
    test "platform_admin can reject with reason" do
      admin = platform_admin()
      applicant = normal_user()
      application = create_application(applicant)

      assert {:ok, rejected} =
               application
               |> Ash.Changeset.for_update(:reject, %{rejection_reason: "slug 不合适"})
               |> Ash.update(actor: admin)

      assert rejected.status == :rejected
      assert rejected.rejection_reason == "slug 不合适"
    end

    test "platform_admin can reject without reason" do
      admin = platform_admin()
      applicant = normal_user()
      application = create_application(applicant)

      assert {:ok, rejected} =
               application
               |> Ash.Changeset.for_update(:reject, %{})
               |> Ash.update(actor: admin)

      assert rejected.status == :rejected
      assert rejected.rejection_reason == nil
    end

    test "non-platform-admin cannot reject" do
      applicant = normal_user()
      application = create_application(applicant)
      outsider = register_user("wapp-reject-nonadmin@example.com")

      assert {:error, %Ash.Error.Forbidden{}} =
               application
               |> Ash.Changeset.for_update(:reject, %{rejection_reason: "no"})
               |> Ash.update(actor: outsider)
    end
  end

  describe "expire workspace application" do
    test "expire transitions pending application to expired (internal action)" do
      applicant = normal_user()
      application = create_application(applicant)

      assert {:ok, expired} =
               application
               |> Ash.Changeset.for_update(:expire)
               |> Ash.update(actor: applicant, authorize?: false)

      assert expired.status == :expired
      assert expired.expired_at != nil
    end
  end

  describe "status guard on non-pending applications" do
    test "approve on already-approved application is rejected" do
      admin = platform_admin()
      applicant = normal_user()
      application = create_application(applicant)
      approved = set_status(application, :approved)

      assert {:error, %Ash.Error.Invalid{}} =
               approved
               |> Ash.Changeset.for_update(:approve, %{})
               |> Ash.update(actor: admin)

      reloaded = Ash.get!(WorkspaceApplication, application.id, authorize?: false)
      assert reloaded.status == :approved
    end

    test "reject on already-approved application is rejected" do
      admin = platform_admin()
      applicant = normal_user()
      application = create_application(applicant)
      approved = set_status(application, :approved)

      assert {:error, %Ash.Error.Invalid{}} =
               approved
               |> Ash.Changeset.for_update(:reject, %{rejection_reason: "try"})
               |> Ash.update(actor: admin)

      reloaded = Ash.get!(WorkspaceApplication, application.id, authorize?: false)
      assert reloaded.status == :approved
    end

    test "expire on already-approved application is rejected" do
      applicant = normal_user()
      application = create_application(applicant)
      approved = set_status(application, :approved)

      assert {:error, %Ash.Error.Invalid{}} =
               approved
               |> Ash.Changeset.for_update(:expire)
               |> Ash.update(actor: applicant, authorize?: false)

      reloaded = Ash.get!(WorkspaceApplication, application.id, authorize?: false)
      assert reloaded.status == :approved
    end
  end

  describe "read permissions" do
    test "applicant can read own application including status and rejection_reason" do
      admin = platform_admin()
      applicant = normal_user()
      application = create_application(applicant)

      assert {:ok, rejected} =
               application
               |> Ash.Changeset.for_update(:reject, %{rejection_reason: "不通过"})
               |> Ash.update(actor: admin)

      assert rejected.status == :rejected

      assert {:ok, applications} =
               WorkspaceApplication
               |> Ash.Query.for_read(:read)
               |> Ash.read(actor: applicant)

      own = Enum.find(applications, &(&1.id == application.id))
      assert own != nil
      assert own.status == :rejected
      assert own.rejection_reason == "不通过"
    end

    test "platform_admin can read all applications" do
      admin = platform_admin()
      applicant = normal_user()
      application = create_application(applicant)

      assert {:ok, applications} =
               WorkspaceApplication
               |> Ash.Query.for_read(:read)
               |> Ash.read(actor: admin)

      assert Enum.any?(applications, &(&1.id == application.id))
    end

    test "other user cannot read applicant's application" do
      applicant = normal_user()
      application = create_application(applicant)
      outsider = register_user("wapp-read-outsider@example.com")

      assert {:ok, applications} =
               WorkspaceApplication
               |> Ash.Query.for_read(:read)
               |> Ash.read(actor: outsider)

      refute Enum.any?(applications, &(&1.id == application.id))
    end
  end
end
