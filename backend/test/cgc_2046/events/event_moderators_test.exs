defmodule Cgc2046.Events.EventModeratorsTest do
  use Cgc2046Web.ConnCase, async: true

  require Ash.Query
  alias Cgc2046.Notifications.NotificationDelivery
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Events.{Event, EventModerator, Moderators}
  alias Cgc2046.EventsFixtures

  require Ash.Query

  test "creator is assigned by event create; member assign/remove round-trip" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    user = Fixtures.register_user("moderator")
    Fixtures.add_member(workspace, user, [:learner])
    event = EventsFixtures.create_event(workspace, owner)

    # The fixture uses the authenticated creator; creator assignment is observable
    # through the real EventModerator resource.
    assert {:ok, moderators} = Moderators.list(event.id, workspace.id, owner)
    assert Enum.any?(moderators, &(&1.user_id == owner.id))

    assert {:ok, assigned} = Moderators.assign(event.id, workspace.id, user.id, owner)
    assert assigned.user_id == user.id
    assert Moderators.moderator?(user.id, event.id, workspace.id)

    assert {:error, :forbidden} = Moderators.assign(event.id, workspace.id, owner.id, user)

    # 撤权走域唯一入口（GraphQL/MCP 共用 Moderators.remove，U7 AE8）
    assert :ok = Moderators.remove(assigned.id, workspace.id, owner)

    refute Moderators.moderator?(user.id, event.id, workspace.id)
    assert Ash.get!(Event, event.id, authorize?: false).status == :open

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.get(EventModerator, assigned.id, authorize?: false)

    # 已移除的记录再走域入口 → not_found（幂等边界）
    assert {:error, :not_found} = Moderators.remove(assigned.id, workspace.id, owner)

    # 非管理角色不可撤权
    assert {:error, :forbidden} =
             Moderators.assign(event.id, workspace.id, user.id, owner)
             |> then(fn {:ok, record} -> Moderators.remove(record.id, workspace.id, user) end)
  end

  test "非成员指派被拒（#558 成员前提）：稳定 code 引导先邀请入台；入台后放行" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    # register_user 自动加入默认 2046 工作台，但不是本 workspace 的成员
    outsider = Fixtures.register_user("outsider")
    event = EventsFixtures.create_event(workspace, owner)

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Moderators.assign(event.id, workspace.id, outsider.id, owner)

    assert Enum.any?(
             errors,
             &match?(%BusinessError{code: "event_moderator_not_workspace_member"}, &1)
           ),
           "expected event_moderator_not_workspace_member, got: #{inspect(errors)}"

    refute Moderators.moderator?(outsider.id, event.id, workspace.id)

    # 入台（任意角色，learner 即可）后同一指派放行
    Fixtures.add_member(workspace, outsider, [:learner])
    assert {:ok, assigned} = Moderators.assign(event.id, workspace.id, outsider.id, owner)
    assert Moderators.moderator?(outsider.id, event.id, workspace.id)
    assert :ok = Moderators.remove(assigned.id, workspace.id, owner)
  end

  test "成员离台级联撤销其主理人指派（#561）：本台清空、他台不动、审计落行" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    other_workspace = Fixtures.create_workspace(owner)
    user = Fixtures.register_user("cascade-mod")
    Fixtures.add_member(workspace, user, [:learner])
    Fixtures.add_member(other_workspace, user, [:learner])
    event = EventsFixtures.create_event(workspace, owner)
    other_event = EventsFixtures.create_event(other_workspace, owner)

    # 平台身份就位（#538 负断言前置）：无身份时 Fanout 直接 skipped，
    # 「级联不发 removed」的 refute 会空转通过
    insert_identity(user.id, :wechat, "openid-cascade")

    {:ok, _} = Moderators.assign(event.id, workspace.id, user.id, owner)
    {:ok, _} = Moderators.assign(other_event.id, other_workspace.id, user.id, owner)

    # 指派审计落行（#561 接活沉睡原子）：target = 活动，metadata 带被指派者
    assert [_, _] = moderator_logs(:event_moderator_assign, event.id)
    assert [_, _] = moderator_logs(:event_moderator_assign, other_event.id)

    # 离台（destroy 本台 membership，唯一写边界）
    membership = Cgc2046.Accounts.MembershipContext.membership_of(user, workspace.id)
    Ash.destroy!(membership, actor: owner, tenant: workspace.id)

    # 本台指派清空 + 级联审计（cascade 标记与主动撤销区分）；他台不动
    refute Moderators.moderator?(user.id, event.id, workspace.id)
    assert Moderators.moderator?(user.id, other_event.id, other_workspace.id)

    assert [cascade_log] = moderator_logs(:event_moderator_remove, event.id)
    assert cascade_log.metadata["cascade"] == "membership_destroy"
    assert cascade_log.metadata["user_id"] == user.id
    assert moderator_logs(:event_moderator_remove, other_event.id) == []

    # #538：级联撤销（裸 SQL DELETE）不经 Moderators.remove——不发
    # event_moderator_removed（「成员移除」另有语境，不逐行轰炸）
    # #847 批 4：event_moderator_removed 已迁耐久路径，行为面 = Delivery 行
    assert NotificationDelivery
           |> Ash.Query.filter(template_key == "event_moderator_removed")
           |> Ash.read!(authorize?: false) == []
  end

  test "主动撤销主理人落审计（无 cascade 标记，与离台级联区分）" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    user = Fixtures.register_user("manual-remove-mod")
    Fixtures.add_member(workspace, user, [:learner])
    event = EventsFixtures.create_event(workspace, owner)

    {:ok, assigned} = Moderators.assign(event.id, workspace.id, user.id, owner)
    assert :ok = Moderators.remove(assigned.id, workspace.id, owner)

    assert [log] = moderator_logs(:event_moderator_remove, event.id)
    assert log.metadata["user_id"] == user.id
    refute log.metadata["cascade"]
  end

  # ── #611：重复指派撞 identity 唯一索引 → 稳定 code（不再落 database_error） ──
  test "重复指派：event_moderator_already_assigned + 无库内文本 + 不落第二行" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    user = Fixtures.register_user("dup-mod")
    Fixtures.add_member(workspace, user, [:learner])
    event = EventsFixtures.create_event(workspace, owner)

    {:ok, _} = Moderators.assign(event.id, workspace.id, user.id, owner)

    assert {:error, %Ash.Error.Invalid{errors: errors} = error} =
             Moderators.assign(event.id, workspace.id, user.id, owner)

    assert Enum.any?(
             errors,
             &match?(
               %BusinessError{code: "event_moderator_already_assigned", fields: [:user_id]},
               &1
             )
           ),
           "expected event_moderator_already_assigned, got: #{inspect(errors)}"

    message = Exception.message(error)
    assert message =~ "this user is already a moderator of the event"
    refute message =~ "event_moderators_event_id_user_id_index"
    refute message =~ "event_moderators_unique_event_user_index"
    refute message =~ "duplicate key"
    refute message =~ "constraint error"

    assert [row] =
             EventModerator
             |> Ash.Query.filter(event_id == ^event.id and user_id == ^user.id)
             |> Ash.read!(authorize?: false)

    assert row.user_id == user.id
  end

  # ensure_assigned/2 的幂等语义必须由**稳定 code** 承载，不得再依赖
  # Ecto.ConstraintError 原文（改名对齐索引后原文里的注册约束名消失）。
  test "ensure_assigned 幂等：重复调用仍 :ok（判据 = event_moderator_already_assigned）" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    event = EventsFixtures.create_event(workspace, owner)

    assert :ok = Moderators.ensure_assigned(event, owner.id)
    assert :ok = Moderators.ensure_assigned(event, owner.id)
  end

  # ── #537：三锚点指派 + 统一未命中 + 回显平铺 ─────────────────────────────

  test "三锚点指派命中：email（大小写混合）/ CGC 编号（小写）/ UUID（大写）" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    user = Fixtures.register_user_with_email("anchor-mod@example.com")
    Fixtures.add_member(workspace, user, [:learner])
    event = EventsFixtures.create_event(workspace, owner)

    member_number =
      "CGC-" <>
        (user.id |> String.replace("-", "") |> String.slice(0, 6) |> String.upcase())

    assert {:ok, by_email} =
             Moderators.assign(event.id, workspace.id, "Anchor-Mod@Example.com", owner)

    assert by_email.user_id == user.id
    assert :ok = Moderators.remove(by_email.id, workspace.id, owner)

    assert {:ok, by_cgc} =
             Moderators.assign(event.id, workspace.id, String.downcase(member_number), owner)

    assert by_cgc.user_id == user.id
    assert :ok = Moderators.remove(by_cgc.id, workspace.id, owner)

    assert {:ok, by_uuid} =
             Moderators.assign(event.id, workspace.id, String.upcase(user.id), owner)

    assert by_uuid.user_id == user.id
  end

  test "任一锚未命中统一 user_not_found（不区分锚类型，防枚举）" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    event = EventsFixtures.create_event(workspace, owner)

    for anchor <- [
          "nobody@example.com",
          "cgc-000000",
          Ecto.UUID.generate(),
          "not-an-anchor"
        ] do
      assert {:error, %BusinessError{code: "user_not_found"}} =
               Moderators.assign(event.id, workspace.id, anchor, owner),
             "anchor: #{anchor}"
    end
  end

  test "CGC 前缀歧义：命中多行报 user_anchor_ambiguous（引导改用用户 ID）" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    user_a = Fixtures.register_user("ambiguous-a")
    Fixtures.add_member(workspace, user_a, [:learner])
    event = EventsFixtures.create_event(workspace, owner)

    # 构造前 6 hex 与 user_a 相同的第二个 uuid（必然碰撞，O(1)）：
    # prefix + 随机 26 hex → 重组 8-4-4-4-12
    prefix = user_a.id |> String.replace("-", "") |> String.slice(0, 6)
    hex_b = prefix <> (:crypto.strong_rand_bytes(13) |> Base.encode16(case: :lower))

    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> = hex_b

    uuid_b = "#{a}-#{b}-#{c}-#{d}-#{e}"

    register_user_with_uuid("ambiguous-b@example.com", uuid_b)

    assert {:error, %BusinessError{code: "user_anchor_ambiguous"}} =
             Moderators.assign(event.id, workspace.id, "cgc-" <> String.downcase(prefix), owner)
  end

  test "closed / cancelled 场次仍可指派与移除（#537 语义不变，钉住不回归）" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    user = Fixtures.register_user("closed-mod")
    Fixtures.add_member(workspace, user, [:learner])

    closed = EventsFixtures.create_event(workspace, owner)
    closed |> Ash.Changeset.for_update(:close, %{}) |> Ash.update!(actor: owner)

    cancelled = EventsFixtures.create_event(workspace, owner)
    cancelled |> Ash.Changeset.for_update(:cancel, %{}) |> Ash.update!(actor: owner)

    assert {:ok, row} = Moderators.assign(closed.id, workspace.id, user.id, owner)
    assert Moderators.moderator?(user.id, closed.id, workspace.id)
    assert :ok = Moderators.remove(row.id, workspace.id, owner)

    assert {:ok, row2} = Moderators.assign(cancelled.id, workspace.id, user.email, owner)
    assert :ok = Moderators.remove(row2.id, workspace.id, owner)
  end

  test "回显平铺：displayName / memberNumber / assignedBy 单查询带出（#537）" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    user = Fixtures.register_user("display-mod")
    Fixtures.add_member(workspace, user, [:learner])
    event = EventsFixtures.create_event(workspace, owner)

    assert {:ok, _} = Moderators.assign(event.id, workspace.id, user.id, owner)

    assert {:ok, rows} = Moderators.list(event.id, workspace.id, owner)
    row = Enum.find(rows, &(&1.user_id == user.id))

    # display_name 未设置：nil + memberNumber 恒有值（fallback 链数据面）
    assert row.user_display_name == nil
    assert row.user_member_number == expected_member_number(user.id)
    assert row.assigned_by_display_name == nil
    assert row.assigned_by_member_number == expected_member_number(owner.id)

    # 本人设置 display_name 后，同查询回显新值（展示字段公开可见）
    user
    |> Ash.Changeset.for_update(:update_display_name, %{display_name: "展示名"})
    |> Ash.update!(actor: user)

    assert {:ok, rows2} = Moderators.list(event.id, workspace.id, owner)
    row2 = Enum.find(rows2, &(&1.user_id == user.id))
    assert row2.user_display_name == "展示名"
  end

  # ── #538：公开投影 public_moderators + 移除通知 ──────────────────────────

  test "公开投影：匿名可求值、键集最小化（displayName/memberNumber 两键）、displayName 缺失回退数据面" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    user = Fixtures.register_user("public-mod")
    Fixtures.add_member(workspace, user, [:learner])
    event = EventsFixtures.create_event(workspace, owner)

    user
    |> Ash.Changeset.for_update(:update_display_name, %{display_name: "展示名"})
    |> Ash.update!(actor: user)

    assert {:ok, _} = Moderators.assign(event.id, workspace.id, user.id, owner)

    # 匿名（无 actor）读 open+public 并求值投影——行级门在 Event read policy，
    # 投影本身不设门
    assert {:ok, readable} = Ash.get(Event, event.id, authorize?: true)

    assert {:ok, %{public_moderators: projections}} =
             Ash.load(readable, :public_moderators, authorize?: true)

    assert length(projections) == 2

    # 键集最小化：userId/email/phone 结构性不存在（非过滤排除），每行两键
    assert Enum.all?(
             projections,
             &(Map.keys(&1) |> Enum.sort() == [:display_name, :member_number])
           )

    by_number = Map.new(projections, &{&1.member_number, &1.display_name})
    # owner 未设置 displayName → nil（展示层回退 memberNumber 的数据面）
    assert Map.fetch!(by_number, expected_member_number(owner.id)) == nil
    assert Map.fetch!(by_number, expected_member_number(user.id)) == "展示名"

    # 全员移除后投影空数组（展示层「无主理人不渲染」的数据面）
    {:ok, rows} = Moderators.list(event.id, workspace.id, owner)
    for row <- rows, do: :ok = Moderators.remove(row.id, workspace.id, owner)

    assert {:ok, readable2} = Ash.get(Event, event.id, authorize?: true)

    assert {:ok, %{public_moderators: []}} =
             Ash.load(readable2, :public_moderators, authorize?: true)
  end

  test "公开投影排序：assignedAt 升序（与管理面 Moderators.list 同序）" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    first = Fixtures.register_user("order-first")
    second = Fixtures.register_user("order-second")
    Fixtures.add_member(workspace, first, [:learner])
    Fixtures.add_member(workspace, second, [:learner])
    event = EventsFixtures.create_event(workspace, owner)

    # 清空建场自动指派，直插可控 assigned_at 的两行（assign action accept 该列）
    {:ok, rows} = Moderators.list(event.id, workspace.id, owner)
    for row <- rows, do: :ok = Moderators.remove(row.id, workspace.id, owner)

    insert_moderator(event, second, owner, ~U[2026-09-02 00:00:00Z])
    insert_moderator(event, first, owner, ~U[2026-09-01 00:00:00Z])

    assert {:ok, readable} = Ash.get(Event, event.id, authorize?: true)

    assert {:ok, %{public_moderators: projections}} =
             Ash.load(readable, :public_moderators, authorize?: true)

    assert Enum.map(projections, & &1.member_number) ==
             [expected_member_number(first.id), expected_member_number(second.id)]
  end

  test "closed 场次投影照出（成员可读路径，跟随现有投影口径；投影不设状态门）" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    member = Fixtures.register_user("closed-viewer")
    Fixtures.add_member(workspace, member, [:learner])

    closed = EventsFixtures.create_event(workspace, owner)
    closed |> Ash.Changeset.for_update(:close, %{}) |> Ash.update!(actor: owner)

    # 成员经 ActorReadsOffering 读 closed（visibility 测试既有口径），投影随行
    assert {:ok, readable} = Ash.get(Event, closed.id, actor: member, authorize?: true)

    assert {:ok, %{public_moderators: projections}} =
             Ash.load(readable, :public_moderators, authorize?: true)

    assert [_ | _] = projections
  end

  test "移除通知：主动移除入队 event_moderator_removed（逐身份，data 带 event_id/title）" do
    owner = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(owner)
    user = Fixtures.register_user("removed-mod")
    Fixtures.add_member(workspace, user, [:learner])
    insert_identity(user.id, :wechat, "openid-removed-wechat")
    insert_identity(user.id, :tt, "openid-removed-tt")
    event = EventsFixtures.create_event(workspace, owner)

    {:ok, assigned} = Moderators.assign(event.id, workspace.id, user.id, owner)
    :ok = Moderators.remove(assigned.id, workspace.id, owner)

    removed_jobs =
      NotificationDelivery
      |> Ash.Query.filter(template_key == "event_moderator_removed")
      |> Ash.read!(authorize?: false)
      |> Enum.map(&%{args: %{"user_id" => &1.user_id, "data" => &1.data}})

    # 两平台身份各一条（同用户多身份不折叠，#3 口径）
    assert length(removed_jobs) == 2
    assert Enum.all?(removed_jobs, &(&1.args["user_id"] == user.id))
    assert Enum.all?(removed_jobs, &(&1.args["data"]["event_id"] == event.id))
    assert Enum.all?(removed_jobs, &(&1.args["data"]["title"] == event.title))
  end

  defp expected_member_number(uuid) do
    "CGC-" <> (uuid |> String.replace("-", "") |> String.slice(0, 6) |> String.upcase())
  end

  # 直插可控 assigned_at 的主理人行（排序测试专用；成员前提由 assign 校验承载）
  defp insert_moderator(event, user, actor, assigned_at) do
    EventModerator
    |> Ash.Changeset.for_create(:assign, %{
      workspace_id: event.workspace_id,
      event_id: event.id,
      user_id: user.id,
      assigned_by: actor.id,
      assigned_at: assigned_at
    })
    |> Ash.create!(authorize?: false, tenant: event.workspace_id)
  end

  # 平台身份裸插（service_test.exs 同款）：Fanout.identities 的取值源
  defp insert_identity(user_id, platform, uid) do
    Cgc2046.Repo.query!(
      """
      INSERT INTO user_identities (id, provider, uid, user_id, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, $2, $3, NOW(), NOW())
      """,
      [to_string(platform), uid, Ecto.UUID.dump!(user_id)]
    )
  end

  # 歧义布置：force 指定 uuid（register_with_password + force_change_attribute，
  # 绕 writable 默认——uuid 由 Ash 自动生成，测试需要前缀可控）
  defp register_user_with_uuid(email, uuid) do
    Cgc2046.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: email,
      password: Fixtures.password()
    })
    |> Ash.Changeset.force_change_attribute(:id, uuid)
    |> Ash.create!(authorize?: false)
  end

  # 审计行断言收窄到本测试独占的 target_id（共享沙箱不见他测试未提交行，
  # 但本测试的多次写同 target 会累积——按 target 过滤即可）
  defp moderator_logs(action, event_id) do
    Cgc2046.Accounts.AdminActionLog
    |> Ash.Query.filter(action == ^action and target_id == ^event_id)
    |> Ash.read!(authorize?: false)
  end
end
