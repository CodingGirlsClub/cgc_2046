defmodule Cgc2046.Mcp.PublicOfferingToolsTest do
  @moduledoc """
  公开浏览两工具测试（U2，R4/R5/R16/R11 数据面，KTD2/KTD3/KTD4；直接调 tool execute/2，不走 HTTP）。

  场景（按 plan U2）：
  1. 零成员身份的连接 token 调用成功；成员调用者与匿名逐字段一致（parity 最高危面，KTD2）
  2. draft / workspace-only 条目对任何调用者（含 owner 自己）不可见
  3. 过滤：kind / city / starts_after / starts_before 各一命例；city 不作用于 course；
     无时间条目计入 undated_count；默认「近期」口径 = starts_at >= now ∪ 无时间条目
  4. get_public_offering 按 id 取全白名单字段；非公开 id 与「不存在」同一拒绝
  5. 每次调用落 ToolCallLog 审计行，params 经 Redact
  """
  use Cgc2046.DataCase, async: true

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Event
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Mcp.ToolCallLog
  alias Cgc2046.Mcp.Tools.GetPublicOffering
  alias Cgc2046.Mcp.Tools.ListPublicOfferings

  require Ash.Query

  @venue_beijing %{"country" => "中国", "province" => "北京市", "city" => "北京", "district" => "海淀区"}
  @venue_shanghai %{
    "country" => "中国",
    "province" => "上海市",
    "city" => "Shanghai",
    "district" => "Pudong"
  }

  defp frame_for(user), do: Frame.new(current_user: user)

  defp decode({:reply, response, _frame}) do
    [content] = response.content
    Jason.decode!(content["text"])
  end

  # draft 布置：状态机无直达 draft 保持外的公开 action，fixtures 默认 force_open，
  # 此处直走 create（不入 force_open）。
  defp draft_event(workspace, actor, attrs) do
    Event
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :title, "草稿活动"), tenant: workspace.id)
    |> Ash.create!(tenant: workspace.id, actor: actor)
  end

  defp tool_logs_for(user_id, tool_name) do
    ToolCallLog
    |> Ash.Query.filter(user_id == ^user_id and tool == ^tool_name)
    |> Ash.read!(authorize?: false)
  end

  defp list_ids(payload), do: Enum.map(payload["items"], & &1["id"])

  describe "场景 1:零成员身份可用 + 成员 parity(KTD2)" do
    test "零成员身份（无任何 workspace 成员资格）调用成功，跨工作区可见" do
      admin_a = Fixtures.platform_admin("po-parity-a")
      workspace_a = Fixtures.create_workspace(admin_a)
      admin_b = Fixtures.platform_admin("po-parity-b")
      workspace_b = Fixtures.create_workspace(admin_b)

      event_a = EventFixtures.create_event(workspace_a, admin_a, %{title: "A 区活动"})
      course_b = EventFixtures.create_course(workspace_b, admin_b, %{title: "B 区课程"})

      outsider = Fixtures.register_user("po-parity-outsider")

      assert {:reply, _, _} = reply = ListPublicOfferings.execute(%{}, frame_for(outsider))
      payload = decode(reply)

      ids = list_ids(payload)
      assert event_a.id in ids
      assert course_b.id in ids
    end

    test "成员调用者返回与零成员调用者逐字段一致，不超标" do
      admin = Fixtures.platform_admin("po-parity-m")
      workspace = Fixtures.create_workspace(admin)

      EventFixtures.create_event(workspace, admin, %{
        title: "parity 活动",
        capacity: 5,
        venue: @venue_beijing,
        starts_at: EventFixtures.days_from_now(3)
      })

      EventFixtures.create_course(workspace, admin, %{title: "parity 课程", capacity: 9})

      outsider = Fixtures.register_user("po-parity-m-outsider")
      member = Fixtures.register_user("po-parity-m-member")
      Fixtures.add_member(workspace, member, [:learner])

      assert {:reply, _, _} = anon_reply = ListPublicOfferings.execute(%{}, frame_for(outsider))
      assert {:reply, _, _} = member_reply = ListPublicOfferings.execute(%{}, frame_for(member))

      assert decode(anon_reply) == decode(member_reply)

      # get 面 parity 同钉
      [first | _] = decode(anon_reply)["items"]

      assert {:reply, _, _} =
               anon_get =
               GetPublicOffering.execute(%{"id" => first["id"]}, frame_for(outsider))

      assert {:reply, _, _} =
               member_get =
               GetPublicOffering.execute(%{"id" => first["id"]}, frame_for(member))

      assert decode(anon_get) == decode(member_get)
    end

    test "紧凑行字段恰为白名单（无 description / capacity / confirmed_count / workspace_id）" do
      admin = Fixtures.platform_admin("po-shape")
      workspace = Fixtures.create_workspace(admin)

      EventFixtures.create_event(workspace, admin, %{
        capacity: 3,
        venue: @venue_beijing,
        starts_at: EventFixtures.days_from_now(2)
      })

      outsider = Fixtures.register_user("po-shape-user")

      assert {:reply, _, _} = reply = ListPublicOfferings.execute(%{}, frame_for(outsider))
      [row | _] = decode(reply)["items"]

      assert Map.keys(row) |> Enum.sort() ==
               ~w(badge city district id kind slug starts_at title)
    end

    test "传入 workspace_id 不改变跨工作区口径（KTD3 豁免语义）" do
      admin_a = Fixtures.platform_admin("po-scope-a")
      workspace_a = Fixtures.create_workspace(admin_a)
      admin_b = Fixtures.platform_admin("po-scope-b")
      workspace_b = Fixtures.create_workspace(admin_b)

      event_a = EventFixtures.create_event(workspace_a, admin_a, %{title: "A"})
      event_b = EventFixtures.create_event(workspace_b, admin_b, %{title: "B"})

      outsider = Fixtures.register_user("po-scope-user")

      assert {:reply, _, _} =
               reply =
               ListPublicOfferings.execute(
                 %{"workspace_id" => workspace_a.id},
                 frame_for(outsider)
               )

      ids = list_ids(decode(reply))
      assert event_a.id in ids
      assert event_b.id in ids
    end

    test "无连接 token（无 actor）拒绝" do
      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ListPublicOfferings.execute(%{}, Frame.new())

      assert msg =~ "unauthenticated"
    end
  end

  describe "场景 2:draft / workspace-only 对任何调用者不可见" do
    test "owner 自己也看不到 draft 与 workspace-only 条目（list 与 get 同口径）" do
      admin = Fixtures.platform_admin("po-hide")
      workspace = Fixtures.create_workspace(admin)

      draft = draft_event(workspace, admin, %{})
      hidden = EventFixtures.create_event(workspace, admin, %{visibility: :workspace})
      visible = EventFixtures.create_event(workspace, admin, %{title: "公开活动"})

      assert {:reply, _, _} = reply = ListPublicOfferings.execute(%{}, frame_for(admin))
      ids = list_ids(decode(reply))

      assert visible.id in ids
      refute draft.id in ids
      refute hidden.id in ids

      # get：非公开 id 与不存在同一拒绝
      assert {:error, %Anubis.MCP.Error{message: draft_msg}, _} =
               GetPublicOffering.execute(%{"id" => draft.id}, frame_for(admin))

      assert {:error, %Anubis.MCP.Error{message: hidden_msg}, _} =
               GetPublicOffering.execute(%{"id" => hidden.id}, frame_for(admin))

      missing_id = Ash.UUID.generate()

      assert {:error, %Anubis.MCP.Error{message: missing_msg}, _} =
               GetPublicOffering.execute(%{"id" => missing_id}, frame_for(admin))

      # 同一拒绝形状（「id 不存在」模板），不区分 draft / workspace-only / 真不存在
      assert draft_msg == "public offering not found: #{draft.id}"
      assert hidden_msg == "public offering not found: #{hidden.id}"
      assert missing_msg == "public offering not found: #{missing_id}"
    end
  end

  describe "场景 3:过滤与排序（R5/KTD4）" do
    test "kind=event 只出活动；kind=course 只出课程" do
      admin = Fixtures.platform_admin("po-kind")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{title: "活动"})
      course = EventFixtures.create_course(workspace, admin, %{title: "课程"})
      outsider = Fixtures.register_user("po-kind-user")

      assert {:reply, _, _} =
               ev = ListPublicOfferings.execute(%{"kind" => "event"}, frame_for(outsider))

      ev_payload = decode(ev)
      assert list_ids(ev_payload) == [event.id]
      assert hd(ev_payload["items"])["kind"] == "event"

      assert {:reply, _, _} =
               co = ListPublicOfferings.execute(%{"kind" => "course"}, frame_for(outsider))

      co_payload = decode(co)
      assert list_ids(co_payload) == [course.id]
      assert hd(co_payload["items"])["kind"] == "course"
    end

    test "非法 kind 报错" do
      outsider = Fixtures.register_user("po-kind-bad")

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ListPublicOfferings.execute(%{"kind" => "webinar"}, frame_for(outsider))

      assert msg =~ "kind"
    end

    test "city 跨 city/province/district 大小写不敏感 contains，且不作用于 course" do
      admin = Fixtures.platform_admin("po-city")
      workspace = Fixtures.create_workspace(admin)

      beijing = EventFixtures.create_event(workspace, admin, %{venue: @venue_beijing})
      shanghai = EventFixtures.create_event(workspace, admin, %{venue: @venue_shanghai})
      course = EventFixtures.create_course(workspace, admin, %{title: "线上课程"})
      outsider = Fixtures.register_user("po-city-user")

      # city 命中
      assert {:reply, _, _} =
               r1 = ListPublicOfferings.execute(%{"city" => "北京"}, frame_for(outsider))

      ids1 = list_ids(decode(r1))
      assert beijing.id in ids1
      refute shanghai.id in ids1
      # city 不作用于 course：线上课程不受地点过滤影响
      assert course.id in ids1

      # district 命中
      assert {:reply, _, _} =
               r2 = ListPublicOfferings.execute(%{"city" => "海淀"}, frame_for(outsider))

      assert beijing.id in list_ids(decode(r2))

      # province 命中
      assert {:reply, _, _} =
               r3 = ListPublicOfferings.execute(%{"city" => "北京市"}, frame_for(outsider))

      assert beijing.id in list_ids(decode(r3))

      # 大小写不敏感
      assert {:reply, _, _} =
               r4 = ListPublicOfferings.execute(%{"city" => "shanghai"}, frame_for(outsider))

      ids4 = list_ids(decode(r4))
      assert shanghai.id in ids4
      refute beijing.id in ids4
    end

    test "默认「近期」口径：过去开始的条目排除，无时间条目保留并计入 undated_count" do
      admin = Fixtures.platform_admin("po-recent")
      workspace = Fixtures.create_workspace(admin)

      past =
        EventFixtures.create_event(workspace, admin, %{starts_at: EventFixtures.days_from_now(-1)})

      future =
        EventFixtures.create_event(workspace, admin, %{starts_at: EventFixtures.days_from_now(3)})

      undated = EventFixtures.create_event(workspace, admin, %{})
      outsider = Fixtures.register_user("po-recent-user")

      assert {:reply, _, _} = reply = ListPublicOfferings.execute(%{}, frame_for(outsider))
      payload = decode(reply)
      ids = list_ids(payload)

      refute past.id in ids
      assert future.id in ids
      assert undated.id in ids
      assert payload["undated_count"] == 1
      assert payload["total_count"] == 2
    end

    test "starts_after / starts_before 过滤：无时间条目被排除但计入 undated_count" do
      admin = Fixtures.platform_admin("po-time")
      workspace = Fixtures.create_workspace(admin)

      soon =
        EventFixtures.create_event(workspace, admin, %{starts_at: EventFixtures.days_from_now(2)})

      later =
        EventFixtures.create_event(workspace, admin, %{starts_at: EventFixtures.days_from_now(9)})

      _undated = EventFixtures.create_event(workspace, admin, %{})
      outsider = Fixtures.register_user("po-time-user")

      # starts_after = now+5d：只留 later；undated 排除但计数
      after_dt = EventFixtures.days_from_now(5) |> DateTime.to_iso8601()

      assert {:reply, _, _} =
               r1 =
               ListPublicOfferings.execute(%{"starts_after" => after_dt}, frame_for(outsider))

      p1 = decode(r1)
      assert list_ids(p1) == [later.id]
      assert p1["undated_count"] == 1

      # starts_before = now+5d：只留 soon
      before_dt = EventFixtures.days_from_now(5) |> DateTime.to_iso8601()

      assert {:reply, _, _} =
               r2 =
               ListPublicOfferings.execute(%{"starts_before" => before_dt}, frame_for(outsider))

      p2 = decode(r2)
      assert list_ids(p2) == [soon.id]
      assert p2["undated_count"] == 1

      # 双界夹逼：now+1d ~ now+5d → soon
      assert {:reply, _, _} =
               r3 =
               ListPublicOfferings.execute(
                 %{
                   "starts_after" => EventFixtures.days_from_now(1) |> DateTime.to_iso8601(),
                   "starts_before" => before_dt
                 },
                 frame_for(outsider)
               )

      assert list_ids(decode(r3)) == [soon.id]
    end

    test "非法时间参数报错" do
      outsider = Fixtures.register_user("po-time-bad")

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ListPublicOfferings.execute(%{"starts_after" => "not-a-date"}, frame_for(outsider))

      assert msg =~ "starts_after"
    end

    test "排序：starts_at 升序、无时间条目在最后" do
      admin = Fixtures.platform_admin("po-sort")
      workspace = Fixtures.create_workspace(admin)

      later =
        EventFixtures.create_event(workspace, admin, %{starts_at: EventFixtures.days_from_now(8)})

      sooner =
        EventFixtures.create_event(workspace, admin, %{starts_at: EventFixtures.days_from_now(2)})

      undated = EventFixtures.create_event(workspace, admin, %{})
      outsider = Fixtures.register_user("po-sort-user")

      assert {:reply, _, _} = reply = ListPublicOfferings.execute(%{}, frame_for(outsider))
      assert list_ids(decode(reply)) == [sooner.id, later.id, undated.id]
    end

    test "limit 20：超出截断，total_count 为截断前命中小计" do
      admin = Fixtures.platform_admin("po-limit")
      workspace = Fixtures.create_workspace(admin)

      for i <- 1..21 do
        EventFixtures.create_event(workspace, admin, %{title: "活动 #{i}"})
      end

      outsider = Fixtures.register_user("po-limit-user")

      assert {:reply, _, _} = reply = ListPublicOfferings.execute(%{}, frame_for(outsider))
      payload = decode(reply)

      assert length(payload["items"]) == 20
      assert payload["total_count"] == 21
      assert payload["undated_count"] == 21
    end

    test "空结果：items 为空、total_count 为 0（agent 直说没有，R11 数据面）" do
      admin = Fixtures.platform_admin("po-empty")
      workspace = Fixtures.create_workspace(admin)
      EventFixtures.create_event(workspace, admin, %{venue: @venue_beijing})
      outsider = Fixtures.register_user("po-empty-user")

      assert {:reply, _, _} =
               reply =
               ListPublicOfferings.execute(%{"city" => "不存在的城市"}, frame_for(outsider))

      payload = decode(reply)
      assert payload["items"] == []
      assert payload["total_count"] == 0
      # 无时间条目仍计数（北京活动无 starts_at）
      assert payload["undated_count"] == 0
    end
  end

  describe "场景 4:get_public_offering 全白名单字段（R16）" do
    test "按 id 取活动全字段（含 description / pricingEnabled / availablePriceTiers / venue / 赞助键）" do
      admin = Fixtures.platform_admin("po-get")
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{
          description: "公开描述文案",
          venue: @venue_beijing,
          starts_at: EventFixtures.days_from_now(3),
          ends_at: EventFixtures.days_from_now(4),
          pricing_enabled: true,
          price_tiers: [
            %{"id" => Ash.UUID.generate(), "name" => "早鸟票", "amount_cents" => 9900}
          ],
          sponsorship_enabled: true,
          sponsorship_tiers: [
            %{"id" => "gold", "name" => "金牌", "benefits" => ["logo 展示位"], "exclusive" => false}
          ]
        })

      outsider = Fixtures.register_user("po-get-user")

      assert {:reply, _, _} =
               reply = GetPublicOffering.execute(%{"id" => event.id}, frame_for(outsider))

      detail = decode(reply)

      assert Map.keys(detail) |> Enum.sort() ==
               ~w(available_price_tiers badge description ends_at enrollment_policy id kind
                  pricing_enabled registration_deadline slug sponsorship_enabled
                  sponsorship_tiers starts_at status title venue visibility)

      assert detail["id"] == event.id
      assert detail["kind"] == "event"
      assert detail["slug"] == event.slug
      assert detail["description"] == "公开描述文案"
      assert detail["status"] == "open"
      assert detail["visibility"] == "public"
      assert detail["pricing_enabled"] == true
      assert [%{"name" => "早鸟票"}] = detail["available_price_tiers"]
      assert detail["venue"] == @venue_beijing
      assert detail["sponsorship_enabled"] == true
      assert detail["badge"] in ["enrolling", "starting_soon", "full"]
      assert is_binary(detail["starts_at"])
      assert is_binary(detail["ends_at"])
    end

    test "按 id 取课程：venue / 赞助键为 null，kind=course" do
      admin = Fixtures.platform_admin("po-get-c")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{description: "课程描述"})
      outsider = Fixtures.register_user("po-get-c-user")

      assert {:reply, _, _} =
               reply = GetPublicOffering.execute(%{"id" => course.id}, frame_for(outsider))

      detail = decode(reply)

      assert detail["kind"] == "course"
      assert detail["description"] == "课程描述"
      assert is_nil(detail["venue"])
      assert is_nil(detail["sponsorship_enabled"])
      assert is_nil(detail["sponsorship_tiers"])
    end

    test "kind 参数显式分派；kind 与 id 不匹配 = not found" do
      admin = Fixtures.platform_admin("po-get-k")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{})
      outsider = Fixtures.register_user("po-get-k-user")

      assert {:reply, _, _} =
               GetPublicOffering.execute(
                 %{"id" => event.id, "kind" => "event"},
                 frame_for(outsider)
               )

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               GetPublicOffering.execute(
                 %{"id" => event.id, "kind" => "course"},
                 frame_for(outsider)
               )

      assert msg =~ "not found"
    end

    test "畸形 id 与不存在同一拒绝（不泄存在性）" do
      outsider = Fixtures.register_user("po-get-bad")

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               GetPublicOffering.execute(%{"id" => "not-a-uuid"}, frame_for(outsider))

      assert msg =~ "not found"
    end

    # 读取失败 ≠ 不存在（#4）：DB 级读故障必须报 load 失败，不得混入 not found。
    # 故障注入不 mock 内部：直改库把公开活动的 enrollment_policy 落为越枚举值
    # （text 列，绕过 Ash 校验），read_one 装载时 atom 枚举 cast 失败 = 真实读
    # 失败；断言在消息边界（execute 返回的用户可见 error message）。
    # 注入值必须每跑随机生成：Ash 的 enum load 走 String.to_existing_atom——
    # 固定字面量（如 "bogus"）会被套件里其它测试的同名 atom 字面量预热，
    # 全量跑时 cast 反而成功（单文件跑才失败），注入就漂了。
    test "读取失败（DB 故障）报 failed to load 而非 not found" do
      admin = Fixtures.platform_admin("po-get-loadfail")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{title: "读失败活动"})
      outsider = Fixtures.register_user("po-get-loadfail-user")
      bad_policy = "po-fault-#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               Ecto.Adapters.SQL.query(
                 Cgc2046.Repo,
                 "UPDATE events SET enrollment_policy = '#{bad_policy}' WHERE id = '#{event.id}'"
               )

      # kind 缺省：event 读取失败不得降级为「不存在」（若回退 course 查同一 id，
      # 会误报 not found；正确行为 = 原样报 load 失败）
      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               GetPublicOffering.execute(%{"id" => event.id}, frame_for(outsider))

      assert msg == "failed to load public offering"

      # 显式 kind 路径同层错误
      assert {:error, %Anubis.MCP.Error{message: msg2}, _} =
               GetPublicOffering.execute(
                 %{"id" => event.id, "kind" => "event"},
                 frame_for(outsider)
               )

      assert msg2 == "failed to load public offering"
    end
  end

  describe "场景 5:ToolCallLog 审计（D9/KD3）" do
    test "每次调用落审计行，params 经 Redact" do
      outsider = Fixtures.register_user("po-audit-user")

      assert {:reply, _, _} =
               ListPublicOfferings.execute(
                 %{"city" => "北京", "api_token" => "should-not-land"},
                 frame_for(outsider)
               )

      assert [log] = tool_logs_for(outsider.id, "list_public_offerings")
      assert log.result_status == :ok
      assert log.params["city"] == "北京"
      assert log.params["api_token"] == "[REDACTED]"
      assert is_integer(log.latency_ms)

      # 错误路径同样落审计（result_status = :error）
      assert {:error, _, _} =
               GetPublicOffering.execute(%{"id" => Ash.UUID.generate()}, frame_for(outsider))

      assert [err_log] = tool_logs_for(outsider.id, "get_public_offering")
      assert err_log.result_status == :error
    end
  end
end
