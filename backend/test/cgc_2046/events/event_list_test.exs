defmodule Cgc2046.Events.EventListTest do
  @moduledoc """
  list_events / list_courses 显式排序契约（plan 008）：UUID v4 主键无序，
  列表必须按 inserted_at desc（id 兜底）返回——#411/enrollment 同款回归锚。
  """

  use Cgc2046.DataCase, async: true

  require Ash.Query

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Courses.Course
  alias Cgc2046.Events.Event
  alias Cgc2046.EventsFixtures, as: EventFixtures

  describe "list 显式排序（plan 008）" do
    test "list_events 按 inserted_at desc 返回（id 兜底，keyset 稳定序）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      # 按创建序 e1 → e2 → e3 插入；随后回拨 inserted_at 使 e2 最新——
      # 创建序与插入时间序刻意错位，断言的是显式 sort 而非物理插入序
      e1 = EventFixtures.create_event(workspace, admin)
      e2 = EventFixtures.create_event(workspace, admin)
      e3 = EventFixtures.create_event(workspace, admin)

      backdate_inserted_at("events", e1.id, 3)
      backdate_inserted_at("events", e3.id, 2)

      # graphql list_events 列表绑定的 :list_events（显式 sort + keyset）
      %{results: results} =
        Event
        |> Ash.Query.for_read(:list_events, %{})
        |> Ash.Query.filter(id in ^[e1.id, e2.id, e3.id])
        |> Ash.read!(authorize?: false)

      assert Enum.map(results, & &1.id) == [e2.id, e3.id, e1.id]
    end

    test "list_courses 按 inserted_at desc 返回（id 兜底，keyset 稳定序）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      c1 = EventFixtures.create_course(workspace, admin)
      c2 = EventFixtures.create_course(workspace, admin)
      c3 = EventFixtures.create_course(workspace, admin)

      backdate_inserted_at("courses", c1.id, 3)
      backdate_inserted_at("courses", c3.id, 2)

      %{results: results} =
        Course
        |> Ash.Query.for_read(:list_courses, %{})
        |> Ash.Query.filter(id in ^[c1.id, c2.id, c3.id])
        |> Ash.read!(authorize?: false)

      assert Enum.map(results, & &1.id) == [c2.id, c3.id, c1.id]
    end
  end

  # inserted_at 由 create_timestamp 控制不可写，直改库回拨造时间差
  # （enrollment_test.exs:230-238 backdate_inserted_at 同款；UPDATE 恰命中一行）
  defp backdate_inserted_at(table, id, hours_ago) do
    assert %{num_rows: 1} =
             Cgc2046.Repo.query!(
               "UPDATE #{table} SET inserted_at = $1 WHERE id = $2",
               [
                 DateTime.add(DateTime.utc_now(), -hours_ago * 3600, :second),
                 Cgc2046.Repo.uuid!(id)
               ]
             )
  end
end
