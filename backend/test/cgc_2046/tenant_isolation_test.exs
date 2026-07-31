defmodule Cgc2046.TenantIsolationTest do
  @moduledoc """
  T03 切片A:多租户 attribute 策略隔离语义(Ash action 层)。

  对应验收标准:租户资源按 workspace_id 隔离(跨租户查不到数据)。

  租户资源(WorkspaceMembership 最小骨架,T04 扩展)声明
  `multitenancy strategy: :attribute, attribute: :workspace_id`;
  查询/写入必须显式 `tenant: <workspace_id>`,未指定 tenant 报错。
  """

  use Cgc2046.DataCase, async: true

  require Ash.Query

  alias Cgc2046.TestFixtures
  alias Cgc2046.Workspaces.{Workspace, WorkspaceMembership}

  describe "租户资源按 workspace_id 隔离" do
    test "两个 workspace 的 membership 互不可见" do
      admin = TestFixtures.seed_platform_admin()
      user_a = TestFixtures.seed_user()
      user_b = TestFixtures.seed_user()

      ws_a = TestFixtures.seed_workspace(slug: "iso-a", owner: admin)
      ws_b = TestFixtures.seed_workspace(slug: "iso-b", owner: admin)

      # T04 起 WorkspaceMembership 需租户权限 member:manage;admin 是 Owner
      # (seed_workspace 自动入会),可执行成员管理。无 actor 的裸创建已不再允许。
      {:ok, m_a} =
        Ash.create(WorkspaceMembership, %{user_id: user_a.id}, tenant: ws_a.id, actor: admin)

      {:ok, m_b} =
        Ash.create(WorkspaceMembership, %{user_id: user_b.id}, tenant: ws_b.id, actor: admin)

      # tenant ws_a 只见 ws_a 的 membership(含 admin 的 Owner 成员身份),
      # 不含 ws_b 的 membership
      assert {:ok, found_a} = Ash.read(WorkspaceMembership, tenant: ws_a.id, actor: admin)
      assert Enum.map(found_a, & &1.id) |> Enum.member?(m_a.id)
      refute Enum.map(found_a, & &1.id) |> Enum.member?(m_b.id)

      # tenant ws_b 只见 ws_b 的 membership
      assert {:ok, found_b} = Ash.read(WorkspaceMembership, tenant: ws_b.id, actor: admin)
      assert Enum.map(found_b, & &1.id) |> Enum.member?(m_b.id)
      refute Enum.map(found_b, & &1.id) |> Enum.member?(m_a.id)

      # 未指定 tenant → 报错(缺租户上下文)
      assert {:error, error} = Ash.read(WorkspaceMembership, actor: admin)
      assert Exception.message(error) =~ "tenant"
    end

    test "Workspace 是全局资源,不要求 tenant" do
      admin = TestFixtures.seed_platform_admin()
      ws = TestFixtures.seed_workspace(owner: admin)

      assert {:ok, [%Workspace{id: found_id}]} =
               Workspace
               |> Ash.Query.filter(id: ws.id)
               |> Ash.read(actor: admin)

      assert found_id == ws.id
    end
  end
end
