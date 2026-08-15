defmodule Cgc2046.Accounts.BypassReadsTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.BypassReads
  alias Cgc2046.AccountsFixtures, as: Fixtures

  describe "member_count/1（聚合旁路，GROUP BY）" do
    test "跨工作台批量统计（含创建者自身）" do
      admin = Fixtures.platform_admin("br-admin")
      ws_a = Fixtures.create_workspace(admin)
      ws_b = Fixtures.create_workspace(admin)
      Fixtures.add_member(ws_a, Fixtures.register_user("br-user"))
      Fixtures.add_member(ws_a, Fixtures.register_user("br-user"))
      Fixtures.add_member(ws_b, Fixtures.register_user("br-user"), [:admin])

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

  describe "owner_count/1（raw COUNT，按 membership 去重）" do
    test "2 个 owner（不同 membership）→ 2" do
      admin = Fixtures.platform_admin("br-admin")
      workspace = Fixtures.create_workspace(admin)
      Fixtures.add_member(workspace, Fixtures.register_user("br-user"), [:owner])

      assert BypassReads.owner_count(workspace.id) == 2
    end

    test "一人持多角色（owner + admin）仍只算 1 次（去重）" do
      admin = Fixtures.platform_admin("br-admin")
      workspace = Fixtures.create_workspace(admin)

      multi = Fixtures.register_user("br-user")
      Fixtures.add_member(workspace, multi, [:owner, :admin])
      Fixtures.add_member(workspace, Fixtures.register_user("br-user"), [:owner])

      # admin（创建者）+ multi + 新 owner = 3
      assert BypassReads.owner_count(workspace.id) == 3
    end

    test "无 owner 的 workspace → 0" do
      admin = Fixtures.platform_admin("br-admin")
      workspace = Fixtures.create_workspace(admin)

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
      admin = Fixtures.platform_admin("br-admin")
      workspace = Fixtures.create_workspace(admin)
      Fixtures.add_member(workspace, Fixtures.register_user("br-user"), [:admin])
      Fixtures.add_member(workspace, Fixtures.register_user("br-user"))

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
