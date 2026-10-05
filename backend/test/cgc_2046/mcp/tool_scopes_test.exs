defmodule Cgc2046.Mcp.ToolScopesTest do
  @moduledoc """
  MCP 工具可见性分层的结构守卫与 scope 计算（#1085，ADR-0021）。

  - 分层名单：每个工具的 `scopes:` 声明必须与 `Cgc2046.McpToolTiers` 人工钉死的名单逐名一致；
    新增工具不归层则红（anubis 默认「不声明 scope = 全员可见」，漏标不会自己报错）；
  - `meta: %{membership: :platform_admin}` ⇔ `scopes: ["platform_admin"]`：两套声明不得漂移；
  - 钩子旁路面：Server 不得声明 `tasks` capability（task 增强的 tools/call 不经
    `Server.handle_request/2`，会绕过 scope 注入）；
  - `Scopes.granted/1`：scope 是**跨工作台并集**，平台管理员级联拿全部三个 scope。

  端到端行为（真实 `/mcp` 入口的可见面 / 拒绝 / 审计）见 `mcp_tool_visibility_test.exs`。
  """
  use Cgc2046.DataCase, async: true

  import ExUnit.CaptureLog

  alias Cgc2046.Accounts.{MembershipContext, Rbac}
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Mcp.{Scopes, Server}
  alias Cgc2046.McpToolTiers, as: Tiers

  defp tools, do: Server.__components__(:tool)

  defp names_with_scopes(scopes) do
    for(%{name: name, scopes: ^scopes} <- tools(), do: name) |> Enum.sort()
  end

  describe "分层名单精确钉死（新增工具必须显式归层）" do
    test "四个名单两两互斥，并集 = 全部注册工具（100）" do
      lists = [
        Tiers.all_visible(),
        Tiers.tutor(),
        Tiers.workspace_admin(),
        Tiers.platform_admin()
      ]

      all = List.flatten(lists)

      assert length(all) == length(Enum.uniq(all)), "名单有重复归层的工具"
      assert Enum.sort(all) == tools() |> Enum.map(& &1.name) |> Enum.sort()
      assert length(all) == 100
      assert Enum.map(lists, &length/1) == [34, 4, 34, 28]
    end

    test "scopes: [] = 全员可见名单" do
      assert names_with_scopes([]) == Tiers.all_visible()
    end

    test "scopes: [\"tutor\"] = tutor 层名单" do
      assert names_with_scopes(["tutor"]) == Tiers.tutor()
    end

    test "scopes: [\"workspace_admin\"] = Owner/Admin 层名单" do
      assert names_with_scopes(["workspace_admin"]) == Tiers.workspace_admin()
    end

    test "scopes: [\"platform_admin\"] = 平台治理层名单" do
      assert names_with_scopes(["platform_admin"]) == Tiers.platform_admin()
    end

    test "scope 词汇表封闭：只允许空或单个已知层名（防拼写漂移悄悄变成全员不可见）" do
      allowed = [[], ["tutor"], ["workspace_admin"], ["platform_admin"]]

      for %{name: name, scopes: scopes} <- tools() do
        assert scopes in allowed, "#{name} 声明了未知 scopes: #{inspect(scopes)}"
      end
    end
  end

  describe "两套声明不漂移" do
    test "meta: %{membership: :platform_admin} ⇔ scopes: [\"platform_admin\"]" do
      by_meta =
        for(%{name: name, meta: %{membership: :platform_admin}} <- tools(), do: name)
        |> Enum.sort()

      assert by_meta == names_with_scopes(["platform_admin"])
    end
  end

  describe "钩子旁路面" do
    test "Server 不声明 tasks capability（task 增强路径不经 handle_request/2，会绕过 scope 注入）" do
      refute Map.has_key?(Server.server_capabilities(), "tasks")
    end
  end

  describe "Scopes.granted/1：跨工作台并集 + 平台管理员级联" do
    test "nil → []" do
      assert Scopes.granted(nil) == []
    end

    test "无成员资格 / 无角色 / learner / volunteer → []（只见全员可见名单）" do
      %{workspace: workspace} = Fixtures.workspace_with_member()
      orphan = Fixtures.register_user("scopes-orphan")

      assert Scopes.granted(orphan) == []

      for roles <- [[], [:learner], [:volunteer], [:learner, :volunteer]] do
        user = Fixtures.register_user("scopes-plain")
        Fixtures.add_member(workspace, user, roles)
        assert Scopes.granted(user) == [], "roles=#{inspect(roles)} 不该拿到任何 scope"
      end
    end

    test "tutor → [\"tutor\"]" do
      %{workspace: workspace} = Fixtures.workspace_with_member()
      tutor = Fixtures.register_user("scopes-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])

      assert Scopes.granted(tutor) == ["tutor"]
    end

    test "Owner / Admin → [\"tutor\", \"workspace_admin\"]（管理角色并入 tutor 层）" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      admin = Fixtures.register_user("scopes-admin")
      Fixtures.add_member(workspace, admin, [:admin])

      assert Scopes.granted(owner) == ["tutor", "workspace_admin"]
      assert Scopes.granted(admin) == ["tutor", "workspace_admin"]
    end

    test "跨工作台并集：A 台是学员、B 台是 Admin → 拿管理层（具体哪个台仍由 Wrapper 判定）" do
      %{workspace: workspace_a} = Fixtures.workspace_with_member()
      %{workspace: workspace_b} = Fixtures.workspace_with_member()
      user = Fixtures.register_user("scopes-union")
      Fixtures.add_member(workspace_a, user, [:learner])
      Fixtures.add_member(workspace_b, user, [:admin])

      assert Scopes.granted(user) == ["tutor", "workspace_admin"]
    end

    test "平台管理员（不属于任何工作台）级联拿全部三个 scope" do
      admin = Fixtures.platform_admin("scopes-platform")

      assert Scopes.granted(admin) == ["tutor", "workspace_admin", "platform_admin"]
    end

    test "成员资格读取失败 → fail-closed 为 []（不抛、不放行）" do
      # 非 UUID 的 id 让 Ash 读取抛错，走 rescue 分支
      log = capture_log(fn -> assert Scopes.granted(%{id: "not-a-uuid"}) == [] end)

      assert log =~ "[Mcp.Scopes]"
    end
  end

  describe "层级判别词表 vs Rbac 判定（防两处独立推导再漂移）" do
    test "scope 层级判别词与 Rbac 词表完全同源" do
      assert Scopes.scope_role_names() == Enum.sort(Rbac.workspace_manage_roles())
      assert Scopes.scope_tutor_role_names() == Enum.sort(Rbac.staff_roles())
    end

    test "granted 层级与 Rbac.staff?/manage?/member 一致（单工作台）" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      tutor = Fixtures.register_user("parity-tutor")
      admin = Fixtures.register_user("parity-admin")
      learner = Fixtures.register_user("parity-learner")
      volunteer = Fixtures.register_user("parity-volunteer")
      plain = Fixtures.register_user("parity-plain")

      Fixtures.add_member(workspace, tutor, [:tutor])
      Fixtures.add_member(workspace, admin, [:admin])
      Fixtures.add_member(workspace, learner, [:learner])
      Fixtures.add_member(workspace, volunteer, [:volunteer])
      Fixtures.add_member(workspace, plain, [])

      # granted 判定（跨工作台 union，本测试工作台与 Rbac 同义）
      for {user, expect_tutor, expect_manage} <- [
            {owner, true, true},
            {admin, true, true},
            {tutor, true, false},
            {learner, false, false},
            {volunteer, false, false},
            {plain, false, false}
          ] do
        scopes = Scopes.granted(user)
        assert "tutor" in scopes == expect_tutor
        assert "workspace_admin" in scopes == expect_manage

        assert Rbac.staff?(user, workspace.id) == expect_tutor or expect_manage
        assert Rbac.manage?(user, workspace.id) == expect_manage
        assert MembershipContext.membership_of(user, workspace.id) != nil
      end
    end
  end
end
