defmodule Cgc2046.Workflows.StepAuthorizationTest do
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Accounts.Role
  alias Cgc2046.Accounts.WorkspaceMembership
  alias Cgc2046.Accounts.MembershipRole
  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.Step
  alias Cgc2046.Workflows.StepRole
  alias Cgc2046.Workflows.StepAuthorization
  alias AshAuthentication.Info, as: AuthInfo

  require Ash.Query

  @admin_email "stepauth-admin@example.com"
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

  defp platform_admin(email \\ @admin_email) do
    user = register_user(email)

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE users SET is_platform_admin = true WHERE id = $1",
        [Ecto.UUID.dump!(user.id)]
      )

    Ash.get!(User, user.id, actor: user, authorize?: false, domain: Cgc2046.GlobalApi)
  end

  defp create_workspace(admin) do
    slug = "stepauth-ws-#{System.unique_integer([:positive])}"

    assert {:ok, workspace} =
             Workspace
             |> Ash.Changeset.for_create(:create, %{slug: slug, name: "StepAuth WS"})
             |> Ash.create(actor: admin)

    workspace
  end

  # workspace create 时已 seed 六角色（workspace.ex after_action），按 name 取 role_id
  defp role_by_name(workspace, name) do
    assert {:ok, role} =
             Role
             |> Ash.Query.filter(name == ^name)
             |> Ash.read_one(tenant: workspace.id, authorize?: false)

    role
  end

  # 建非 owner 成员：Membership + MembershipRole（参照 workspace.ex owner 建立模式）
  defp add_member(workspace, user, role_name) do
    role = role_by_name(workspace, role_name)

    assert {:ok, membership} =
             WorkspaceMembership
             |> Ash.Changeset.for_create(:create, %{user_id: user.id})
             |> Ash.create(tenant: workspace.id, authorize?: false)

    assert {:ok, _} =
             MembershipRole
             |> Ash.Changeset.for_create(:create, %{
               membership_id: membership.id,
               role_id: role.id
             })
             |> Ash.create(tenant: workspace.id, authorize?: false)

    membership
  end

  defp create_definition(workspace, actor, attrs \\ %{}) do
    defaults = %{
      name: "StepAuth workflow",
      type: :research,
      input_schema: %{"topic" => "string"},
      node_def: %{steps: ["outline_design", "content_review"]},
      approval_timeout: 604_800
    }

    WorkflowDefinition
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs),
      tenant: workspace.id,
      actor: actor
    )
    |> Ash.create(tenant: workspace.id, actor: actor)
  end

  defp create_step(workspace, actor, defn, attrs \\ %{}) do
    defaults = %{
      definition_id: defn.id,
      step_key: "approval",
      title: "审批",
      type: :manual
    }

    Step
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs),
      tenant: workspace.id,
      actor: actor
    )
    |> Ash.create(tenant: workspace.id, actor: actor)
  end

  defp create_step_role(workspace, actor, step, role_names) do
    for role_name <- role_names do
      role = role_by_name(workspace, role_name)

      assert {:ok, _step_role} =
               StepRole
               |> Ash.Changeset.for_create(
                 :create,
                 %{step_id: step.id, role_id: role.id},
                 tenant: workspace.id,
                 actor: actor
               )
               |> Ash.create(tenant: workspace.id, actor: actor)
    end
  end

  describe "authorize_signal/4（IO：真实 DB 读取）" do
    test "Step 行不存在 → :ok（未配置授权 = 不限制）" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      member = register_user("stepauth-member@example.com")
      add_member(workspace, member, :member)

      assert :ok =
               StepAuthorization.authorize_signal(
                 member,
                 workspace.id,
                 Ecto.UUID.generate(),
                 "approval"
               )
    end

    test "Step 存在但无 StepRole 行 → :ok" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      member = register_user("stepauth-member2@example.com")
      add_member(workspace, member, :member)

      {:ok, defn} = create_definition(workspace, admin)
      {:ok, _step} = create_step(workspace, admin, defn)

      assert :ok = StepAuthorization.authorize_signal(member, workspace.id, defn.id, "approval")
    end

    test "租户隔离：A 配置角色，B 同 definition_id+step_key 无配置 → B 放行、A 拒绝" do
      admin = platform_admin()
      ws_a = create_workspace(admin)
      ws_b = create_workspace(admin)

      member_a = register_user("stepauth-ma@example.com")
      member_b = register_user("stepauth-mb@example.com")
      add_member(ws_a, member_a, :member)
      add_member(ws_b, member_b, :member)

      # A：approval 仅授权 :owner
      {:ok, defn} = create_definition(ws_a, admin)
      {:ok, step} = create_step(ws_a, admin, defn)
      create_step_role(ws_a, admin, step, [:owner])

      # B 无任何 Step 配置（同 definition_id + step_key 查不到）→ 不限制
      assert :ok = StepAuthorization.authorize_signal(member_b, ws_b.id, defn.id, "approval")

      # A：member 不在 [:owner] 集内 → 拒绝
      assert {:error, :unauthorized} =
               StepAuthorization.authorize_signal(member_a, ws_a.id, defn.id, "approval")

      # A：owner 豁免
      assert :ok = StepAuthorization.authorize_signal(admin, ws_a.id, defn.id, "approval")
    end

    test "owner/admin 豁免短路：不读 step 配置（fetch 不被调用）" do
      admin = platform_admin()
      workspace = create_workspace(admin)

      # 回归钉测：曾因参数急切求值，owner/admin 也先触发 step 配置读取——
      # 多 2 次查询且被配置读失败（fail-closed）波及。fetch 一旦被调用即失败。
      assert :ok =
               StepAuthorization.authorize_signal(
                 admin,
                 workspace.id,
                 Ecto.UUID.generate(),
                 "approval",
                 fn _, _, _ -> flunk("owner/admin must not fetch step config") end
               )
    end
  end
end
