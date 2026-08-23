defmodule Cgc2046.Events.EnrollmentBadgeTest do
  @moduledoc """
  U1 / R6 / KTD1：enrollment_badge 公开派生标签矩阵。

  枚举 `enrolling | starting_soon | full`，优先级 full > starting_soon > enrolling：

  - capacity 非空且 confirmed_count >= capacity → full
  - starts_at 落在未来 7 天内且报名未截止（deadline 为空或晚于 now）→ starting_soon
  - 其余 → enrolling；无 starts_at 的条目永不为 starting_soon（AE2 数据面）

  confirmed_count 只能由 Enrollment 原子维护——测试经 EventsFixtures.set_confirmed_count
  裸 SQL 置位（布置而非被测对象，force_open 同款纪律）。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.{Course, Event}
  alias Cgc2046.EventsFixtures, as: EventFixtures

  setup do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    %{admin: admin, workspace: workspace}
  end

  describe "Event badge 派生矩阵" do
    test "默认（无名额上限、无 starts_at）→ enrolling", ctx do
      event = EventFixtures.create_event(ctx.workspace, ctx.admin)
      assert badge(event) == :enrolling
    end

    test "名额满（confirmed_count >= capacity）→ full", ctx do
      event = EventFixtures.create_event(ctx.workspace, ctx.admin, %{capacity: 2})
      event = EventFixtures.set_confirmed_count(event, :events, 2)
      assert badge(event) == :full
    end

    test "full 优先级最高：即将开始但名额已满 → full", ctx do
      event =
        EventFixtures.create_event(ctx.workspace, ctx.admin, %{
          capacity: 1,
          registration_deadline: nil,
          starts_at: EventFixtures.days_from_now(3)
        })

      event = EventFixtures.set_confirmed_count(event, :events, 1)
      assert badge(event) == :full
    end

    test "confirmed_count < capacity → 不 full", ctx do
      event = EventFixtures.create_event(ctx.workspace, ctx.admin, %{capacity: 2})
      event = EventFixtures.set_confirmed_count(event, :events, 1)
      assert badge(event) == :enrolling
    end

    test "starts_at 未来 7 天内且报名未截止（无 deadline）→ starting_soon", ctx do
      event =
        EventFixtures.create_event(ctx.workspace, ctx.admin, %{
          registration_deadline: nil,
          starts_at: EventFixtures.days_from_now(3)
        })

      assert badge(event) == :starting_soon
    end

    test "starts_at 未来 7 天内且 deadline 晚于 now → starting_soon", ctx do
      event =
        EventFixtures.create_event(ctx.workspace, ctx.admin, %{
          registration_deadline: EventFixtures.days_from_now(2),
          starts_at: EventFixtures.days_from_now(6)
        })

      assert badge(event) == :starting_soon
    end

    test "无 starts_at 永不 starting_soon（AE2：其余条件都凑齐也 enrolling）", ctx do
      event =
        EventFixtures.create_event(ctx.workspace, ctx.admin, %{
          capacity: nil,
          registration_deadline: nil
        })

      assert badge(event) == :enrolling
    end

    test "starts_at 在过去 → 不 starting_soon（历史活动）", ctx do
      event =
        EventFixtures.create_event(ctx.workspace, ctx.admin, %{
          registration_deadline: nil,
          starts_at: EventFixtures.days_from_now(-1)
        })

      assert badge(event) == :enrolling
    end

    test "starts_at 超出未来 7 天 → enrolling", ctx do
      event =
        EventFixtures.create_event(ctx.workspace, ctx.admin, %{
          registration_deadline: nil,
          starts_at: EventFixtures.days_from_now(8)
        })

      assert badge(event) == :enrolling
    end

    test "deadline 已过 → 不 starting_soon（报名已截止）", ctx do
      event =
        EventFixtures.create_event(ctx.workspace, ctx.admin, %{
          registration_deadline: EventFixtures.days_from_now(-1),
          starts_at: EventFixtures.days_from_now(3)
        })

      assert badge(event) == :enrolling
    end
  end

  describe "Course badge（同构，无 venue）" do
    test "starts_at 未来 7 天内 → starting_soon；名额满 → full", ctx do
      course =
        EventFixtures.create_course(ctx.workspace, ctx.admin, %{
          registration_deadline: nil,
          starts_at: EventFixtures.days_from_now(3)
        })

      assert badge(course) == :starting_soon

      full_course = EventFixtures.create_course(ctx.workspace, ctx.admin, %{capacity: 1})
      full_course = EventFixtures.set_confirmed_count(full_course, :courses, 1)
      assert badge(full_course) == :full
    end

    test "无 starts_at → enrolling", ctx do
      course = EventFixtures.create_course(ctx.workspace, ctx.admin)
      assert badge(course) == :enrolling
    end
  end

  describe "load 依赖声明（KTD1：只 select 计算字段时依赖列自动补载）" do
    test "Query 只 load enrollment_badge 不误判（capacity/confirmed_count 补载）", ctx do
      event = EventFixtures.create_event(ctx.workspace, ctx.admin, %{capacity: 1})
      _ = EventFixtures.set_confirmed_count(event, :events, 1)

      require Ash.Query

      [row] =
        Event
        |> Ash.Query.filter(id == ^event.id)
        |> Ash.Query.load(:enrollment_badge)
        |> Ash.Query.select([:id])
        |> Ash.read!(authorize?: false)

      assert row.enrollment_badge == :full
    end
  end

  # ── 布置 ──

  defp badge(record) do
    Ash.load!(record, :enrollment_badge, authorize?: false).enrollment_badge
  end
end
