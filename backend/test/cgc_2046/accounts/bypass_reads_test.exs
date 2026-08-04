defmodule Cgc2046.Accounts.BypassReadsTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.BypassReads
  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Accounts.WorkspaceMembership
  alias AshAuthentication.Info, as: AuthInfo

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
    user = register_user("br-admin-#{System.unique_integer([:positive])}@example.com", @password)

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE users SET is_platform_admin = true WHERE id = $1",
        [Ecto.UUID.dump!(user.id)]
      )

    Ash.get!(User, user.id, actor: user, authorize?: false, domain: Cgc2046.GlobalApi)
  end

  defp new_user do
    register_user("br-user-#{System.unique_integer([:positive])}@example.com", @password)
  end

  defp create_workspace(admin) do
    {:ok, workspace} =
      Workspace
      |> Ash.Changeset.for_create(:create, %{
        slug: "br-#{System.unique_integer([:positive])}",
        name: "BR"
      })
      |> Ash.create(actor: admin)

    workspace
  end

  defp add_member(workspace, user, actor, role_names) do
    {:ok, membership} =
      WorkspaceMembership
      |> Ash.Changeset.for_create(:create, %{user_id: user.id})
      |> Ash.create(tenant: workspace.id, actor: actor, authorize?: false)

    if role_names != [] do
      # P0 grant scope 校验依赖 context.actor：actor/tenant 在 for_update 阶段传
      assert {:ok, _membership} =
               membership
               |> Ash.Changeset.for_update(
                 :assign_roles,
                 %{role_names: role_names},
                 actor: actor,
                 tenant: workspace.id
               )
               |> Ash.update()
    end

    membership
  end

  describe "member_count/1（聚合旁路，GROUP BY）" do
    test "跨工作台批量统计（含创建者自身）" do
      admin = admin_user()
      ws_a = create_workspace(admin)
      ws_b = create_workspace(admin)
      add_member(ws_a, new_user(), admin, [:member])
      add_member(ws_a, new_user(), admin, [:member])
      add_member(ws_b, new_user(), admin, [:admin])

      # 创建者自动是成员：ws_a = admin + 2，ws_b = admin + 1
      assert BypassReads.member_count([ws_a.id, ws_b.id]) == %{
               ws_a.id => 3,
               ws_b.id => 2
             }
    end

    test "空输入返回空 map" do
      assert BypassReads.member_count([]) == %{}
    end

    test "无 membership 行的工作台不出现在结果中（调用方 Map.get 兜底 0）" do
      # 随机不存在的 workspace id：查询无该行 → 结果无 key
      assert BypassReads.member_count([Ecto.UUID.generate()]) == %{}
    end

    test "DB 失败返回空 map（降级，不抛 500）" do
      # 释放 sandbox 连接模拟 DB 不可用
      Ecto.Adapters.SQL.Sandbox.checkin(Cgc2046.Repo)

      assert BypassReads.member_count([Ecto.UUID.generate()]) == %{}
    end
  end

  describe "shared_workspace_ids/1（成员资格旁路，供 exists 子查询注入）" do
    test "成员跨工作台返回全部 workspace_id" do
      admin = admin_user()
      ws_a = create_workspace(admin)
      ws_b = create_workspace(admin)
      member = new_user()
      add_member(ws_a, member, admin, [:member])
      add_member(ws_b, member, admin, [:owner])

      ids = BypassReads.shared_workspace_ids(member)
      assert Enum.sort(ids) == Enum.sort([ws_a.id, ws_b.id])
    end

    test "非成员返回空列表" do
      admin = admin_user()
      create_workspace(admin)
      outsider = new_user()

      assert BypassReads.shared_workspace_ids(outsider) == []
    end

    test "非法 actor.id（非 UUID）抛 ArgumentError（错误姿态与收敛前一致）" do
      assert_raise ArgumentError, fn ->
        BypassReads.shared_workspace_ids(%User{id: "not-a-uuid"})
      end
    end

    test "DB 失败返回空列表（降级，不抛 500）" do
      Ecto.Adapters.SQL.Sandbox.checkin(Cgc2046.Repo)

      assert BypassReads.shared_workspace_ids(%User{id: Ecto.UUID.generate()}) == []
    end
  end

  describe "owner_count/1（raw COUNT，按 membership 去重）" do
    test "2 个 owner（不同 membership）→ 2" do
      admin = admin_user()
      workspace = create_workspace(admin)
      add_member(workspace, new_user(), admin, [:owner])

      assert BypassReads.owner_count(workspace.id) == 2
    end

    test "一人持多角色（owner + admin）仍只算 1 次（去重）" do
      admin = admin_user()
      workspace = create_workspace(admin)

      multi = new_user()
      add_member(workspace, multi, admin, [:owner, :admin])
      add_member(workspace, new_user(), admin, [:owner])

      # admin（创建者）+ multi + 新 owner = 3
      assert BypassReads.owner_count(workspace.id) == 3
    end

    test "无 owner 的 workspace → 0" do
      admin = admin_user()
      workspace = create_workspace(admin)

      # 移除创建者自己的 owner 角色
      loaded = Ash.load!(workspace, :memberships, tenant: workspace.id, authorize?: false)
      membership = Enum.find(loaded.memberships, &(&1.user_id == admin.id))

      Ecto.Adapters.SQL.query!(
        Cgc2046.Repo,
        "DELETE FROM membership_roles WHERE membership_id = $1",
        [Ecto.UUID.dump!(membership.id)]
      )

      Ash.destroy!(membership, tenant: workspace.id, actor: admin, authorize?: false)

      assert BypassReads.owner_count(workspace.id) == 0
    end

    test "非 owner membership 不计数" do
      admin = admin_user()
      workspace = create_workspace(admin)
      add_member(workspace, new_user(), admin, [:admin])
      add_member(workspace, new_user(), admin, [:member])

      # admin（owner）+ 2 非 owner = 1
      assert BypassReads.owner_count(workspace.id) == 1
    end

    test "非法 workspace_id 抛 ArgumentError（与 member_count 同姿态）" do
      assert_raise ArgumentError, fn ->
        BypassReads.owner_count("not-a-uuid")
      end
    end

    test "DB 失败返回 0（降级，不抛 500）" do
      Ecto.Adapters.SQL.Sandbox.checkin(Cgc2046.Repo)

      assert BypassReads.owner_count(Ecto.UUID.generate()) == 0
    end
  end
end
