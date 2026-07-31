defmodule Cgc2046.RoleDefaultTemplateTest do
  @moduledoc """
  T04 切片A:新 Workspace 自动生成默认角色模板。

  对应验收标准:新 Workspace 自动生成默认角色模板
  (Owner/Admin/Tutor/Volunteer/Learner)。

  额外锁定 Owner 语义:平台管理员创建 Workspace 时指定 Owner,Owner
  自动成为成员并获得 Owner 角色(否则 Owner 无法管理成员/访问租户资源)。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.TestFixtures
  alias Cgc2046.Workspaces.{Role, WorkspaceMembership}

  @default_role_names ~w(Owner Admin Tutor Volunteer Learner)

  defp role_names(workspace) do
    {:ok, roles} = Ash.read(Role, tenant: workspace.id, authorize?: false)
    Enum.map(roles, & &1.name) |> Enum.sort()
  end

  defp role_by_name!(workspace, name) do
    {:ok, roles} = Ash.read(Role, tenant: workspace.id, authorize?: false)

    Enum.find(roles, fn role -> role.name == name end) ||
      raise "角色 #{name} 未生成"
  end

  describe "新 Workspace 自动生成默认角色模板" do
    test "创建后生成 Owner/Admin/Tutor/Volunteer/Learner 五个角色" do
      admin = TestFixtures.seed_platform_admin()
      ws = TestFixtures.seed_workspace(owner: admin)

      assert role_names(ws) == @default_role_names |> Enum.sort()
    end

    test "每个 Workspace 有独立模板(互不串扰)" do
      admin = TestFixtures.seed_platform_admin()
      ws_a = TestFixtures.seed_workspace(slug: "tpl-a", owner: admin)
      ws_b = TestFixtures.seed_workspace(slug: "tpl-b", owner: admin)

      assert role_names(ws_a) == @default_role_names |> Enum.sort()
      assert role_names(ws_b) == @default_role_names |> Enum.sort()

      # 各自的角色 id 不同(租户内实体)
      {:ok, roles_a} = Ash.read(Role, tenant: ws_a.id, authorize?: false)
      {:ok, roles_b} = Ash.read(Role, tenant: ws_b.id, authorize?: false)
      assert Enum.map(roles_a, & &1.id) != Enum.map(roles_b, & &1.id)
    end

    test "默认角色按 spec 权限矩阵携带权限集" do
      admin = TestFixtures.seed_platform_admin()
      ws = TestFixtures.seed_workspace(owner: admin)

      owner = role_by_name!(ws, "Owner")
      admin_role = role_by_name!(ws, "Admin")
      tutor = role_by_name!(ws, "Tutor")
      volunteer = role_by_name!(ws, "Volunteer")
      learner = role_by_name!(ws, "Learner")

      # 权限矩阵(见 docs/spec §4):
      # 创建/部署 Workflow = Owner/Admin/Tutor;邀请 = Owner/Admin/Volunteer
      # 成员管理 = Owner/Admin;角色管理/审计 = Owner
      assert "workflow:create" in owner.permissions
      assert "workflow:deploy" in owner.permissions
      assert "member:manage" in owner.permissions

      assert "member:manage" in admin_role.permissions
      refute "role:manage" in admin_role.permissions

      assert "workflow:create" in tutor.permissions
      assert "invitation:create" in tutor.permissions

      refute "workflow:create" in volunteer.permissions
      assert "invitation:create" in volunteer.permissions

      refute "workflow:create" in learner.permissions
      refute "invitation:create" in learner.permissions
    end
  end

  describe "Owner 自动成为成员并获得 Owner 角色" do
    test "创建 Workspace 后 Owner 自动成为成员,角色为 Owner" do
      admin = TestFixtures.seed_platform_admin()
      ws = TestFixtures.seed_workspace(owner: admin)

      {:ok, memberships} =
        Ash.read(WorkspaceMembership, tenant: ws.id, authorize?: false, load: [:roles])

      assert [membership] = memberships
      assert membership.user_id == admin.id

      assert Enum.map(membership.roles, & &1.name) == ["Owner"]
    end

    test "Owner 角色来自默认模板中的 Owner" do
      admin = TestFixtures.seed_platform_admin()
      ws = TestFixtures.seed_workspace(owner: admin)

      owner_role = role_by_name!(ws, "Owner")

      {:ok, memberships} =
        Ash.read(WorkspaceMembership, tenant: ws.id, authorize?: false, load: [:roles])

      assert [membership] = memberships
      assert Enum.map(membership.roles, & &1.id) == [owner_role.id]
    end
  end
end
