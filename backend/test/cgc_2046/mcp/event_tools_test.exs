defmodule Cgc2046.Mcp.EventToolsTest do
  @moduledoc """
  活动管理工具面测试（role-agent-journeys-v2 S3 event 六件 + list_enrollments
  kind=event 分派；直接调 tool execute/2，不走 HTTP；workspace_admin_tools_test
  同款模式）。

  - 授权：plain member / tutor / learner / 非成员对活动六件写工具一律 forbidden
    （非成员撞 Wrapper member 门；成员撞工具层 Owner/Admin 判定；#676
    delete_event 收窄为 Owner ∪ 平台管理员，admin 亦拒）；
    list_workspace_events 为 member-only 发现面（成员可读全部状态含 draft）
  - create_event 直接写生成 draft（venue/pricing 落库，slug 缺省生成 e-<hex>），
    不经 pending
  - update/launch/close/cancel 确认流两段式；close/cancel 摘要含终态不可逆提示
  - update_event pricing_enabled true→false 摘要含批量免缴影响（R9/KTD4）
  - list_enrollments kind=event 分派：活动报名行 + 跨 kind 隔离 + 非法 kind 报错
  - confirm_enrollment 成功投影补 event_id（课程字段为 nil 原样返回）
  - 跨租户：他工作台 event_id / offering_id ≡ not found（不泄露存在性）
  - #630 detach 来源标记：create/update 写响应与 list_workspace_events 行恒带
    `detached_rule_provenance`（无标记 nil；detach 后含 initiative 身份 + 只含
    locked 字段），MCP 编辑标记内字段逐字段清除；公开 MCP 面（list/get public
    offering、discover_offerings）负向不透出
  - #539 assign_event_moderator 三锚点（email / CGC 编号 / UUID，域层
    UserResolution 单源）：错误码 `user_not_found` / `user_anchor_ambiguous`
    前缀透传（不落笼统 fallback）；权限门先于解析（越权者探测不到
    user_not_found）；list_event_moderators 行带回显平铺字段
  """
  use Cgc2046.DataCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Events.Event
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Initiatives.{Initiative, InitiativeRule, RuleInheritance}
  alias Cgc2046.Mcp.{PendingOperation, ToolCallLog}

  alias Cgc2046.Mcp.Tools.{
    AssignEventModerator,
    CancelEvent,
    CloseEvent,
    ConfirmEnrollment,
    ConfirmOperation,
    CreateEvent,
    DeleteEvent,
    DiscoverOfferings,
    GetPublicOffering,
    LaunchEvent,
    ListEnrollments,
    ListEventModerators,
    ListPublicOfferings,
    ListWorkspaceEvents,
    UpdateEvent
  }

  alias Cgc2046.Events.Moderators

  require Ash.Query

  @tier_id "88888888-8888-8888-8888-888888888888"
  @tier %{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900}

  @venue %{"country" => "中国", "province" => "浙江省", "city" => "杭州市", "district" => "西湖区"}

  # 活动六件写工具（list_workspace_events 为 member-only 发现面，不在此列）
  @event_write_tools %{
    "create_event" => CreateEvent,
    "update_event" => UpdateEvent,
    "launch_event" => LaunchEvent,
    "close_event" => CloseEvent,
    "cancel_event" => CancelEvent,
    "delete_event" => DeleteEvent
  }

  defp frame_for(user), do: Frame.new(current_user: user)

  defp decode_reply({:reply, response, _frame}) do
    [content] = response.content
    Jason.decode!(content["text"])
  end

  defp tool_logs_for(user_id, tool_name) do
    ToolCallLog
    |> Ash.Query.filter(user_id == ^user_id and tool == ^tool_name)
    |> Ash.read!(authorize?: false)
  end

  defp pending_count do
    PendingOperation |> Ash.read!(authorize?: false) |> length()
  end

  # 行已删除：Ash.get 对不存在的主键回 NotFound（不是 {:ok, nil}）
  defp assert_deleted(event_id) do
    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
             Ash.get(Event, event_id, authorize?: false)
  end

  # 草稿活动（不经 EventFixtures 的 force_open——launch 路径需要 draft 起点）
  defp draft_event(workspace, actor, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{title: "S3 Draft Event", registration_deadline: EventFixtures.days_from_now(7)},
        attrs
      )

    Event
    |> Ash.Changeset.for_create(:create, attrs, tenant: workspace.id)
    |> Ash.create!(tenant: workspace.id, actor: actor)
  end

  defp open_event(workspace, actor, attrs \\ %{}),
    do: EventFixtures.create_event(workspace, actor, attrs)

  defp paid_event(workspace, actor),
    do: open_event(workspace, actor, %{pricing_enabled: true, price_tiers: [@tier]})

  # #596 挂载继承可见：initiative 由平台管理员建规则 + 开门（挂载要求 open 且四规则齐备）
  defp initiative_with_rules(admin, slug, rules) do
    initiative =
      Initiative
      |> Ash.Changeset.for_create(:create, %{
        name: "规则倡议 #{slug}",
        slug: slug,
        created_by: admin.id
      })
      |> Ash.create!(actor: admin)

    for {key, value, locked} <- rules do
      InitiativeRule
      |> Ash.Changeset.for_create(:create, %{
        initiative_id: initiative.id,
        key: key,
        value: value,
        locked: locked
      })
      |> Ash.create!(actor: admin)
    end

    initiative |> Ash.Changeset.for_update(:open, %{}) |> Ash.update!(actor: admin)
  end

  # 两锁两默认：deposit/age_gate 锁死，min_participants/deadline_rule 挂载快照
  defp mixed_initiative(admin, slug) do
    initiative_with_rules(admin, slug, [
      {:deposit, %{enabled: true, amount_cents: 6900}, true},
      {:age_gate, %{min_age: 18}, true},
      {:min_participants, %{count: 8}, false},
      {:deadline_rule, %{hours_before_start: 72}, false}
    ])
  end

  defp all_default_initiative(admin, slug) do
    initiative_with_rules(admin, slug, [
      {:deposit, %{enabled: false}, false},
      {:age_gate, %{min_age: 21}, false},
      {:min_participants, %{count: 5}, false},
      {:deadline_rule, %{hours_before_start: 48}, false}
    ])
  end

  # 硬要求①：响应里每个 inherited 值必须等于落库真值（不是响应自洽）
  defp assert_inherited_matches_db(payload, workspace) do
    event = Ash.get!(Event, payload["event_id"], authorize?: false, tenant: workspace.id)

    for {field, entry} <- payload["inherited"] do
      db_value =
        case field do
          "registration_deadline" ->
            event.registration_deadline &&
              DateTime.to_iso8601(DateTime.truncate(event.registration_deadline, :second))

          field ->
            Map.fetch!(event, String.to_existing_atom(field))
        end

      assert entry["value"] == db_value,
             "inherited.#{field} 响应 #{inspect(entry["value"])} != 落库 #{inspect(db_value)}"
    end

    event
  end

  # create/update 挂载态的公共事件输入（押金规则开启 → 需要 ends_at 与截止）
  @mounted_event_attrs %{
    "starts_at" => "2027-01-10T10:00:00Z",
    "ends_at" => "2027-01-10T12:00:00Z",
    "capacity" => 50
  }

  # 域侧布置 detach 状态：MCP 已支持 detach_initiative: true（#632），此 helper
  # 供标记相关测试直接布置，少走一轮确认流。
  defp detach!(event, actor, workspace) do
    event
    |> Ash.Changeset.for_update(:update, %{initiative_id: nil}, tenant: workspace.id)
    |> Ash.update!(actor: actor, tenant: workspace.id)
  end

  # 挂载建场（CreateEvent 直接写 → draft）返回 event_id；@mounted_event_attrs 满足
  # 押金规则开启所需的 ends_at / capacity
  defp mount_event(owner, workspace, initiative, title) do
    assert {:reply, _, _} =
             reply =
             CreateEvent.execute(
               Map.merge(@mounted_event_attrs, %{
                 "workspace_id" => workspace.id,
                 "title" => title,
                 "initiative_id" => initiative.id
               }),
               frame_for(owner)
             )

    decode_reply(reply)["event_id"]
  end

  defp enroll(event, learner, attrs \\ %{}) do
    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(
        :create_enrollment,
        Map.merge(%{event_id: event.id, user_id: learner.id}, attrs)
      )
      |> Ash.create(tenant: event.workspace_id, actor: learner)

    enrollment
  end

  # 收费活动报名（open 策略 + tier_id）→ payment_pending；每次调用注册新学员
  defp payment_pending_enrollment(event, prefix) do
    learner = Fixtures.register_user(prefix)
    enrollment = enroll(event, learner, %{tier_id: @tier_id})
    assert enrollment.status == :payment_pending
    {learner, enrollment}
  end

  describe "授权：非 Owner/Admin 对活动六件写工具 forbidden" do
    test "plain member / tutor / learner 撞工具层判定；非成员撞 member 门" do
      owner = Fixtures.platform_admin("s3-ev-authz-owner")
      workspace = Fixtures.create_workspace(owner)

      member = Fixtures.register_user("s3-ev-authz-member")
      Fixtures.add_member(workspace, member, [])

      tutor = Fixtures.register_user("s3-ev-authz-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])

      learner = Fixtures.register_user("s3-ev-authz-learner")
      Fixtures.add_member(workspace, learner, [:learner])

      outsider = Fixtures.register_user("s3-ev-authz-outsider")

      base_params = %{
        "workspace_id" => workspace.id,
        "title" => "X",
        "event_id" => Ecto.UUID.generate()
      }

      for {tool_name, module} <- @event_write_tools do
        # #676：delete_event 是收窄面（Owner ∪ 平台管理员，admin 不放行），
        # 文案与其余五件的 "owner or admin required" 刻意不同；非成员门不变。
        denial =
          if tool_name == "delete_event",
            do: "owner or platform admin required",
            else: "owner or admin required"

        for {user, expected} <- [
              {member, denial},
              {tutor, denial},
              {learner, denial},
              {outsider, "not a member"}
            ] do
          assert {:error, %Anubis.MCP.Error{message: msg}, _} =
                   apply(module, :execute, [base_params, frame_for(user)]),
                 "expected #{tool_name} to reject #{user.email}"

          assert msg =~ "forbidden", "expected forbidden for #{tool_name}, got: #{msg}"
          assert msg =~ expected, "expected #{inspect(expected)} for #{tool_name}, got: #{msg}"

          [log] = tool_logs_for(user.id, tool_name)
          assert log.result_status == :forbidden
        end
      end

      # 无任何 pending / 活动副作用
      assert pending_count() == 0
      assert [] = Ash.read!(Event, authorize?: false, tenant: workspace.id)
    end
  end

  describe "create_event（直接写）" do
    test "Owner 直接创建 draft（venue/赞助/定价落库，slug 缺省生成）" do
      owner = Fixtures.platform_admin("s3-ev-cc-owner")
      workspace = Fixtures.create_workspace(owner)

      assert {:reply, _, _} =
               reply =
               CreateEvent.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "title" => "杭州站见面会",
                   "description" => "线下交流",
                   "venue" => @venue,
                   "visibility" => "workspace",
                   "pricing_enabled" => true,
                   "price_tiers" => [@tier],
                   "capacity" => 50,
                   "starts_at" => "2027-01-10T10:00:00Z",
                   "ends_at" => "2027-01-10T12:00:00Z",
                   "registration_deadline" => "2027-01-01T00:00:00Z"
                 },
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["title"] == "杭州站见面会"
      assert payload["status"] == "draft"
      assert payload["pricing_enabled"] == true
      assert payload["visibility"] == "workspace"
      assert payload["slug"] =~ ~r/^e-[0-9a-f]{8}$/

      event = Ash.get!(Event, payload["event_id"], authorize?: false, tenant: workspace.id)
      assert event.status == :draft
      assert event.capacity == 50
      assert event.venue == @venue
      assert [%{"id" => @tier_id}] = event.price_tiers

      [log] = tool_logs_for(owner.id, "create_event")
      assert log.result_status == :ok
      # 直接写：不经 pending
      assert pending_count() == 0
    end

    test "显式 false 布尔落库（sponsorship/curriculum 域默认 true，丢弃=false 即回归）" do
      owner = Fixtures.platform_admin("s3-ev-cc-false-owner")
      workspace = Fixtures.create_workspace(owner)

      assert {:reply, _, _} =
               reply =
               CreateEvent.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "title" => "无赞助无教研活动",
                   "sponsorship_enabled" => false,
                   "curriculum_enabled" => false
                 },
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      event = Ash.get!(Event, payload["event_id"], authorize?: false, tenant: workspace.id)
      assert event.sponsorship_enabled == false
      assert event.curriculum_enabled == false
    end
  end

  describe "挂载继承可见（#596）" do
    test "create_event 回传本次生效的继承结果（值 == 落库真值，source 区分 locked/default）" do
      owner = Fixtures.platform_admin("s3-ev-inherit-owner")
      workspace = Fixtures.create_workspace(owner)
      initiative = mixed_initiative(owner, "s3-ev-inherit-mixed")

      assert {:reply, _, _} =
               reply =
               CreateEvent.execute(
                 Map.merge(@mounted_event_attrs, %{
                   "workspace_id" => workspace.id,
                   "title" => "挂载建场",
                   "initiative_id" => initiative.id
                 }),
                 frame_for(owner)
               )

      payload = decode_reply(reply)

      assert payload["initiative"] == %{
               "id" => initiative.id,
               "name" => initiative.name,
               "slug" => initiative.slug
             }

      assert payload["inherited"] == %{
               "deposit_enabled" => %{"value" => true, "source" => "locked"},
               "deposit_amount_cents" => %{"value" => 6900, "source" => "locked"},
               "min_age" => %{"value" => 18, "source" => "locked"},
               "min_participants" => %{"value" => 8, "source" => "default"},
               "registration_deadline" => %{
                 "value" => "2027-01-07T10:00:00Z",
                 "source" => "default"
               }
             }

      assert_inherited_matches_db(payload, workspace)
    end

    test "无挂载 create_event 回空壳（inherited == %{}、initiative == nil）" do
      owner = Fixtures.platform_admin("s3-ev-inherit-none")
      workspace = Fixtures.create_workspace(owner)

      assert {:reply, _, _} =
               reply =
               CreateEvent.execute(
                 %{"workspace_id" => workspace.id, "title" => "无挂载"},
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["initiative"] == nil
      assert payload["inherited"] == %{}
    end

    test "update_event 未改挂载：只回 locked 项（unlocked 规则本次不写）" do
      owner = Fixtures.platform_admin("s3-ev-inherit-update")
      workspace = Fixtures.create_workspace(owner)
      initiative = mixed_initiative(owner, "s3-ev-inherit-update-mixed")

      assert {:reply, _, _} =
               created =
               CreateEvent.execute(
                 Map.merge(@mounted_event_attrs, %{
                   "workspace_id" => workspace.id,
                   "title" => "挂载后再改",
                   "initiative_id" => initiative.id
                 }),
                 frame_for(owner)
               )

      created_payload = decode_reply(created)

      assert {:reply, _, _} =
               pending =
               UpdateEvent.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "event_id" => created_payload["event_id"],
                   "title" => "改名"
                 },
                 frame_for(owner)
               )

      assert {:reply, _, _} =
               confirmed =
               ConfirmOperation.execute(
                 %{"pending_id" => decode_reply(pending)["pending_id"]},
                 frame_for(owner)
               )

      result = decode_reply(confirmed)["result"]

      assert result["initiative"]["id"] == initiative.id

      assert result["inherited"] == %{
               "deposit_enabled" => %{"value" => true, "source" => "locked"},
               "deposit_amount_cents" => %{"value" => 6900, "source" => "locked"},
               "min_age" => %{"value" => 18, "source" => "locked"}
             }

      assert_inherited_matches_db(result, workspace)
    end

    test "update_event 改挂载：新 Initiative 的默认项按挂载快照回传" do
      owner = Fixtures.platform_admin("s3-ev-inherit-remount")
      workspace = Fixtures.create_workspace(owner)
      first = mixed_initiative(owner, "s3-ev-inherit-remount-a")
      second = all_default_initiative(owner, "s3-ev-inherit-remount-b")

      assert {:reply, _, _} =
               created =
               CreateEvent.execute(
                 Map.merge(@mounted_event_attrs, %{
                   "workspace_id" => workspace.id,
                   "title" => "换挂载",
                   "initiative_id" => first.id
                 }),
                 frame_for(owner)
               )

      event_id = decode_reply(created)["event_id"]

      assert {:reply, _, _} =
               pending =
               UpdateEvent.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "event_id" => event_id,
                   "initiative_id" => second.id
                 },
                 frame_for(owner)
               )

      assert {:reply, _, _} =
               confirmed =
               ConfirmOperation.execute(
                 %{"pending_id" => decode_reply(pending)["pending_id"]},
                 frame_for(owner)
               )

      result = decode_reply(confirmed)["result"]
      assert result["initiative"]["id"] == second.id

      assert result["inherited"] == %{
               "deposit_enabled" => %{"value" => false, "source" => "default"},
               "deposit_amount_cents" => %{"value" => nil, "source" => "default"},
               "min_age" => %{"value" => 21, "source" => "default"},
               "min_participants" => %{"value" => 5, "source" => "default"},
               "registration_deadline" => %{
                 "value" => "2027-01-08T10:00:00Z",
                 "source" => "default"
               }
             }

      assert_inherited_matches_db(result, workspace)
    end

    test "locked 字段的本地冲突写仍被拒绝（错误语义不变）" do
      owner = Fixtures.platform_admin("s3-ev-inherit-locked")
      workspace = Fixtures.create_workspace(owner)
      initiative = mixed_initiative(owner, "s3-ev-inherit-locked-mixed")

      assert {:reply, _, _} =
               created =
               CreateEvent.execute(
                 Map.merge(@mounted_event_attrs, %{
                   "workspace_id" => workspace.id,
                   "title" => "锁死守卫",
                   "initiative_id" => initiative.id
                 }),
                 frame_for(owner)
               )

      event_id = decode_reply(created)["event_id"]

      assert {:reply, _, _} =
               pending =
               UpdateEvent.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "event_id" => event_id,
                   "min_age" => 21
                 },
                 frame_for(owner)
               )

      assert {:error, %Anubis.MCP.Error{message: message}, _} =
               ConfirmOperation.execute(
                 %{"pending_id" => decode_reply(pending)["pending_id"]},
                 frame_for(owner)
               )

      assert message =~ "initiative rule age_gate is locked"
    end

    test "全 unlocked 的挂载场普通更新：initiative 在、inherited 空（本次无规则写入）" do
      owner = Fixtures.platform_admin("s3-ev-inherit-unlocked")
      workspace = Fixtures.create_workspace(owner)
      initiative = all_default_initiative(owner, "s3-ev-inherit-unlocked-init")

      assert {:reply, _, _} =
               created =
               CreateEvent.execute(
                 Map.merge(@mounted_event_attrs, %{
                   "workspace_id" => workspace.id,
                   "title" => "全默认规则场",
                   "initiative_id" => initiative.id
                 }),
                 frame_for(owner)
               )

      event_id = decode_reply(created)["event_id"]

      assert {:reply, _, _} =
               pending =
               UpdateEvent.execute(
                 %{"workspace_id" => workspace.id, "event_id" => event_id, "title" => "改名"},
                 frame_for(owner)
               )

      assert {:reply, _, _} =
               confirmed =
               ConfirmOperation.execute(
                 %{"pending_id" => decode_reply(pending)["pending_id"]},
                 frame_for(owner)
               )

      result = decode_reply(confirmed)["result"]
      assert result["initiative"]["id"] == initiative.id
      assert result["inherited"] == %{}
    end

    test "detach（initiative_id → nil）：inherited 空壳、initiative nil（域路径）" do
      owner = Fixtures.platform_admin("s3-ev-inherit-detach")
      workspace = Fixtures.create_workspace(owner)
      initiative = mixed_initiative(owner, "s3-ev-inherit-detach-init")

      assert {:reply, _, _} =
               created =
               CreateEvent.execute(
                 Map.merge(@mounted_event_attrs, %{
                   "workspace_id" => workspace.id,
                   "title" => "待摘除",
                   "initiative_id" => initiative.id
                 }),
                 frame_for(owner)
               )

      mounted =
        Ash.get!(Event, decode_reply(created)["event_id"],
          authorize?: false,
          tenant: workspace.id
        )

      # 写响应的继承元数据只在写返回的记录上；重读记录按落库真值核对
      assert mounted.initiative_id == initiative.id
      assert decode_reply(created)["inherited"]["min_age"]["value"] == mounted.min_age

      detached =
        mounted
        |> Ash.Changeset.for_update(:update, %{initiative_id: nil}, tenant: workspace.id)
        |> Ash.update!(actor: owner, tenant: workspace.id)

      assert detached.initiative_id == nil
      # #596 写响应契约不变：本次无规则写入 → inherited 空壳
      assert RuleInheritance.inheritance_of(detached) == %{initiative: nil, inherited: %{}}

      # #624 方案 C：locked 规则强制写入的值保留 + 落库来源标记（只含 locked 字段）
      assert detached.min_age == mounted.min_age
      assert detached.deposit_enabled == mounted.deposit_enabled

      assert detached.detached_rule_provenance == %{
               "initiative" => %{
                 "id" => initiative.id,
                 "name" => initiative.name,
                 "slug" => initiative.slug
               },
               "fields" => %{
                 "deposit_amount_cents" => %{"value" => 6900, "source" => "locked"},
                 "deposit_enabled" => %{"value" => true, "source" => "locked"},
                 "min_age" => %{"value" => 18, "source" => "locked"}
               }
             }

      assert Ash.get!(Event, detached.id, authorize?: false, tenant: workspace.id).detached_rule_provenance ==
               detached.detached_rule_provenance
    end
  end

  describe "解除挂载来源标记（#630）" do
    test "update_event 响应含来源标记（initiative 身份 + 只含 locked 字段）；无标记时键恒在为 nil" do
      owner = Fixtures.platform_admin("s3-ev-630-write")
      workspace = Fixtures.create_workspace(owner)
      initiative = mixed_initiative(owner, "s3-ev-630-write-init")

      assert {:reply, _, _} =
               created =
               CreateEvent.execute(
                 Map.merge(@mounted_event_attrs, %{
                   "workspace_id" => workspace.id,
                   "title" => "待摘除",
                   "initiative_id" => initiative.id
                 }),
                 frame_for(owner)
               )

      created_payload = decode_reply(created)
      event_id = created_payload["event_id"]

      # create_event 响应恒带该键（新建无标记 → nil）
      assert Map.has_key?(created_payload, "detached_rule_provenance")
      assert created_payload["detached_rule_provenance"] == nil

      mounted = Ash.get!(Event, event_id, authorize?: false, tenant: workspace.id)
      detached = detach!(mounted, owner, workspace)

      # detach 只标记此刻仍 locked 的规则字段（min_participants / deadline_rule
      # 是挂载快照，不标）
      assert detached.detached_rule_provenance == %{
               "initiative" => %{
                 "id" => initiative.id,
                 "name" => initiative.name,
                 "slug" => initiative.slug
               },
               "fields" => %{
                 "deposit_amount_cents" => %{"value" => 6900, "source" => "locked"},
                 "deposit_enabled" => %{"value" => true, "source" => "locked"},
                 "min_age" => %{"value" => 18, "source" => "locked"}
               }
             }

      assert {:reply, _, _} =
               pending =
               UpdateEvent.execute(
                 %{"workspace_id" => workspace.id, "event_id" => event_id, "title" => "摘除后改名"},
                 frame_for(owner)
               )

      assert {:reply, _, _} =
               confirmed =
               ConfirmOperation.execute(
                 %{"pending_id" => decode_reply(pending)["pending_id"]},
                 frame_for(owner)
               )

      result = decode_reply(confirmed)["result"]

      # MCP 写响应 = 落库真值，恒带标记键；未改标记内字段 → 标记原样保留
      assert result["detached_rule_provenance"] == detached.detached_rule_provenance

      assert Ash.get!(Event, event_id, authorize?: false, tenant: workspace.id).detached_rule_provenance ==
               result["detached_rule_provenance"]

      # #596 契约不变：detach 后本次无规则写入 → initiative nil / inherited 空壳
      assert result["initiative"] == nil
      assert result["inherited"] == %{}
    end

    test "MCP 编辑标记内字段 → 响应该键消失（逐字段清除）；编辑未标记字段不动标记" do
      owner = Fixtures.platform_admin("s3-ev-630-clear")
      workspace = Fixtures.create_workspace(owner)
      initiative = mixed_initiative(owner, "s3-ev-630-clear-init")

      event_id = mount_event(owner, workspace, initiative, "待摘除再编辑")

      mounted = Ash.get!(Event, event_id, authorize?: false, tenant: workspace.id)
      detached = detach!(mounted, owner, workspace)
      assert map_size(detached.detached_rule_provenance["fields"]) == 3

      # 编辑标记内字段 min_age（18 → 20）：只清该键，其余 locked 键保留
      assert {:reply, _, _} =
               pending =
               UpdateEvent.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "event_id" => event_id,
                   "min_age" => 20
                 },
                 frame_for(owner)
               )

      assert {:reply, _, _} =
               confirmed =
               ConfirmOperation.execute(
                 %{"pending_id" => decode_reply(pending)["pending_id"]},
                 frame_for(owner)
               )

      result = decode_reply(confirmed)["result"]
      fields = result["detached_rule_provenance"]["fields"]

      refute Map.has_key?(fields, "min_age")

      assert fields == %{
               "deposit_amount_cents" => %{"value" => 6900, "source" => "locked"},
               "deposit_enabled" => %{"value" => true, "source" => "locked"}
             }

      assert result["detached_rule_provenance"]["initiative"]["id"] == initiative.id

      assert Ash.get!(Event, event_id, authorize?: false, tenant: workspace.id).detached_rule_provenance ==
               result["detached_rule_provenance"]

      # 编辑未标记字段（title）不动标记
      assert {:reply, _, _} =
               pending_title =
               UpdateEvent.execute(
                 %{"workspace_id" => workspace.id, "event_id" => event_id, "title" => "再改名"},
                 frame_for(owner)
               )

      assert {:reply, _, _} =
               confirmed_title =
               ConfirmOperation.execute(
                 %{"pending_id" => decode_reply(pending_title)["pending_id"]},
                 frame_for(owner)
               )

      assert decode_reply(confirmed_title)["result"]["detached_rule_provenance"] ==
               result["detached_rule_provenance"]
    end

    test "清空最后一个标记字段 → 响应整列归 nil（键仍在）" do
      owner = Fixtures.platform_admin("s3-ev-630-last")
      workspace = Fixtures.create_workspace(owner)

      # 只锁 age_gate：detach 标记恰一个字段，MCP 一次编辑即清空整列
      initiative =
        initiative_with_rules(owner, "s3-ev-630-last-init", [
          {:deposit, %{enabled: false}, false},
          {:age_gate, %{min_age: 18}, true},
          {:min_participants, %{count: 8}, false},
          {:deadline_rule, %{hours_before_start: 72}, false}
        ])

      event_id = mount_event(owner, workspace, initiative, "最后一个标记")

      detached =
        event_id
        |> then(&Ash.get!(Event, &1, authorize?: false, tenant: workspace.id))
        |> detach!(owner, workspace)

      assert map_size(detached.detached_rule_provenance["fields"]) == 1

      assert {:reply, _, _} =
               pending =
               UpdateEvent.execute(
                 %{"workspace_id" => workspace.id, "event_id" => event_id, "min_age" => 30},
                 frame_for(owner)
               )

      assert {:reply, _, _} =
               confirmed =
               ConfirmOperation.execute(
                 %{"pending_id" => decode_reply(pending)["pending_id"]},
                 frame_for(owner)
               )

      result = decode_reply(confirmed)["result"]
      assert Map.has_key?(result, "detached_rule_provenance")
      assert result["detached_rule_provenance"] == nil

      assert Ash.get!(Event, event_id, authorize?: false, tenant: workspace.id).detached_rule_provenance ==
               nil
    end

    test "list_workspace_events 行含标记：detach 后有、挂载中/从未挂载为 nil（键恒在）" do
      owner = Fixtures.platform_admin("s3-ev-630-list")
      workspace = Fixtures.create_workspace(owner)
      initiative = mixed_initiative(owner, "s3-ev-630-list-init")

      plain = draft_event(workspace, owner, %{title: "从未挂载"})
      mounted_id = mount_event(owner, workspace, initiative, "挂载中")

      detached_id = mount_event(owner, workspace, initiative, "已摘除")

      detached =
        detached_id
        |> then(&Ash.get!(Event, &1, authorize?: false, tenant: workspace.id))
        |> detach!(owner, workspace)

      assert {:reply, _, _} =
               reply =
               ListWorkspaceEvents.execute(%{"workspace_id" => workspace.id}, frame_for(owner))

      by_id = Map.new(decode_reply(reply)["events"], &{&1["event_id"], &1})

      for id <- [plain.id, mounted_id] do
        assert Map.has_key?(by_id[id], "detached_rule_provenance"),
               "expected key present for #{id}"

        assert by_id[id]["detached_rule_provenance"] == nil
      end

      assert by_id[detached_id]["detached_rule_provenance"] ==
               detached.detached_rule_provenance
    end

    test "公开 MCP 面不透出标记（list/get_public_offering + discover_offerings 负向）" do
      owner = Fixtures.platform_admin("s3-ev-630-public")
      workspace = Fixtures.create_workspace(owner)
      initiative = mixed_initiative(owner, "s3-ev-630-public-init")

      event_id = mount_event(owner, workspace, initiative, "公开已摘除活动")

      detached =
        event_id
        |> then(&Ash.get!(Event, &1, authorize?: false, tenant: workspace.id))
        |> detach!(owner, workspace)

      # 布置而非被测对象：公开面只含 open，直置状态（marker 列不动）
      assert detached.detached_rule_provenance != nil

      Cgc2046.Repo.query!("UPDATE events SET status = 'open' WHERE id = $1", [
        Ecto.UUID.dump!(event_id)
      ])

      outsider = Fixtures.register_user("s3-ev-630-public-outsider")

      assert {:reply, _, _} =
               list_reply =
               ListPublicOfferings.execute(%{"kind" => "event"}, frame_for(outsider))

      [row] = Enum.filter(decode_reply(list_reply)["items"], &(&1["id"] == event_id))
      refute Map.has_key?(row, "detached_rule_provenance")

      assert {:reply, _, _} =
               get_reply =
               GetPublicOffering.execute(
                 %{"id" => event_id, "kind" => "event"},
                 frame_for(outsider)
               )

      refute Map.has_key?(decode_reply(get_reply), "detached_rule_provenance")

      assert {:reply, _, _} =
               discover_reply = DiscoverOfferings.execute(%{}, frame_for(outsider))

      [offering] =
        Enum.filter(decode_reply(discover_reply)["offerings"], &(&1["id"] == event_id))

      refute Map.has_key?(offering, "detached_rule_provenance")
    end
  end

  describe "解除挂载（#632 detach_initiative）" do
    test "端到端：draft 挂载场 detach → 值保留 + 来源标记 + inherited 空壳（响应 == 落库）" do
      owner = Fixtures.platform_admin("s3-ev-632-e2e-owner")
      workspace = Fixtures.create_workspace(owner)
      initiative = mixed_initiative(owner, "s3-ev-632-e2e-init")

      event_id = mount_event(owner, workspace, initiative, "待解除")

      mounted = Ash.get!(Event, event_id, authorize?: false, tenant: workspace.id)
      assert mounted.initiative_id == initiative.id

      assert {:reply, _, _} =
               pending =
               UpdateEvent.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "event_id" => event_id,
                   "detach_initiative" => true
                 },
                 frame_for(owner)
               )

      # 确认流摘要给用户过目：特化渲染（不是 initiative_id → null），含名称与值保留语义
      payload = decode_reply(pending)
      assert payload["summary"] =~ "解除挂载"
      assert payload["summary"] =~ initiative.name
      assert payload["summary"] =~ "值保留在场"

      assert {:reply, _, _} =
               confirmed =
               ConfirmOperation.execute(
                 %{"pending_id" => payload["pending_id"]},
                 frame_for(owner)
               )

      result = decode_reply(confirmed)["result"]

      assert result["initiative"] == nil
      assert result["inherited"] == %{}
      assert "initiative_id" in result["updated_fields"]

      # 只标 locked 规则字段（min_participants / deadline_rule 是挂载快照，不标）
      assert result["detached_rule_provenance"] == %{
               "initiative" => %{
                 "id" => initiative.id,
                 "name" => initiative.name,
                 "slug" => initiative.slug
               },
               "fields" => %{
                 "deposit_amount_cents" => %{"value" => 6900, "source" => "locked"},
                 "deposit_enabled" => %{"value" => true, "source" => "locked"},
                 "min_age" => %{"value" => 18, "source" => "locked"}
               }
             }

      # 响应 == 落库真值；locked 值保留在场（#624 方案 C）
      reloaded = Ash.get!(Event, event_id, authorize?: false, tenant: workspace.id)
      assert reloaded.initiative_id == nil
      assert reloaded.detached_rule_provenance == result["detached_rule_provenance"]
      assert reloaded.min_age == mounted.min_age
      assert reloaded.deposit_enabled == mounted.deposit_enabled
    end

    test "互斥：detach_initiative 与 initiative_id 同传 → 报错不建 pending" do
      owner = Fixtures.platform_admin("s3-ev-632-mutex-owner")
      workspace = Fixtures.create_workspace(owner)
      mounted_initiative = mixed_initiative(owner, "s3-ev-632-mutex-a")
      other_initiative = all_default_initiative(owner, "s3-ev-632-mutex-b")

      event_id = mount_event(owner, workspace, mounted_initiative, "互斥目标")

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               UpdateEvent.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "event_id" => event_id,
                   "detach_initiative" => true,
                   "initiative_id" => other_initiative.id
                 },
                 frame_for(owner)
               )

      assert msg =~ "mutually exclusive"
      assert pending_count() == 0

      # 未动库：挂载原样
      assert Ash.get!(Event, event_id, authorize?: false, tenant: workspace.id).initiative_id ==
               mounted_initiative.id
    end

    test "越权不变：非 Owner/Admin 带 detach_initiative 撞工具层判定，未动库" do
      owner = Fixtures.platform_admin("s3-ev-632-authz-owner")
      workspace = Fixtures.create_workspace(owner)
      initiative = mixed_initiative(owner, "s3-ev-632-authz-init")

      event_id = mount_event(owner, workspace, initiative, "越权目标")

      member = Fixtures.register_user("s3-ev-632-authz-member")
      Fixtures.add_member(workspace, member, [])

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               UpdateEvent.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "event_id" => event_id,
                   "detach_initiative" => true
                 },
                 frame_for(member)
               )

      assert msg =~ "forbidden: owner or admin required"

      assert Ash.get!(Event, event_id, authorize?: false, tenant: workspace.id).initiative_id ==
               initiative.id
    end

    test "幂等：已 detach 再 detach 标记不变；从未挂载 detach 无变化无标记" do
      owner = Fixtures.platform_admin("s3-ev-632-idem-owner")
      workspace = Fixtures.create_workspace(owner)
      initiative = mixed_initiative(owner, "s3-ev-632-idem-init")

      # 已 detach（域侧布置）→ 再走 MCP detach：成功且标记不变
      detached =
        mount_event(owner, workspace, initiative, "已解除再解除")
        |> then(&Ash.get!(Event, &1, authorize?: false, tenant: workspace.id))
        |> detach!(owner, workspace)

      assert {:reply, _, _} =
               pending =
               UpdateEvent.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "event_id" => detached.id,
                   "detach_initiative" => true
                 },
                 frame_for(owner)
               )

      assert {:reply, _, _} =
               confirmed =
               ConfirmOperation.execute(
                 %{"pending_id" => decode_reply(pending)["pending_id"]},
                 frame_for(owner)
               )

      result = decode_reply(confirmed)["result"]
      assert result["detached_rule_provenance"] == detached.detached_rule_provenance

      assert Ash.get!(Event, detached.id, authorize?: false, tenant: workspace.id).detached_rule_provenance ==
               detached.detached_rule_provenance

      # 从未挂载的 draft 场 detach：幂等成功，无标记
      plain = draft_event(workspace, owner, %{title: "从未挂载"})

      assert {:reply, _, _} =
               pending_plain =
               UpdateEvent.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "event_id" => plain.id,
                   "detach_initiative" => true
                 },
                 frame_for(owner)
               )

      assert {:reply, _, _} =
               confirmed_plain =
               ConfirmOperation.execute(
                 %{"pending_id" => decode_reply(pending_plain)["pending_id"]},
                 frame_for(owner)
               )

      result_plain = decode_reply(confirmed_plain)["result"]
      assert result_plain["initiative"] == nil
      assert result_plain["inherited"] == %{}
      assert result_plain["detached_rule_provenance"] == nil
    end

    test "非 draft 挂载中 → 第一段快速失败不建 pending；非 draft 未挂载幂等放行" do
      owner = Fixtures.platform_admin("s3-ev-632-draft-owner")
      workspace = Fixtures.create_workspace(owner)
      initiative = mixed_initiative(owner, "s3-ev-632-draft-init")

      # open + 挂载中（挂载规则所需 starts_at/ends_at/capacity 同 @mounted_event_attrs）
      open_mounted =
        open_event(workspace, owner, %{
          initiative_id: initiative.id,
          starts_at: ~U[2027-01-10 10:00:00Z],
          ends_at: ~U[2027-01-10 12:00:00Z],
          capacity: 50
        })

      assert open_mounted.status == :open
      assert open_mounted.initiative_id == initiative.id

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               UpdateEvent.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "event_id" => open_mounted.id,
                   "detach_initiative" => true
                 },
                 frame_for(owner)
               )

      # 与域层 ensure_mount_state 同一句判据文案
      assert msg =~ "draft"
      assert pending_count() == 0

      assert Ash.get!(Event, open_mounted.id, authorize?: false, tenant: workspace.id).initiative_id ==
               initiative.id

      # 非 draft 未挂载（从未挂载的 open 场）：幂等 detach 无变更，不拦
      open_plain = open_event(workspace, owner, %{title: "未挂载 open 场"})

      assert {:reply, _, _} =
               pending_plain =
               UpdateEvent.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "event_id" => open_plain.id,
                   "detach_initiative" => true
                 },
                 frame_for(owner)
               )

      assert {:reply, _, _} =
               confirmed_plain =
               ConfirmOperation.execute(
                 %{"pending_id" => decode_reply(pending_plain)["pending_id"]},
                 frame_for(owner)
               )

      assert decode_reply(confirmed_plain)["result"]["detached_rule_provenance"] == nil
    end

    test "nil ≠ detach：显式 initiative_id: nil 仍视为未提供，挂载原样保留" do
      owner = Fixtures.platform_admin("s3-ev-632-nil-owner")
      workspace = Fixtures.create_workspace(owner)
      initiative = mixed_initiative(owner, "s3-ev-632-nil-init")

      event_id = mount_event(owner, workspace, initiative, "nil 不解除")

      assert {:reply, _, _} =
               pending =
               UpdateEvent.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "event_id" => event_id,
                   "title" => "改名不改挂载",
                   "initiative_id" => nil
                 },
                 frame_for(owner)
               )

      assert {:reply, _, _} =
               confirmed =
               ConfirmOperation.execute(
                 %{"pending_id" => decode_reply(pending)["pending_id"]},
                 frame_for(owner)
               )

      result = decode_reply(confirmed)["result"]

      # title 改了、挂载保留；initiative_id 不在变更清单
      assert result["initiative"]["id"] == initiative.id
      assert "initiative_id" not in result["updated_fields"]

      reloaded = Ash.get!(Event, event_id, authorize?: false, tenant: workspace.id)
      assert reloaded.title == "改名不改挂载"
      assert reloaded.initiative_id == initiative.id
    end
  end

  describe "update_event（确认流）" do
    test "两段：摘要列出将变更字段 → 无副作用 → confirm 落库" do
      owner = Fixtures.platform_admin("s3-ev-uc-owner")
      workspace = Fixtures.create_workspace(owner)
      event = open_event(workspace, owner, %{title: "旧标题"})

      assert {:reply, _, _} =
               reply =
               UpdateEvent.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "event_id" => event.id,
                   "title" => "新标题",
                   "venue" => @venue
                 },
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"
      assert payload["summary"] =~ "title"
      assert payload["summary"] =~ "新标题"
      assert payload["summary"] =~ "venue"

      # 无副作用
      assert Ash.get!(Event, event.id, authorize?: false).title == "旧标题"

      [log] = tool_logs_for(owner.id, "update_event")
      assert log.result_status == :needs_confirmation

      assert {:reply, _, _} =
               confirm_reply =
               ConfirmOperation.execute(
                 %{"pending_id" => payload["pending_id"]},
                 frame_for(owner)
               )

      confirmed = decode_reply(confirm_reply)
      assert confirmed["status"] == "confirmed"
      assert confirmed["result"]["event_id"] == event.id
      assert Enum.sort(confirmed["result"]["updated_fields"]) == ["title", "venue"]

      updated = Ash.get!(Event, event.id, authorize?: false)
      assert updated.title == "新标题"
      assert updated.venue == @venue
    end

    test "pricing_enabled true→false：摘要含批量免缴影响（笔数），confirm 后待支付报名免缴（R9/KTD4）" do
      owner = Fixtures.platform_admin("s3-ev-uc-pricing")
      workspace = Fixtures.create_workspace(owner)
      event = paid_event(workspace, owner)
      {_l1, enrollment1} = payment_pending_enrollment(event, "s3-ev-uc-p1")
      {_l2, enrollment2} = payment_pending_enrollment(event, "s3-ev-uc-p2")

      {:reply, _, _} =
        reply =
        UpdateEvent.execute(
          %{
            "workspace_id" => workspace.id,
            "event_id" => event.id,
            "pricing_enabled" => false
          },
          frame_for(owner)
        )

      payload = decode_reply(reply)
      assert payload["summary"] =~ "pricing_enabled"
      assert payload["summary"] =~ "批量免缴"
      assert payload["summary"] =~ "2 笔"

      {:reply, _, _} =
        ConfirmOperation.execute(%{"pending_id" => payload["pending_id"]}, frame_for(owner))

      assert Ash.get!(Event, event.id, authorize?: false).pricing_enabled == false
      assert Ash.get!(Enrollment, enrollment1.id, authorize?: false).status == :confirmed
      assert Ash.get!(Enrollment, enrollment2.id, authorize?: false).status == :confirmed
    end

    # #597：MCP 写入路径无法产生「押金开 + 档位非空」。域层拒绝经确认流回到调用方，
    # pending 回滚为 pending（可重试），事件零变化、档位原样保留。
    test "update_event 在有休眠档位的场开押金 → confirm 失败，事件零变化且 pending 回滚" do
      owner = Fixtures.platform_admin("s3-ev-uc-597")
      workspace = Fixtures.create_workspace(owner)

      event =
        draft_event(workspace, owner, %{
          price_tiers: [%{"id" => @tier_id, "name" => "休眠", "amount_cents" => 9900}]
        })

      {:reply, _, _} =
        reply =
        UpdateEvent.execute(
          %{
            "workspace_id" => workspace.id,
            "event_id" => event.id,
            "deposit_enabled" => true,
            "deposit_amount_cents" => 3000,
            "ends_at" => DateTime.to_iso8601(EventFixtures.days_from_now(3)),
            "registration_deadline" => DateTime.to_iso8601(EventFixtures.days_from_now(3))
          },
          frame_for(owner)
        )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"

      pending_id = payload["pending_id"]

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ConfirmOperation.execute(%{"pending_id" => pending_id}, frame_for(owner))

      assert msg =~ "price tiers"

      reloaded = Ash.get!(Event, event.id, authorize?: false)
      assert reloaded.deposit_enabled == false
      assert reloaded.price_tiers == event.price_tiers
      assert Ash.get!(PendingOperation, pending_id, authorize?: false).status == :pending
    end

    # #616：关押金后重开必须显式带金额——第一段快速失败（不建 pending，省一轮
    # 确认）；资源级 `PaymentModeValidation` 同名不变量是 GraphQL 等其他入口的
    # 第二道闸。
    test "update_event 关押金后重开不带金额 → 快速失败，不建 pending" do
      owner = Fixtures.platform_admin("s3-ev-uc-616")
      workspace = Fixtures.create_workspace(owner)

      event =
        open_event(workspace, owner, %{
          deposit_enabled: true,
          deposit_amount_cents: 6900,
          ends_at: EventFixtures.days_from_now(8),
          registration_deadline: EventFixtures.days_from_now(8)
        })

      {:ok, _} =
        event
        |> Ash.Changeset.for_update(:update, %{deposit_enabled: false})
        |> Ash.update(authorize?: false, tenant: workspace.id)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               UpdateEvent.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "event_id" => event.id,
                   "deposit_enabled" => true
                 },
                 frame_for(owner)
               )

      assert msg =~ "event_deposit_amount_must_be_explicit"
      reloaded = Ash.get!(Event, event.id, authorize?: false)
      assert reloaded.deposit_enabled == false
      assert reloaded.deposit_amount_cents == 6900
      assert pending_count() == 0
    end

    test "update_event 重开押金带金额 → pending 摘要含金额，confirm 后按新金额生效" do
      owner = Fixtures.platform_admin("s3-ev-uc-616b")
      workspace = Fixtures.create_workspace(owner)

      event =
        open_event(workspace, owner, %{
          deposit_enabled: true,
          deposit_amount_cents: 6900,
          ends_at: EventFixtures.days_from_now(8),
          registration_deadline: EventFixtures.days_from_now(8)
        })

      {:ok, _} =
        event
        |> Ash.Changeset.for_update(:update, %{deposit_enabled: false})
        |> Ash.update(authorize?: false, tenant: workspace.id)

      {:reply, _, _} =
        reply =
        UpdateEvent.execute(
          %{
            "workspace_id" => workspace.id,
            "event_id" => event.id,
            "deposit_enabled" => true,
            "deposit_amount_cents" => 4200
          },
          frame_for(owner)
        )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"
      # 确认摘要必须披露金额（#616 验收）：不能只显示开关翻转
      assert payload["summary"] =~ "deposit_enabled"
      assert payload["summary"] =~ "deposit_amount_cents"
      assert payload["summary"] =~ "4200"

      {:reply, _, _} =
        ConfirmOperation.execute(%{"pending_id" => payload["pending_id"]}, frame_for(owner))

      reloaded = Ash.get!(Event, event.id, authorize?: false)
      assert reloaded.deposit_enabled == true
      assert reloaded.deposit_amount_cents == 4200
    end

    test "无可更新字段 → 报错不建 pending" do
      owner = Fixtures.platform_admin("s3-ev-uc-none")
      workspace = Fixtures.create_workspace(owner)
      event = open_event(workspace, owner)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               UpdateEvent.execute(
                 %{"workspace_id" => workspace.id, "event_id" => event.id},
                 frame_for(owner)
               )

      assert msg =~ "no updatable fields"
      assert pending_count() == 0
    end

    test "跨租户：他工作台 event_id ≡ not found（不泄露存在性）" do
      owner_a = Fixtures.platform_admin("s3-ev-uc-owner-a")
      workspace_a = Fixtures.create_workspace(owner_a)
      owner_b = Fixtures.platform_admin("s3-ev-uc-owner-b")
      workspace_b = Fixtures.create_workspace(owner_b)
      event_b = open_event(workspace_b, owner_b)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               UpdateEvent.execute(
                 %{
                   "workspace_id" => workspace_a.id,
                   "event_id" => event_b.id,
                   "title" => "越租户改写"
                 },
                 frame_for(owner_a)
               )

      assert msg =~ "event not found"
      assert pending_count() == 0
      assert Ash.get!(Event, event_b.id, authorize?: false).title == "Test Event"
    end
  end

  describe "launch/close/cancel（确认流）" do
    test "launch：draft → open（两段；第一段仍 draft）" do
      owner = Fixtures.platform_admin("s3-ev-launch-owner")
      workspace = Fixtures.create_workspace(owner)
      event = draft_event(workspace, owner)

      assert {:reply, _, _} =
               reply =
               LaunchEvent.execute(
                 %{"workspace_id" => workspace.id, "event_id" => event.id},
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"
      assert payload["summary"] =~ event.id
      assert payload["summary"] =~ "draft → open"

      assert Ash.get!(Event, event.id, authorize?: false).status == :draft

      assert {:reply, _, _} =
               confirm_reply =
               ConfirmOperation.execute(
                 %{"pending_id" => payload["pending_id"]},
                 frame_for(owner)
               )

      confirmed = decode_reply(confirm_reply)
      assert confirmed["result"]["status"] == "open"
      assert Ash.get!(Event, event.id, authorize?: false).status == :open
    end

    test "close：open → closed；cancel：open → cancelled（摘要含终态不可逆提示）" do
      owner = Fixtures.platform_admin("s3-ev-cc-lc-owner")
      workspace = Fixtures.create_workspace(owner)
      event = open_event(workspace, owner)

      for {module, tool, expected} <- [
            {CloseEvent, "close_event", "closed"},
            {CancelEvent, "cancel_event", "cancelled"}
          ] do
        {:reply, _, _} =
          reply =
          apply(module, :execute, [
            %{"workspace_id" => workspace.id, "event_id" => event.id},
            frame_for(owner)
          ])

        payload = decode_reply(reply)
        assert payload["status"] == "needs_confirmation"
        assert payload["summary"] =~ "终态不可逆"
        assert Ash.get!(Event, event.id, authorize?: false).status == :open

        {:reply, _, _} =
          ConfirmOperation.execute(%{"pending_id" => payload["pending_id"]}, frame_for(owner))

        assert Ash.get!(Event, event.id, authorize?: false).status ==
                 String.to_existing_atom(expected)

        # 回到 open 供下一段（布置而非被测对象）
        {:ok, _} =
          Cgc2046.Repo.query("UPDATE events SET status = 'open' WHERE id = $1", [
            Ecto.UUID.dump!(event.id)
          ])

        [log] = tool_logs_for(owner.id, tool)
        assert log.result_status == :needs_confirmation
      end
    end

    test "错误路径：launch 已 open 活动 → 报错不建 pending" do
      owner = Fixtures.platform_admin("s3-ev-launch-open")
      workspace = Fixtures.create_workspace(owner)
      event = open_event(workspace, owner)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               LaunchEvent.execute(
                 %{"workspace_id" => workspace.id, "event_id" => event.id},
                 frame_for(owner)
               )

      assert msg =~ "cannot launch from status=open"
      assert pending_count() == 0
    end

    test "错误路径：close draft 活动 → 报错不建 pending" do
      owner = Fixtures.platform_admin("s3-ev-close-draft")
      workspace = Fixtures.create_workspace(owner)
      event = draft_event(workspace, owner)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               CloseEvent.execute(
                 %{"workspace_id" => workspace.id, "event_id" => event.id},
                 frame_for(owner)
               )

      assert msg =~ "cannot close from status=draft"
      assert pending_count() == 0
    end
  end

  describe "delete_event（#676 draft 删除；Owner ∪ 平台管理员）" do
    test "两段式：摘要含不可恢复与 slug；confirm 后行删除并回传 event_id/title/slug" do
      owner = Fixtures.platform_admin("s3-ev-del-owner")
      workspace = Fixtures.create_workspace(owner)
      event = draft_event(workspace, owner, %{title: "错建活动", slug: "s3-ev-del-draft"})

      assert {:reply, _, _} =
               reply =
               DeleteEvent.execute(
                 %{"workspace_id" => workspace.id, "event_id" => event.id},
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"
      assert payload["summary"] =~ "不可恢复"

      # #688 连带披露：主理人指派 + 讲者邀请（draft 合法）+ 邀请批次 + 留痕
      assert payload["summary"] =~ "主理人指派"
      assert payload["summary"] =~ "讲者邀请记录"
      assert payload["summary"] =~ "留痕"
      assert payload["summary"] =~ event.slug

      # 无副作用：第一段不落库
      assert Ash.get!(Event, event.id, authorize?: false).status == :draft

      assert {:reply, _, _} =
               confirm_reply =
               ConfirmOperation.execute(
                 %{"pending_id" => payload["pending_id"]},
                 frame_for(owner)
               )

      result = decode_reply(confirm_reply)["result"]
      assert result["event_id"] == event.id
      assert result["title"] == "错建活动"
      assert result["slug"] == "s3-ev-del-draft"

      assert_deleted(event.id)

      [log] = tool_logs_for(owner.id, "delete_event")
      assert log.result_status == :needs_confirmation
    end

    test "非 draft 快速失败（open → 报错不建 pending）" do
      owner = Fixtures.platform_admin("s3-ev-del-open")
      workspace = Fixtures.create_workspace(owner)
      event = open_event(workspace, owner)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               DeleteEvent.execute(
                 %{"workspace_id" => workspace.id, "event_id" => event.id},
                 frame_for(owner)
               )

      assert msg =~ "cannot delete from status=open"
      assert msg =~ "仅 draft 可删除"
      assert pending_count() == 0
      assert Ash.get!(Event, event.id, authorize?: false).status == :open
    end

    test "权限矩阵：admin ❌ / learner ❌ / 成员平台管理员 ✅" do
      owner = Fixtures.platform_admin("s3-ev-del-matrix")
      workspace = Fixtures.create_workspace(owner)

      admin_only = Fixtures.register_user("s3-ev-del-admin")
      Fixtures.add_member(workspace, admin_only, [:admin])
      learner = Fixtures.register_user("s3-ev-del-learner")
      Fixtures.add_member(workspace, learner, [:learner])

      admin_event = draft_event(workspace, owner, %{slug: "s3-ev-del-admin-event"})
      learner_event = draft_event(workspace, owner, %{slug: "s3-ev-del-learner-event"})

      for {user, event} <- [{admin_only, admin_event}, {learner, learner_event}] do
        assert {:error, %Anubis.MCP.Error{message: msg}, _} =
                 DeleteEvent.execute(
                   %{"workspace_id" => workspace.id, "event_id" => event.id},
                   frame_for(user)
                 )

        assert msg =~ "owner or platform admin required"
        assert msg =~ "delete events"
        assert Ash.get!(Event, event.id, authorize?: false).status == :draft
      end

      assert pending_count() == 0

      # 成员平台管理员（无 owner 角色）走收窄面的平台管理员分支
      platform = Fixtures.platform_admin("s3-ev-del-platform")
      Fixtures.add_member(workspace, platform, [])
      platform_event = draft_event(workspace, owner, %{slug: "s3-ev-del-platform-event"})

      assert {:reply, _, _} =
               reply =
               DeleteEvent.execute(
                 %{"workspace_id" => workspace.id, "event_id" => platform_event.id},
                 frame_for(platform)
               )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"

      {:reply, _, _} =
        ConfirmOperation.execute(%{"pending_id" => payload["pending_id"]}, frame_for(platform))

      assert_deleted(platform_event.id)
    end
  end

  describe "list_workspace_events（member-only 活动发现面）" do
    test "member 见本台全部状态活动（含 draft）与报名徽章；status 过滤；非 member forbidden" do
      owner = Fixtures.platform_admin("s3-ev-lwe-owner")
      workspace = Fixtures.create_workspace(owner)
      member = Fixtures.register_user("s3-ev-lwe-member")
      Fixtures.add_member(workspace, member, [])

      draft = draft_event(workspace, owner, %{title: "Draft 活动"})
      open = open_event(workspace, owner, %{title: "Open 活动"})

      assert {:reply, _, _} =
               reply =
               ListWorkspaceEvents.execute(%{"workspace_id" => workspace.id}, frame_for(member))

      payload = decode_reply(reply)
      assert payload["count"] == 2

      by_id = Map.new(payload["events"], &{&1["event_id"], &1})
      assert by_id[draft.id]["status"] == "draft"
      assert by_id[open.id]["status"] == "open"

      assert by_id[open.id]["enrollment_badge"] in [
               "enrolling",
               "starting_soon",
               "closed",
               "full"
             ]

      # status 过滤收窄
      assert {:reply, _, _} =
               filtered =
               ListWorkspaceEvents.execute(
                 %{"workspace_id" => workspace.id, "status" => "draft"},
                 frame_for(member)
               )

      assert [row] = decode_reply(filtered)["events"]
      assert row["event_id"] == draft.id

      # 非 member 撞 Wrapper member 门
      outsider = Fixtures.register_user("s3-ev-lwe-outsider")

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ListWorkspaceEvents.execute(%{"workspace_id" => workspace.id}, frame_for(outsider))

      assert msg =~ "not a member"
    end

    test "跨租户隔离：他工作台活动不漏" do
      owner_a = Fixtures.platform_admin("s3-ev-lwe-owner-a")
      workspace_a = Fixtures.create_workspace(owner_a)
      event_a = open_event(workspace_a, owner_a)

      owner_b = Fixtures.platform_admin("s3-ev-lwe-owner-b")
      workspace_b = Fixtures.create_workspace(owner_b)
      event_b = open_event(workspace_b, owner_b)

      {:reply, _, _} =
        reply =
        ListWorkspaceEvents.execute(%{"workspace_id" => workspace_a.id}, frame_for(owner_a))

      ids = Enum.map(decode_reply(reply)["events"], & &1["event_id"])
      assert event_a.id in ids
      refute event_b.id in ids
    end

    test "缴费槽（#586）：押金场出 payment_mode=deposit + 金额/到场退；免费/定价场关闭态形状恒定" do
      owner = Fixtures.platform_admin("s3-ev-lwe-slot")
      workspace = Fixtures.create_workspace(owner)

      deposit =
        open_event(workspace, owner, %{
          title: "押金活动",
          deposit_enabled: true,
          deposit_amount_cents: 6900,
          ends_at: EventFixtures.days_from_now(8)
        })

      free = open_event(workspace, owner, %{title: "免费活动"})
      pricing = paid_event(workspace, owner)

      assert {:reply, _, _} =
               reply =
               ListWorkspaceEvents.execute(%{"workspace_id" => workspace.id}, frame_for(owner))

      by_id = Map.new(decode_reply(reply)["events"], &{&1["event_id"], &1})

      assert by_id[deposit.id]["payment_mode"] == "deposit"

      assert by_id[deposit.id]["deposit"] == %{
               "enabled" => true,
               "amount_cents" => 6900,
               "refundable_on_check_in" => true
             }

      assert by_id[free.id]["payment_mode"] == "free"
      assert by_id[pricing.id]["payment_mode"] == "pricing"

      for id <- [free.id, pricing.id] do
        assert by_id[id]["deposit"] == %{
                 "enabled" => false,
                 "amount_cents" => nil,
                 "refundable_on_check_in" => nil
               }
      end
    end
  end

  describe "list_enrollments（kind=event 分派）" do
    test "Owner 见本活动报名（报名人摘要/状态/档位）；跨 kind 隔离（同工作台课程报名不漏）" do
      owner = Fixtures.platform_admin("s3-ev-le-owner")
      workspace = Fixtures.create_workspace(owner)
      event = paid_event(workspace, owner)
      {learner, enrollment} = payment_pending_enrollment(event, "s3-ev-le-paid")

      # 同工作台课程报名不得漏进活动列表（跨 kind 隔离）
      course = EventFixtures.create_course(workspace, owner)
      course_learner = Fixtures.register_user("s3-ev-le-course")

      {:ok, _course_enrollment} =
        Enrollment
        |> Ash.Changeset.for_create(
          :create_enrollment,
          %{course_id: course.id, user_id: course_learner.id}
        )
        |> Ash.create(tenant: workspace.id, actor: course_learner)

      assert {:reply, _, _} =
               reply =
               ListEnrollments.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "kind" => "event",
                   "offering_id" => event.id
                 },
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["kind"] == "event"
      assert payload["offering_id"] == event.id
      assert payload["count"] == 1

      [row] = payload["enrollments"]
      assert row["enrollment_id"] == enrollment.id
      assert row["status"] == "payment_pending"
      assert row["user"]["id"] == learner.id
      assert row["tier"]["id"] == @tier_id
    end

    test "非法 kind → 参数错误；他工作台 event offering_id = not found" do
      owner = Fixtures.platform_admin("s3-ev-le-kind-owner")
      workspace = Fixtures.create_workspace(owner)
      event = open_event(workspace, owner)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ListEnrollments.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "kind" => "bogus",
                   "offering_id" => event.id
                 },
                 frame_for(owner)
               )

      assert msg =~ "invalid kind"

      owner_b = Fixtures.platform_admin("s3-ev-le-kind-owner-b")
      workspace_b = Fixtures.create_workspace(owner_b)
      event_b = open_event(workspace_b, owner_b)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ListEnrollments.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "kind" => "event",
                   "offering_id" => event_b.id
                 },
                 frame_for(owner)
               )

      assert msg =~ "event not found"
    end
  end

  describe "confirm_enrollment（event 投影）" do
    test "request 活动 pending → confirmed；成功返回投影含 event_id、course_id 为 nil" do
      owner = Fixtures.platform_admin("s3-ev-ce-owner")
      workspace = Fixtures.create_workspace(owner)
      event = open_event(workspace, owner, %{enrollment_policy: :request})
      learner = Fixtures.register_user("s3-ev-ce-learner")
      enrollment = enroll(event, learner)
      assert enrollment.status == :pending

      assert {:reply, _, _} =
               reply =
               ConfirmEnrollment.execute(
                 %{"workspace_id" => workspace.id, "enrollment_id" => enrollment.id},
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"

      assert {:reply, _, _} =
               confirm_reply =
               ConfirmOperation.execute(
                 %{"pending_id" => payload["pending_id"]},
                 frame_for(owner)
               )

      confirmed = decode_reply(confirm_reply)
      assert confirmed["result"]["status"] == "confirmed"
      assert confirmed["result"]["event_id"] == event.id
      assert confirmed["result"]["course_id"] == nil

      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :confirmed
    end
  end

  describe "assign_event_moderator（#539 三锚点指派）" do
    setup do
      owner = Fixtures.platform_admin("539-owner")
      workspace = Fixtures.create_workspace(owner)
      event = EventFixtures.create_event(workspace, owner)
      %{owner: owner, workspace: workspace, event: event}
    end

    test "三锚点命中：email（大小写混合）/ CGC 编号（小写）/ UUID（大写），响应 user_id 为解析后落库 UUID",
         %{owner: owner, workspace: workspace, event: event} do
      user = Fixtures.register_user_with_email("mcp-anchor@example.com")
      Fixtures.add_member(workspace, user, [:learner])

      anchors = [
        "Mcp-Anchor@Example.com",
        String.downcase(expected_member_number(user.id)),
        String.upcase(user.id)
      ]

      for anchor <- anchors do
        assert {:reply, _, _} =
                 reply =
                 AssignEventModerator.execute(
                   %{"workspace_id" => workspace.id, "event_id" => event.id, "user_id" => anchor},
                   frame_for(owner)
                 ),
               "anchor: #{anchor}"

        payload = decode_reply(reply)
        assert payload["user_id"] == user.id, "anchor: #{anchor}"
        assert is_binary(payload["moderator_id"])

        # 同用户连续三锚：前一次指派先撤销，撞不到 already_assigned
        assert :ok = Moderators.remove(payload["moderator_id"], workspace.id, owner)
      end
    end

    test "任一锚未命中统一 user_not_found 前缀透传（不落笼统 fallback）", %{
      owner: owner,
      workspace: workspace,
      event: event
    } do
      for anchor <- [
            "nobody-539@example.com",
            "cgc-000000",
            Ecto.UUID.generate(),
            "not-an-anchor"
          ] do
        assert {:error, %Anubis.MCP.Error{message: msg}, _} =
                 AssignEventModerator.execute(
                   %{"workspace_id" => workspace.id, "event_id" => event.id, "user_id" => anchor},
                   frame_for(owner)
                 ),
               "anchor: #{anchor}"

        assert msg =~ "user_not_found", "anchor: #{anchor}"
        # 变异点：删工具内 BusinessError 子句 → 坍缩回 fallback，此断言红
        refute msg =~ "failed to assign moderator", "anchor: #{anchor}"
      end
    end

    test "CGC 前缀命中多人 user_anchor_ambiguous + 引导换用户 ID", %{
      owner: owner,
      workspace: workspace,
      event: event
    } do
      user_a = Fixtures.register_user_with_email("ambiguous-a-539@example.com")
      Fixtures.add_member(workspace, user_a, [:learner])

      prefix = user_a.id |> String.replace("-", "") |> String.slice(0, 6)
      hex_b = prefix <> (:crypto.strong_rand_bytes(13) |> Base.encode16(case: :lower))

      <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
        e::binary-size(12)>> = hex_b

      register_user_with_uuid("ambiguous-b-539@example.com", "#{a}-#{b}-#{c}-#{d}-#{e}")

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               AssignEventModerator.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "event_id" => event.id,
                   "user_id" => "cgc-" <> String.downcase(prefix)
                 },
                 frame_for(owner)
               )

      assert msg =~ "user_anchor_ambiguous"
      assert msg =~ "use the user ID"
    end

    test "越权双层门：learner 即便持不存在锚也只拿 forbidden（权限先于解析，防探测）；非成员撞 member 门",
         %{owner: owner, workspace: workspace, event: event} do
      learner = Fixtures.register_user("539-learner")
      Fixtures.add_member(workspace, learner, [:learner])

      for anchor <- ["ghost-539@example.com", Ecto.UUID.generate()] do
        assert {:error, %Anubis.MCP.Error{message: msg}, _} =
                 AssignEventModerator.execute(
                   %{"workspace_id" => workspace.id, "event_id" => event.id, "user_id" => anchor},
                   frame_for(learner)
                 ),
               "anchor: #{anchor}"

        assert msg =~ "forbidden: owner or admin required"

        # 权限门先于解析：越权者探测不到 user_not_found（#537 域序，MCP 面钉住）
        refute msg =~ "user_not_found"
      end

      outsider = Fixtures.register_user("539-outsider")

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               AssignEventModerator.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "event_id" => event.id,
                   "user_id" => "ghost-539@example.com"
                 },
                 frame_for(outsider)
               )

      assert msg =~ "not a member"
    end

    test "重复指派走 Invalid 树折叠文案，不经新子句（code 前缀形状不出现）", %{
      owner: owner,
      workspace: workspace,
      event: event
    } do
      user = Fixtures.register_user_with_email("dup-539@example.com")
      Fixtures.add_member(workspace, user, [:learner])

      # user.email 加载后是 Ash.CiString；MCP 线上入参恒为 JSON string——
      # 测试直调给字面量，与生产形状一致（两次同锚指派共用）
      first_assign = %{
        "workspace_id" => workspace.id,
        "event_id" => event.id,
        "user_id" => "dup-539@example.com"
      }

      assert {:reply, _, _} = AssignEventModerator.execute(first_assign, frame_for(owner))

      # 同 email 锚二次指派：解析成功后撞 identity 唯一索引 → Ash.Error.Invalid
      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               AssignEventModerator.execute(first_assign, frame_for(owner))

      assert msg =~ "already a moderator"
      # Invalid 树路径保持既有折叠行为：不带 "<code>: " 前缀形状
      refute msg =~ "event_moderator_already_assigned: "
    end

    test "list_event_moderators 行带回显平铺字段（display_name 可空、member_number 恒有值）",
         %{owner: owner, workspace: workspace, event: event} do
      owner
      |> Ash.Changeset.for_update(:update_display_name, %{display_name: "台主"})
      |> Ash.update!(actor: owner)

      user = Fixtures.register_user_with_email("echo-539@example.com")
      Fixtures.add_member(workspace, user, [:learner])

      # user.email 是 Ash.CiString，测试直调给字面量与生产 JSON 入参形状一致
      assert {:reply, _, _} =
               AssignEventModerator.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "event_id" => event.id,
                   "user_id" => "echo-539@example.com"
                 },
                 frame_for(owner)
               )

      assert {:reply, _, _} =
               reply =
               ListEventModerators.execute(
                 %{"workspace_id" => workspace.id, "event_id" => event.id},
                 frame_for(owner)
               )

      rows = decode_reply(reply)["moderators"]
      row = Enum.find(rows, &(&1["user_id"] == user.id))

      assert row["user_display_name"] == nil
      assert row["user_member_number"] == expected_member_number(user.id)
      assert row["assigned_by_display_name"] == "台主"
      assert row["assigned_by_member_number"] == expected_member_number(owner.id)
    end
  end

  defp expected_member_number(uuid),
    do: "CGC-" <> (uuid |> String.replace("-", "") |> String.slice(0, 6) |> String.upcase())

  # 歧义布置（域层同款手法）：force 指定 uuid，测试需要前缀可控
  defp register_user_with_uuid(email, uuid) do
    Cgc2046.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: email,
      password: Fixtures.password()
    })
    |> Ash.Changeset.force_change_attribute(:id, uuid)
    |> Ash.create!(authorize?: false)
  end
end
