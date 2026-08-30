defmodule Cgc2046.StatusTransitionTest do
  @moduledoc """
  状态机 CAS 原语（Cgc2046.StatusTransition）契约测试（ADR-0009 D5：写原语自
  offering/ 迁出根部，纯读投影端口回归零写入）。

  表驱动契约（真实 events/courses 行，changeset 仅作 data 载体——测原语非测
  资源 action）：合法 table 原子 CAS 成功 / 竞态拒（:status_race）/ 白名单外
  table（字符串、未知原子）ArgumentError 拒绝，表名不被字符串注入。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures
  alias Cgc2046.Repo
  alias Cgc2046.StatusTransition

  setup do
    admin = Fixtures.platform_admin("stransition-admin")
    workspace = Fixtures.create_workspace(admin)

    %{workspace: workspace, admin: admin}
  end

  # 原语只读 changeset.data（id / status），new/1 包装的 record 即合法输入。
  defp changeset_for(record), do: Ash.Changeset.new(record)

  defp fetch_status!(table, id) do
    {:ok, %{rows: [[status]]}} =
      Repo.query("SELECT status FROM #{table} WHERE id = $1", [Repo.uuid!(id)])

    status
  end

  # 故意越界的白名单拒绝用例：apply/3 绕过渐进类型检查（@spec 已收窄到
  # :events | :courses，直写违规实参会触发 type warning，噪音而非缺陷）。
  defp run_unchecked(changeset, table, to_status),
    do: apply(StatusTransition, :run, [changeset, table, to_status])

  describe "run/3 合法 table 原子" do
    test "events：from 状态匹配 → :ok，行推进且 updated_at 刷新", %{
      workspace: ws,
      admin: admin
    } do
      event = EventsFixtures.create_event(ws, admin)

      assert :ok = StatusTransition.run(changeset_for(event), :events, :closed)
      assert fetch_status!("events", event.id) == "closed"
    end

    test "courses：from 状态匹配 → :ok，行推进", %{workspace: ws, admin: admin} do
      course = EventsFixtures.create_course(ws, admin)

      assert :ok = StatusTransition.run(changeset_for(course), :courses, :cancelled)
      assert fetch_status!("courses", course.id) == "cancelled"
    end

    test "竞态：同一陈旧读二拍 → {:error, :status_race} 且行不变（不双成功）", %{
      workspace: ws,
      admin: admin
    } do
      event = EventsFixtures.create_event(ws, admin)
      stale = changeset_for(event)

      # 第一拍抢占 open → closed（模拟并发 cron/手动先到者）。
      assert :ok = StatusTransition.run(stale, :events, :closed)

      # 第二拍拿同一陈旧读（data.status 仍是 :open）再抢 → 0 行命中，拒绝。
      assert {:error, :status_race} = StatusTransition.run(stale, :events, :cancelled)
      assert fetch_status!("events", event.id) == "closed"
    end
  end

  describe "run/3 table 白名单" do
    test "字符串表名（注入形态）→ ArgumentError，不触 SQL", %{workspace: ws, admin: admin} do
      event = EventsFixtures.create_event(ws, admin)

      assert_raise ArgumentError, ~r/未知 table/, fn ->
        run_unchecked(changeset_for(event), "events; DROP TABLE events", :closed)
      end

      # 字符串形态（即使字面合法）同样拒绝：白名单只收 atom。
      assert_raise ArgumentError, ~r/未知 table/, fn ->
        run_unchecked(changeset_for(event), "events", :closed)
      end

      assert fetch_status!("events", event.id) == "open"
    end

    test "白名单外原子 → ArgumentError", %{workspace: ws, admin: admin} do
      event = EventsFixtures.create_event(ws, admin)

      assert_raise ArgumentError, ~r/未知 table/, fn ->
        run_unchecked(changeset_for(event), :users, :closed)
      end
    end
  end
end
