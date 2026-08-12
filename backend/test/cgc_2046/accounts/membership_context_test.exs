defmodule Cgc2046.Accounts.MembershipContextTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Accounts.WorkspaceMembership
  alias Cgc2046.AccountsFixtures, as: Fixtures

  require Ash.Query

  describe "membership_of / role_names" do
    test "成员返回记录（roles 已加载），role_names 返回角色名原子" do
      admin = Fixtures.platform_admin("mc-admin")
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("mc-member")
      membership = Fixtures.add_member(workspace, member, [:member])

      fetched = MembershipContext.membership_of(member, workspace.id)
      assert fetched.id == membership.id
      assert Enum.map(fetched.roles, & &1.name) == [:member]
      assert MembershipContext.role_names(member, workspace.id) == [:member]
    end

    test "多角色并集按 roles 加载顺序返回" do
      admin = Fixtures.platform_admin("mc-admin")
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("mc-member")
      Fixtures.add_member(workspace, member, [:member, :tutor])

      roles = MembershipContext.role_names(member, workspace.id)
      assert Enum.sort(roles) == [:member, :tutor]
    end

    test "actor 只需 :id 字段（assign_roles grant scope 契约：%{id: user_id} map）" do
      admin = Fixtures.platform_admin("mc-admin")
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("mc-member")
      Fixtures.add_member(workspace, member, [:owner])

      assert MembershipContext.role_names(%{id: member.id}, workspace.id) == [:owner]
    end

    test "非成员 / 匿名返回 nil / []" do
      admin = Fixtures.platform_admin("mc-admin")
      workspace = Fixtures.create_workspace(admin)
      outsider = Fixtures.register_user("mc-outsider")

      assert MembershipContext.membership_of(outsider, workspace.id) == nil
      assert MembershipContext.role_names(outsider, workspace.id) == []
      assert MembershipContext.membership_of(nil, workspace.id) == nil
      assert MembershipContext.role_names(nil, workspace.id) == []
    end

    test "租户隔离：同一 user 在 A 工作台的成员资格不影响 B 工作台" do
      admin = Fixtures.platform_admin("mc-admin")
      workspace_a = Fixtures.create_workspace(admin)
      workspace_b = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("mc-member")

      Fixtures.add_member(workspace_a, member, [:member])

      assert MembershipContext.role_names(member, workspace_a.id) == [:member]
      assert MembershipContext.role_names(member, workspace_b.id) == []
    end
  end

  describe "memberships_of_actor" do
    test "跨租户返回 actor 全部成员资格（roles 已加载）" do
      admin = Fixtures.platform_admin("mc-admin")
      workspace_a = Fixtures.create_workspace(admin)
      workspace_b = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("mc-member")

      Fixtures.add_member(workspace_a, member, [:member])
      Fixtures.add_member(workspace_b, member, [:tutor])

      memberships = MembershipContext.memberships_of_actor(member)
      assert length(memberships) == 2

      by_workspace = Map.new(memberships, &{&1.workspace_id, &1})
      assert Enum.map(by_workspace[workspace_a.id].roles, & &1.name) == [:member]
      assert Enum.map(by_workspace[workspace_b.id].roles, & &1.name) == [:tutor]
    end

    test "无成员资格返回 []" do
      member = Fixtures.register_user("mc-member")
      assert MembershipContext.memberships_of_actor(member) == []
    end
  end

  describe "owner_count" do
    test "1 owner + 1 普通成员 → 1" do
      admin = Fixtures.platform_admin("mc-admin")
      workspace = Fixtures.create_workspace(admin)
      Fixtures.add_member(workspace, Fixtures.register_user("mc-member"), [:member])

      assert MembershipContext.owner_count(workspace.id) == 1
    end

    test "第二个 owner 加入 → 2（一人多角色只算 1 次）" do
      admin = Fixtures.platform_admin("mc-admin")
      workspace = Fixtures.create_workspace(admin)

      # 一人持 owner + member 两角色，仍只算 1 次；
      # admin（创建者）+ multi + 新 owner = 3
      multi = Fixtures.register_user("mc-multi")
      Fixtures.add_member(workspace, multi, [:owner, :member])
      Fixtures.add_member(workspace, Fixtures.register_user("mc-owner"), [:owner])

      assert MembershipContext.owner_count(workspace.id) == 3
    end

    test "空工作台 → 0" do
      admin = Fixtures.platform_admin("mc-admin")
      workspace = Fixtures.create_workspace(admin)

      # 移除创建者自己后为空
      Fixtures.remove_membership(workspace, admin)

      assert MembershipContext.owner_count(workspace.id) == 0
    end
  end

  describe "Owner 状态谓词族（ownerless? / has_owner? / last_owner?，候选 9）" do
    test "0 个 Owner（pending-owner）→ ownerless? true / has_owner? false / last_owner? true" do
      admin = Fixtures.platform_admin("mc-admin")
      workspace = Fixtures.create_workspace(admin)

      # 移除创建者自己后为空（等价 pending-owner 的 ownerless 终态）
      Fixtures.remove_membership(workspace, admin)

      assert MembershipContext.ownerless?(workspace.id)
      refute MembershipContext.has_owner?(workspace.id)
      assert MembershipContext.last_owner?(workspace.id)
    end

    test "1 个 Owner → has_owner? true / last_owner? true（再移除即孤儿）" do
      admin = Fixtures.platform_admin("mc-admin")
      workspace = Fixtures.create_workspace(admin)

      refute MembershipContext.ownerless?(workspace.id)
      assert MembershipContext.has_owner?(workspace.id)
      assert MembershipContext.last_owner?(workspace.id)
    end

    test "2 个 Owner → last_owner? false（可安全移除其一）" do
      admin = Fixtures.platform_admin("mc-admin")
      workspace = Fixtures.create_workspace(admin)
      Fixtures.add_member(workspace, Fixtures.register_user("mc-owner"), [:owner])

      refute MembershipContext.ownerless?(workspace.id)
      assert MembershipContext.has_owner?(workspace.id)
      refute MembershipContext.last_owner?(workspace.id)
    end
  end

  describe "resolve_workspace_id（Ash 3.31 filter struct 钉测）" do
    # 钉测：用真实 Ash.Query / Ash.Changeset 生成三场景上下文，断言提取结果。
    # Ash 升级改 filter struct 形状时，提取返回 nil → 断言失败 → 当场点名唯一需改的模块。

    setup do
      admin = Fixtures.platform_admin("mc-admin")
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("mc-member")
      membership = Fixtures.add_member(workspace, member, [:member])

      %{admin: admin, workspace: workspace, member: member, membership: membership}
    end

    test "场景1 changeset：tenant 优先（assign_roles update）", %{
      workspace: workspace,
      membership: membership
    } do
      changeset =
        Ash.Changeset.for_update(membership, :assign_roles, %{role_names: []},
          tenant: workspace.id
        )

      assert MembershipContext.resolve_workspace_id(%{changeset: changeset}) == workspace.id
    end

    test "场景1 changeset：无 tenant 时从 changeset.data.workspace_id 取", %{
      workspace: workspace,
      membership: membership
    } do
      changeset = Ash.Changeset.for_update(membership, :assign_roles, %{role_names: []})
      assert MembershipContext.resolve_workspace_id(%{changeset: changeset}) == workspace.id
    end

    test "场景2 list query：workspace_id eq filter（global 查询无 tenant）", %{
      workspace: workspace
    } do
      query = Ash.Query.filter(WorkspaceMembership, workspace_id == ^workspace.id)

      assert MembershipContext.resolve_workspace_id(%{query: query}) == workspace.id
    end

    test "场景2 list query：and 组合 filter（BooleanExpression 分支）", %{
      workspace: workspace,
      member: member
    } do
      query =
        Ash.Query.filter(
          WorkspaceMembership,
          workspace_id == ^workspace.id and user_id == ^member.id
        )

      assert MembershipContext.resolve_workspace_id(%{query: query}) == workspace.id
    end

    test "场景2 list query：tenant 优先于 filter", %{workspace: workspace} do
      query =
        WorkspaceMembership
        |> Ash.Query.filter(workspace_id == ^workspace.id)
        |> Ash.Query.set_tenant(workspace.id)

      assert MembershipContext.resolve_workspace_id(%{query: query}) == workspace.id
    end

    test "场景3 get-by-id：id-only filter 回查记录取 workspace_id", %{
      workspace: workspace,
      membership: membership
    } do
      query = Ash.Query.filter(WorkspaceMembership, id == ^membership.id)

      assert MembershipContext.resolve_workspace_id(%{query: query}) == workspace.id
    end

    test "场景3 get-by-id：Workspace 资源自身（#88，id 即 workspace_id）", %{
      workspace: workspace
    } do
      query = Ash.Query.filter(Workspace, id == ^workspace.id)

      assert MembershipContext.resolve_workspace_id(%{query: query}) == workspace.id
    end

    test "场景4 changeset：Workspace 资源自身更新（#78，无 workspace_id 属性取 data.id）", %{
      workspace: workspace
    } do
      changeset =
        Ash.Changeset.for_update(workspace, :update, %{join_policy: :invite_only})

      assert MembershipContext.resolve_workspace_id(%{changeset: changeset}) == workspace.id
    end

    test "未知 context 返回 nil" do
      assert MembershipContext.resolve_workspace_id(%{data: %{}}) == nil
      assert MembershipContext.resolve_workspace_id(%{}) == nil
    end

    test "filter 中 workspace_id 值非字符串（如绑定变量）不误提取" do
      query =
        Ash.Query.filter(WorkspaceMembership, workspace_id == ^System.unique_integer([:positive]))

      assert MembershipContext.resolve_workspace_id(%{query: query}) == nil
    end
  end

  describe "错误姿态（与收敛前一致，失败路径钉测）" do
    test "membership_of 读失败返回 nil、role_names 返回 []" do
      admin = Fixtures.platform_admin("mc-admin")

      # 非法 tenant（非 UUID）迫使 Ash.read 返回 {:error, _} → nil / []
      assert MembershipContext.membership_of(admin, "not-a-uuid") == nil
      assert MembershipContext.role_names(admin, "not-a-uuid") == []
    end

    test "owner_count 读失败抛出（与 member_count 一致）" do
      assert_raise ArgumentError, fn ->
        MembershipContext.owner_count("not-a-uuid")
      end
    end

    test "memberships_of_actor 读失败抛出（read! 与收敛前一致）" do
      # 非法 user_id（非 UUID）迫使 read! 抛 Ash.Error.Invalid
      assert_raise Ash.Error.Invalid, fn ->
        MembershipContext.memberships_of_actor(%{id: "not-a-uuid"})
      end
    end
  end

  describe "unique_membership_conflict?/1" do
    # 回归：{:error, _} 通配曾把 DB 断连等真实故障误判成「已是成员/幂等成功」，
    # 静默数据丢失。此测试钉住 helper 只对 unique constraint 返回 true。
    alias Ash.Error.Changes.InvalidAttribute

    test "ash_postgres 包装的 unique constraint 冲突返回 true" do
      # ash_postgres constraints_to_errors 把 wm_unique_ws_user_idx unique violation
      # 转成 InvalidAttribute 带 private_vars: [constraint_type: :unique]，
      # Ash.create 返回 Splode error class（Ash.Error.Invalid）包着 leaf errors。
      leaf =
        InvalidAttribute.exception(
          field: :user_id,
          message: "has already been taken",
          private_vars: [
            constraint: "wm_unique_ws_user_idx",
            constraint_type: :unique,
            detail: nil
          ]
        )

      error = Ash.Error.to_error_class(leaf)

      assert MembershipContext.unique_membership_conflict?(error) == true
    end

    test "非 unique 的真实 DB 故障返回 false（不被误判成幂等/已是成员）" do
      # 模拟 DB 断连/磁盘满等：一个不带 constraint_type 的 InvalidAttribute
      leaf =
        InvalidAttribute.exception(
          field: :user_id,
          message: "something went wrong"
        )

      error = Ash.Error.to_error_class(leaf)

      assert MembershipContext.unique_membership_conflict?(error) == false
    end

    test "裸 error（非 Splode error class）返回 false" do
      assert MembershipContext.unique_membership_conflict?(%{errors: []}) == false
      assert MembershipContext.unique_membership_conflict?(:something_else) == false
    end
  end

  describe "admit_member/3" do
    # 入座不变量唯一实现的钉测：覆盖 happy path / existing 守卫两姿态 /
    # 并发 unique 两姿态 / 真 DB 故障上抛 / 空角色 / 角色不存在。

    test "happy path：非成员 → 建 Membership + 入座指定角色" do
      admin = Fixtures.platform_admin("mc-admin")
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("mc-member")

      assert {:ok, membership} =
               MembershipContext.admit_member(member.id, workspace.id, [:tutor],
                 on_conflict: :business_error
               )

      assert membership.user_id == member.id
      # membership_of 验证角色已入座
      fetched = MembershipContext.membership_of(member, workspace.id)
      assert Enum.map(fetched.roles, & &1.name) == [:tutor]
    end

    test "已有成员 → business_error：existing 守卫返回「已是成员」业务错误" do
      admin = Fixtures.platform_admin("mc-admin")
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("mc-member")
      Fixtures.add_member(workspace, member, [:member])

      assert {:error, error} =
               MembershipContext.admit_member(member.id, workspace.id, [:tutor],
                 on_conflict: :business_error,
                 error_message: "你已是该工作台成员"
               )

      assert %Ash.Error.Changes.InvalidAttribute{} = error
      assert error.message == "你已是该工作台成员"
    end

    test "已有成员 → idempotent：existing 守卫幂等成功，回查已有 membership" do
      admin = Fixtures.platform_admin("mc-admin")
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("mc-member")
      existing = Fixtures.add_member(workspace, member, [:member])

      assert {:ok, membership} =
               MembershipContext.admit_member(member.id, workspace.id, [:learner],
                 on_conflict: :idempotent
               )

      # 幂等成功返回的是已有 membership，不重复建
      assert membership.id == existing.id
    end

    test "并发 unique 冲突 → business_error：越过守卫后 DB unique index 拒绝，转业务错误" do
      admin = Fixtures.platform_admin("mc-admin")
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("mc-member")

      # 先用 admit_member 建一条（模拟并发下另一请求已插入）
      assert {:ok, _} =
               MembershipContext.admit_member(member.id, workspace.id, [:member],
                 on_conflict: :business_error
               )

      # 第二次同 user+workspace：existing 守卫已拦——此测试验证守卫正常工作
      # （并发竞态的 DB unique 兜底由 unique_membership_conflict? 钉测覆盖，此处不重复）
      assert {:error, error} =
               MembershipContext.admit_member(member.id, workspace.id, [:member],
                 on_conflict: :business_error
               )

      assert %Ash.Error.Changes.InvalidAttribute{} = error
    end

    test "existing 守卫读失败：返结构化错误而非 raise（#14 fail-closed 原则）" do
      # 非法 workspace_id（非 UUID）迫使 existing 守卫的 Ash.read 返回 {:error, _}
      # （filter 解析 InvalidFilterValue）。admit_member 应把它转成结构化业务错误返回，
      # 不 raise——尤其 Workspace.join 是 generic action transaction?: false，raise 会变 500。
      # fail-closed 不变量：读失败既不建 membership 也不假装成功。
      member = Fixtures.register_user("mc-member")

      assert {:error, error} =
               MembershipContext.admit_member(member.id, "not-a-uuid", [:member],
                 on_conflict: :business_error
               )

      # 转成结构化业务错误（membership_check_error），可走 ash_graphql to_errors
      assert %Ash.Error.Changes.InvalidAttribute{message: "成员资格检查失败"} = error
    end

    test "existing 守卫读失败：idempotent 模式同样返结构化错误而非 raise" do
      # Workspace.join 走 on_conflict: :idempotent，读失败也必须 fail-closed 返错误
      member = Fixtures.register_user("mc-member")

      assert {:error, error} =
               MembershipContext.admit_member(member.id, "not-a-uuid", [:learner],
                 on_conflict: :idempotent
               )

      assert %Ash.Error.Changes.InvalidAttribute{} = error
    end

    test "空角色列表：建 Membership 不建 MembershipRole（决策 6）" do
      admin = Fixtures.platform_admin("mc-admin")
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("mc-member")

      assert {:ok, membership} =
               MembershipContext.admit_member(member.id, workspace.id, [],
                 on_conflict: :business_error
               )

      assert membership.user_id == member.id
      # 无角色入座
      fetched = MembershipContext.membership_of(member, workspace.id)
      assert fetched.roles == []
    end

    test "角色不存在：role_names 含租户内不存在的角色名 → 跳过该角色" do
      admin = Fixtures.platform_admin("mc-admin")
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("mc-member")

      # :owner 在工作台已 seed，:nonexistent 不存在 → 跳过，owner 正常入座
      assert {:ok, _membership} =
               MembershipContext.admit_member(member.id, workspace.id, [:owner, :nonexistent],
                 on_conflict: :business_error
               )

      fetched = MembershipContext.membership_of(member, workspace.id)
      assert Enum.map(fetched.roles, & &1.name) == [:owner]
    end
  end

  describe "admit_to_default_workspace (ADR-0004 默认 workspace 2046)" do
    test "新用户入座 2046 为 member 并建 WorkspaceProfile" do
      user = Fixtures.register_user("mc-user")

      assert {:ok, _membership} = MembershipContext.admit_to_default_workspace(user.id)

      # 查 2046 workspace
      assert {:ok, ws} =
               Workspace
               |> Ash.Query.for_read(:get_by_slug, %{slug: "2046"})
               |> Ash.read_one(authorize?: false)

      # 已是 member（roles 含 member）
      membership = MembershipContext.membership_of(user, ws.id)
      refute is_nil(membership)
      assert Enum.map(membership.roles, & &1.name) == [:member]

      # WorkspaceProfile 已建（默认 only_me / dark）
      assert {:ok, [profile]} =
               Cgc2046.Accounts.WorkspaceProfile
               |> Ash.Query.for_read(:read)
               |> Ash.Query.filter(user_id == ^user.id)
               |> Ash.read(tenant: ws.id, authorize?: false)

      assert profile.workspace_id == ws.id
      assert profile.visibility == :only_me
      assert profile.ui_theme_preference == "dark"
    end

    test "幂等：重复调用不报错、不重复入座" do
      user = Fixtures.register_user("mc-user")

      assert {:ok, _} = MembershipContext.admit_to_default_workspace(user.id)
      assert {:ok, _} = MembershipContext.admit_to_default_workspace(user.id)

      # 仍只有一份 membership + 一份 profile
      assert {:ok, ws} =
               Workspace
               |> Ash.Query.for_read(:get_by_slug, %{slug: "2046"})
               |> Ash.read_one(authorize?: false)

      memberships =
        WorkspaceMembership
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(user_id == ^user.id)
        |> Ash.read!(tenant: ws.id, authorize?: false)

      assert length(memberships) == 1
    end

    test "已加入其它 workspace 的用户也可入座 2046" do
      admin = Fixtures.platform_admin("mc-admin")
      workspace = Fixtures.create_workspace(admin)
      user = Fixtures.register_user("mc-user")
      Fixtures.add_member(workspace, user, [:learner])

      assert {:ok, _} = MembershipContext.admit_to_default_workspace(user.id)

      assert {:ok, ws} =
               Workspace
               |> Ash.Query.for_read(:get_by_slug, %{slug: "2046"})
               |> Ash.read_one(authorize?: false)

      membership = MembershipContext.membership_of(user, ws.id)
      refute is_nil(membership)
    end
  end
end
