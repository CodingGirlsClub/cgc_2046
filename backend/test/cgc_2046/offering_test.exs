defmodule Cgc2046.OfferingTest do
  @moduledoc """
  Offering 读取面 seam 单测（PR-H D7）：fetch 两种 kind / not_found / actor 与
  authorize 选项 / fetch_by_signal_payload 键分派 / 批量形状。

  缴费槽谓词（#586）：`payment_mode/1` 三态（含押金优先、裸 SQL 行形状、
  nil/缺键兜底）与 `deposit_amount_cents/1` 金额降级（仅正整数）单源。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Offering
  alias Cgc2046.EventsFixtures, as: EventFixtures

  describe "fetch/3 两种 kind + 投影" do
    test "fetch(:event, id) → 完整 entity + kind/title/workspace_id" do
      admin = Fixtures.platform_admin("offering-admin")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{title: "Offering 大会"})

      assert {:ok, fetched} = Offering.fetch(:event, event.id)
      assert fetched.id == event.id
      assert Offering.kind(fetched) == :event
      assert Offering.title(fetched) == "Offering 大会"
      assert Offering.workspace_id(fetched) == workspace.id
    end

    test "fetch(:course, id) → 完整 entity + kind/title/workspace_id" do
      admin = Fixtures.platform_admin("offering-admin")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{title: "Offering 课程"})

      assert {:ok, fetched} = Offering.fetch(:course, course.id)
      assert fetched.id == course.id
      assert Offering.kind(fetched) == :course
      assert Offering.title(fetched) == "Offering 课程"
      assert Offering.workspace_id(fetched) == workspace.id
    end

    test "kind 与 id 不匹配 → :not_found" do
      admin = Fixtures.platform_admin("offering-admin")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      assert {:error, :not_found} = Offering.fetch(:course, event.id)
    end

    test "不存在的 id → :not_found（两种 kind）" do
      assert {:error, :not_found} = Offering.fetch(:event, Ecto.UUID.generate())
      assert {:error, :not_found} = Offering.fetch(:course, Ecto.UUID.generate())
    end
  end

  describe "actor 与 authorize 选项" do
    test "默认 authorize?: false：无 actor 也读（匹配原分叉行为）" do
      admin = Fixtures.platform_admin("offering-admin")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      assert {:ok, _} = Offering.fetch(:event, event.id)
    end

    test "actor: + authorize?: true 时按 read policy 过滤（graphql 场景；拒绝坍缩 :not_found）" do
      admin = Fixtures.platform_admin("offering-admin")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{visibility: :workspace})

      member = Fixtures.register_user("offering-actor-member")
      Fixtures.add_member(workspace, member)
      assert {:ok, _} = Offering.fetch(:event, event.id, actor: member, authorize?: true)

      # 非成员 + visibility=workspace → read policy 拒绝 → 坍缩 :not_found
      outsider = Fixtures.register_user("offering-actor-outsider")

      assert {:error, :not_found} =
               Offering.fetch(:event, event.id, actor: outsider, authorize?: true)
    end
  end

  describe "fetch_by_signal_payload/1 键分派" do
    test "event_id 键 → event" do
      admin = Fixtures.platform_admin("offering-admin")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      assert {:ok, fetched} = Offering.fetch_by_signal_payload(%{"event_id" => event.id})
      assert Offering.kind(fetched) == :event
    end

    test "course_id 键 → course" do
      admin = Fixtures.platform_admin("offering-admin")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin)

      assert {:ok, fetched} = Offering.fetch_by_signal_payload(%{"course_id" => course.id})
      assert Offering.kind(fetched) == :course
    end

    test "无键 / 空串 → :not_found" do
      assert {:error, :not_found} = Offering.fetch_by_signal_payload(%{"foo" => "bar"})
      assert {:error, :not_found} = Offering.fetch_by_signal_payload(%{"event_id" => ""})
      assert {:error, :not_found} = Offering.fetch_by_signal_payload(%{})
    end

    test "payload 中的 id 不存在 → :not_found" do
      assert {:error, :not_found} =
               Offering.fetch_by_signal_payload(%{"event_id" => Ecto.UUID.generate()})
    end
  end

  describe "fetch_titles_by_ids/2 批量形状" do
    test "按 kind 分组批量取标题，per-tenant 作用域" do
      admin = Fixtures.platform_admin("offering-admin")
      ws = Fixtures.create_workspace(admin)
      e1 = EventFixtures.create_event(ws, admin, %{title: "E1"})
      e2 = EventFixtures.create_event(ws, admin, %{title: "E2"})
      c1 = EventFixtures.create_course(ws, admin, %{title: "C1"})

      titles = Offering.fetch_titles_by_ids(%{event: [e1.id, e2.id], course: [c1.id]}, ws.id)

      assert titles[e1.id] == "E1"
      assert titles[e2.id] == "E2"
      assert titles[c1.id] == "C1"
    end

    test "空 id 列表不查询（返回空 map）" do
      admin = Fixtures.platform_admin("offering-admin")
      workspace = Fixtures.create_workspace(admin)

      assert Offering.fetch_titles_by_ids(%{event: [], course: []}, workspace.id) == %{}
    end

    test "跨租户隔离：只取 tenant 内标题" do
      admin = Fixtures.platform_admin("offering-admin")
      ws1 = Fixtures.create_workspace(admin)
      ws2 = Fixtures.create_workspace(admin)
      e_ws2 = EventFixtures.create_event(ws2, admin, %{title: "WS2 Event"})

      titles = Offering.fetch_titles_by_ids(%{event: [e_ws2.id]}, ws1.id)
      refute Map.has_key?(titles, e_ws2.id)
    end
  end

  describe "payment_mode/1 缴费槽三态（#586 单源）" do
    test "event 三态：押金 / 定价 / 免费" do
      admin = Fixtures.platform_admin("offering-slot")
      ws = Fixtures.create_workspace(admin)

      deposit =
        EventFixtures.create_event(ws, admin, %{
          deposit_enabled: true,
          deposit_amount_cents: 6900,
          ends_at: EventFixtures.days_from_now(8)
        })

      pricing = EventFixtures.create_event(ws, admin, Map.merge(%{title: "定价场"}, paid_attrs()))
      free = EventFixtures.create_event(ws, admin, %{title: "免费场"})

      assert Offering.payment_mode(deposit) == :deposit
      assert Offering.payment_mode(pricing) == :pricing
      assert Offering.payment_mode(free) == :free
    end

    test "course 无押金列：押金键缺席不影响定价/免费判定" do
      admin = Fixtures.platform_admin("offering-slot-c")
      ws = Fixtures.create_workspace(admin)

      pricing_course =
        EventFixtures.create_course(ws, admin, Map.merge(%{title: "收费课"}, paid_attrs()))

      free_course = EventFixtures.create_course(ws, admin, %{title: "免费课"})

      assert Offering.payment_mode(pricing_course) == :pricing
      assert Offering.payment_mode(free_course) == :free
    end

    test "押金优先于定价（DB CHECK 不可达输入）：优先级与 web paymentModeOf 同序" do
      assert Offering.payment_mode(%{deposit_enabled: true, pricing_enabled: true}) == :deposit
    end

    test "裸 SQL 行形状（confirm_target_status/2 入参）与 schedule 投影 map 皆可" do
      # confirm_target_status/2 的 SELECT 行：["open", pricing_enabled, deposit_enabled, amount]
      assert Offering.payment_mode(%{pricing_enabled: false, deposit_enabled: true}) == :deposit
      assert Offering.payment_mode(%{pricing_enabled: true, deposit_enabled: false}) == :pricing
      assert Offering.payment_mode(%{pricing_enabled: false, deposit_enabled: false}) == :free
      # schedule_for/3 投影（courses 补 false）：同上形状
      assert Offering.payment_mode(%{deposit_enabled: false, pricing_enabled: true}) == :pricing
    end

    test "nil / 空 map / 缺键 → :free（存量兜底逐字不变）" do
      assert Offering.payment_mode(nil) == :free
      assert Offering.payment_mode(%{}) == :free
      assert Offering.payment_mode(%{title: "无缴费键"}) == :free
    end
  end

  describe "deposit_amount_cents/1 金额降级（#586；与 Order.deposit_tier/1 同判据）" do
    test "仅正整数算有效金额，非正/缺失一律 nil（绝不 0）" do
      assert Offering.deposit_amount_cents(%{deposit_amount_cents: 6900}) == 6900
      assert Offering.deposit_amount_cents(%{deposit_amount_cents: 1}) == 1
      assert is_nil(Offering.deposit_amount_cents(%{deposit_amount_cents: 0}))
      assert is_nil(Offering.deposit_amount_cents(%{deposit_amount_cents: -1}))
      assert is_nil(Offering.deposit_amount_cents(%{deposit_amount_cents: nil}))
      assert is_nil(Offering.deposit_amount_cents(%{}))
      assert is_nil(Offering.deposit_amount_cents(nil))
    end

    test "course struct（无押金列）→ nil" do
      admin = Fixtures.platform_admin("offering-slot-amt")
      ws = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(ws, admin)

      assert is_nil(Offering.deposit_amount_cents(course))
    end
  end

  # 收费供给布置：单档可售（谓词面只需 pricing_enabled 真值，档位内容不影响三态）
  defp paid_attrs do
    %{
      pricing_enabled: true,
      price_tiers: [
        %{"id" => Ecto.UUID.generate(), "name" => "标准", "amount_cents" => 9900}
      ]
    }
  end
end
