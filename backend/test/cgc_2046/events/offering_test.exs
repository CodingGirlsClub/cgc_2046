defmodule Cgc2046.Events.OfferingTest do
  @moduledoc """
  Offering 读取面 seam 单测（PR-H D7）：fetch 两种 kind / not_found / actor 与
  authorize 选项 / fetch_by_signal_payload 键分派 / 批量形状。
  """

  use Cgc2046.DataCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Offering
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
end
