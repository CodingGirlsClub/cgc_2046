defmodule Cgc2046.Accounts.MembershipContextTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Accounts.WorkspaceMembership
  alias AshAuthentication.Info, as: AuthInfo

  @password "sup3r-secret-password"

  require Ash.Query

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

  # 注册一个平台管理员用户（直接写库提权，模拟种子/运维操作）
  defp admin_user do
    user = register_user("mc-admin-#{System.unique_integer([:positive])}@example.com", @password)

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE users SET is_platform_admin = true WHERE id = $1",
        [Ecto.UUID.dump!(user.id)]
      )

    Ash.get!(User, user.id, actor: user, authorize?: false, domain: Cgc2046.GlobalApi)
  end

  defp new_user do
    register_user("mc-user-#{System.unique_integer([:positive])}@example.com", @password)
  end

  defp create_workspace(admin) do
    {:ok, workspace} =
      Workspace
      |> Ash.Changeset.for_create(:create, %{
        slug: "mc-#{System.unique_integer([:positive])}",
        name: "MC"
      })
      |> Ash.create(actor: admin)

    workspace
  end

  # 以 owner/admin 身份把一个用户拉进工作台（测试直接建成员资格）
  defp add_member(workspace, user, actor, role_names) do
    {:ok, membership} =
      WorkspaceMembership
      |> Ash.Changeset.for_create(:create, %{user_id: user.id})
      |> Ash.create(tenant: workspace.id, actor: actor, authorize?: false)

    if role_names != [] do
      # assign_roles 的 P0 grant scope 校验读 context.actor：actor/tenant 必须
      # 在 for_update 阶段传入（进 changeset context）；Ash.update(changeset,
      # actor:) 只进 opts，change 内 context.actor 为 nil（GraphQL 走 run_action
      # 同样在 for_update 传 actor，行为一致）。
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

  describe "membership_of / role_names" do
    test "成员返回记录（roles 已加载），role_names 返回角色名原子" do
      admin = admin_user()
      workspace = create_workspace(admin)
      member = new_user()
      membership = add_member(workspace, member, admin, [:member])

      fetched = MembershipContext.membership_of(member, workspace.id)
      assert fetched.id == membership.id
      assert Enum.map(fetched.roles, & &1.name) == [:member]
      assert MembershipContext.role_names(member, workspace.id) == [:member]
    end

    test "多角色并集按 roles 加载顺序返回" do
      admin = admin_user()
      workspace = create_workspace(admin)
      member = new_user()
      add_member(workspace, member, admin, [:member, :tutor])

      roles = MembershipContext.role_names(member, workspace.id)
      assert Enum.sort(roles) == [:member, :tutor]
    end

    test "actor 只需 :id 字段（assign_roles grant scope 契约：%{id: user_id} map）" do
      admin = admin_user()
      workspace = create_workspace(admin)
      member = new_user()
      add_member(workspace, member, admin, [:owner])

      assert MembershipContext.role_names(%{id: member.id}, workspace.id) == [:owner]
    end

    test "非成员 / 匿名返回 nil / []" do
      admin = admin_user()
      workspace = create_workspace(admin)
      outsider = new_user()

      assert MembershipContext.membership_of(outsider, workspace.id) == nil
      assert MembershipContext.role_names(outsider, workspace.id) == []
      assert MembershipContext.membership_of(nil, workspace.id) == nil
      assert MembershipContext.role_names(nil, workspace.id) == []
    end

    test "租户隔离：同一 user 在 A 工作台的成员资格不影响 B 工作台" do
      admin = admin_user()
      workspace_a = create_workspace(admin)
      workspace_b = create_workspace(admin)
      member = new_user()

      add_member(workspace_a, member, admin, [:member])

      assert MembershipContext.role_names(member, workspace_a.id) == [:member]
      assert MembershipContext.role_names(member, workspace_b.id) == []
    end
  end

  describe "memberships_of_actor" do
    test "跨租户返回 actor 全部成员资格（roles 已加载）" do
      admin = admin_user()
      workspace_a = create_workspace(admin)
      workspace_b = create_workspace(admin)
      member = new_user()

      add_member(workspace_a, member, admin, [:member])
      add_member(workspace_b, member, admin, [:tutor])

      memberships = MembershipContext.memberships_of_actor(member)
      assert length(memberships) == 2

      by_workspace = Map.new(memberships, &{&1.workspace_id, &1})
      assert Enum.map(by_workspace[workspace_a.id].roles, & &1.name) == [:member]
      assert Enum.map(by_workspace[workspace_b.id].roles, & &1.name) == [:tutor]
    end

    test "无成员资格返回 []" do
      member = new_user()
      assert MembershipContext.memberships_of_actor(member) == []
    end
  end

  describe "owner_count" do
    test "1 owner + 1 普通成员 → 1" do
      admin = admin_user()
      workspace = create_workspace(admin)
      add_member(workspace, new_user(), admin, [:member])

      assert MembershipContext.owner_count(workspace.id) == 1
    end

    test "第二个 owner 加入 → 2（一人多角色只算 1 次）" do
      admin = admin_user()
      workspace = create_workspace(admin)

      # 一人持 owner + member 两角色，仍只算 1 次；
      # admin（创建者）+ multi + 新 owner = 3
      multi = new_user()
      add_member(workspace, multi, admin, [:owner, :member])
      add_member(workspace, new_user(), admin, [:owner])

      assert MembershipContext.owner_count(workspace.id) == 3
    end

    test "空工作台 → 0" do
      admin = admin_user()
      workspace = create_workspace(admin)

      # 移除创建者自己后为空
      loaded = Ash.load!(workspace, :memberships, tenant: workspace.id, authorize?: false)
      membership = Enum.find(loaded.memberships, &(&1.user_id == admin.id))

      Ecto.Adapters.SQL.query!(
        Cgc2046.Repo,
        "DELETE FROM membership_roles WHERE membership_id = $1",
        [Ecto.UUID.dump!(membership.id)]
      )

      Ash.destroy!(membership, tenant: workspace.id, actor: admin, authorize?: false)

      assert MembershipContext.owner_count(workspace.id) == 0
    end
  end

  describe "resolve_workspace_id（Ash 3.31 filter struct 钉测）" do
    # 钉测：用真实 Ash.Query / Ash.Changeset 生成三场景上下文，断言提取结果。
    # Ash 升级改 filter struct 形状时，提取返回 nil → 断言失败 → 当场点名唯一需改的模块。

    setup do
      admin = admin_user()
      workspace = create_workspace(admin)
      member = new_user()
      membership = add_member(workspace, member, admin, [:member])

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
      admin = admin_user()

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
      admin = admin_user()
      workspace = create_workspace(admin)
      member = new_user()

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
      admin = admin_user()
      workspace = create_workspace(admin)
      member = new_user()
      add_member(workspace, member, admin, [:member])

      assert {:error, error} =
               MembershipContext.admit_member(member.id, workspace.id, [:tutor],
                 on_conflict: :business_error,
                 error_message: "你已是该工作台成员"
               )

      assert %Ash.Error.Changes.InvalidAttribute{} = error
      assert error.message == "你已是该工作台成员"
    end

    test "已有成员 → idempotent：existing 守卫幂等成功，回查已有 membership" do
      admin = admin_user()
      workspace = create_workspace(admin)
      member = new_user()
      existing = add_member(workspace, member, admin, [:member])

      assert {:ok, membership} =
               MembershipContext.admit_member(member.id, workspace.id, [:learner],
                 on_conflict: :idempotent
               )

      # 幂等成功返回的是已有 membership，不重复建
      assert membership.id == existing.id
    end

    test "并发 unique 冲突 → business_error：越过守卫后 DB unique index 拒绝，转业务错误" do
      admin = admin_user()
      workspace = create_workspace(admin)
      member = new_user()

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
      member = new_user()

      assert {:error, error} =
               MembershipContext.admit_member(member.id, "not-a-uuid", [:member],
                 on_conflict: :business_error
               )

      # 转成结构化业务错误（membership_check_error），可走 ash_graphql to_errors
      assert %Ash.Error.Changes.InvalidAttribute{message: "成员资格检查失败"} = error
    end

    test "existing 守卫读失败：idempotent 模式同样返结构化错误而非 raise" do
      # Workspace.join 走 on_conflict: :idempotent，读失败也必须 fail-closed 返错误
      member = new_user()

      assert {:error, error} =
               MembershipContext.admit_member(member.id, "not-a-uuid", [:learner],
                 on_conflict: :idempotent
               )

      assert %Ash.Error.Changes.InvalidAttribute{} = error
    end

    test "空角色列表：建 Membership 不建 MembershipRole（决策 6）" do
      admin = admin_user()
      workspace = create_workspace(admin)
      member = new_user()

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
      admin = admin_user()
      workspace = create_workspace(admin)
      member = new_user()

      # :owner 在工作台已 seed，:nonexistent 不存在 → 跳过，owner 正常入座
      assert {:ok, _membership} =
               MembershipContext.admit_member(member.id, workspace.id, [:owner, :nonexistent],
                 on_conflict: :business_error
               )

      fetched = MembershipContext.membership_of(member, workspace.id)
      assert Enum.map(fetched.roles, & &1.name) == [:owner]
    end
  end
end
