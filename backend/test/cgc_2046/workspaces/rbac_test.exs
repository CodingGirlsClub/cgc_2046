defmodule Cgc2046.RbacTest do
  @moduledoc """
  T04 切片B:成员与角色 RBAC 数据层。

  对应验收标准:
  - Owner 可给成员分配多个角色(WorkspaceMembership + MembershipRole)
  - 多角色权限并集判定生效(命中任一角色即放行)
  - 非成员访问租户资源 → 403(Forbidden)
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.TestFixtures
  alias Cgc2046.Workspaces.{MembershipRole, Role, WorkspaceMembership}
  alias Cgc2046.Rbac

  defp role_by_name!(workspace, name) do
    {:ok, roles} = Ash.read(Role, tenant: workspace.id, authorize?: false)

    Enum.find(roles, fn role -> role.name == name end) ||
      raise "角色 #{name} 未生成"
  end

  describe "Owner 可给成员分配多个角色" do
    setup do
      admin = TestFixtures.seed_platform_admin()
      ws = TestFixtures.seed_workspace(owner: admin)
      user = TestFixtures.seed_user()

      {:ok, membership} =
        Ash.create(WorkspaceMembership, %{user_id: user.id}, tenant: ws.id, actor: admin)

      %{admin: admin, ws: ws, user: user, membership: membership}
    end

    test "给一个成员分配 Tutor + Learner 两个角色", %{ws: ws, admin: admin, membership: membership} do
      tutor = role_by_name!(ws, "Tutor")
      learner = role_by_name!(ws, "Learner")

      {:ok, _mr1} =
        Ash.create(MembershipRole, %{membership_id: membership.id, role_id: tutor.id},
          tenant: ws.id,
          actor: admin
        )

      {:ok, _mr2} =
        Ash.create(MembershipRole, %{membership_id: membership.id, role_id: learner.id},
          tenant: ws.id,
          actor: admin
        )

      loaded =
        Ash.get!(WorkspaceMembership, membership.id,
          tenant: ws.id,
          actor: admin,
          load: [:roles]
        )

      assert Enum.map(loaded.roles, & &1.name) |> Enum.sort() == ["Learner", "Tutor"]
    end

    test "同一成员重复分配同一角色被拒绝(唯一约束)", %{
      ws: ws,
      admin: admin,
      membership: membership
    } do
      owner = role_by_name!(ws, "Owner")

      {:ok, _mr} =
        Ash.create(MembershipRole, %{membership_id: membership.id, role_id: owner.id},
          tenant: ws.id,
          actor: admin
        )

      assert {:error, error} =
               Ash.create(MembershipRole, %{membership_id: membership.id, role_id: owner.id},
                 tenant: ws.id,
                 actor: admin
               )

      assert Exception.message(error) =~ "already been taken"
    end
  end

  describe "多角色权限并集判定(Rbac.can?/3)" do
    setup do
      admin = TestFixtures.seed_platform_admin()
      ws = TestFixtures.seed_workspace(owner: admin)
      user = TestFixtures.seed_user()
      stranger = TestFixtures.seed_user()

      {:ok, membership} =
        Ash.create(WorkspaceMembership, %{user_id: user.id}, tenant: ws.id, actor: admin)

      %{admin: admin, ws: ws, user: user, membership: membership, stranger: stranger}
    end

    test "命中任一角色即放行(Tutor+Learner 并集 → workflow:create 放行)", %{
      ws: ws,
      admin: admin,
      user: user,
      membership: membership
    } do
      tutor = role_by_name!(ws, "Tutor")
      learner = role_by_name!(ws, "Learner")

      {:ok, _} =
        Ash.create(MembershipRole, %{membership_id: membership.id, role_id: tutor.id},
          tenant: ws.id,
          actor: admin
        )

      {:ok, _} =
        Ash.create(MembershipRole, %{membership_id: membership.id, role_id: learner.id},
          tenant: ws.id,
          actor: admin
        )

      # Tutor 有 workflow:create(Learner 没有);并集命中 → 放行
      assert Rbac.can?(user, "workflow:create", tenant: ws.id)
    end

    test "仅 Learner → workflow:create 拒绝,agent:personal:create 放行", %{
      ws: ws,
      admin: admin,
      user: user,
      membership: membership
    } do
      learner = role_by_name!(ws, "Learner")

      {:ok, _} =
        Ash.create(MembershipRole, %{membership_id: membership.id, role_id: learner.id},
          tenant: ws.id,
          actor: admin
        )

      refute Rbac.can?(user, "workflow:create", tenant: ws.id)
      assert Rbac.can?(user, "agent:personal:create", tenant: ws.id)
    end

    test "非成员 → 一律拒绝", %{ws: ws, stranger: stranger} do
      refute Rbac.can?(stranger, "agent:personal:create", tenant: ws.id)
      refute Rbac.can?(stranger, "workflow:create", tenant: ws.id)
    end

    test "无 actor → 拒绝", %{ws: ws} do
      refute Rbac.can?(nil, "agent:personal:create", tenant: ws.id)
    end
  end

  describe "非成员访问租户资源 → 403" do
    setup do
      admin = TestFixtures.seed_platform_admin()
      ws = TestFixtures.seed_workspace(owner: admin)
      stranger = TestFixtures.seed_user()
      %{admin: admin, ws: ws, stranger: stranger}
    end

    test "非成员读 Role → Forbidden", %{ws: ws, stranger: stranger} do
      assert {:error, %Ash.Error.Forbidden{}} = Ash.read(Role, tenant: ws.id, actor: stranger)
    end

    test "非成员读 WorkspaceMembership → Forbidden", %{ws: ws, stranger: stranger} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.read(WorkspaceMembership, tenant: ws.id, actor: stranger)
    end

    test "成员(Owner)可读租户资源", %{ws: ws, admin: admin} do
      assert {:ok, [_ | _]} = Ash.read(Role, tenant: ws.id, actor: admin)
      assert {:ok, [_ | _]} = Ash.read(WorkspaceMembership, tenant: ws.id, actor: admin)
    end

    test "非 Owner 成员不可给他人分配角色(无 member:manage)", %{
      ws: ws,
      admin: admin
    } do
      user = TestFixtures.seed_user()

      {:ok, membership} =
        Ash.create(WorkspaceMembership, %{user_id: user.id}, tenant: ws.id, actor: admin)

      learner = role_by_name!(ws, "Learner")

      {:ok, _} =
        Ash.create(MembershipRole, %{membership_id: membership.id, role_id: learner.id},
          tenant: ws.id,
          actor: admin
        )

      # 现在 user(Learner) 尝试给第三个用户分配角色 → 403
      third = TestFixtures.seed_user()

      {:ok, m3} =
        Ash.create(WorkspaceMembership, %{user_id: third.id}, tenant: ws.id, actor: admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.create(MembershipRole, %{membership_id: m3.id, role_id: learner.id},
                 tenant: ws.id,
                 actor: user
               )
    end
  end
end
