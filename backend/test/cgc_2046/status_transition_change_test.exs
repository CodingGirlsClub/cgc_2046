defmodule Cgc2046.StatusTransition.ChangeTest do
  @moduledoc """
  StatusTransition.Change（#846 action 级声明）单元契约：

  - 成功：CAS 行推进 + changeset status force 为 to；
  - 竞态 / 状态非法：错误文案**逐字节**断言（D2 硬契约——web 正则与 MCP
    测试逐字依赖，任何漂移在此红）；
  - 白名单之外的资源：before_action 阶段即 ArgumentError 拒绝，不静默成功。

  用裸 changeset（`Ash.Changeset.new` + 手动设 action）隔离 change 回调本身：
  迁移期资源 action 上仍挂着旧匿名 CAS 块，经 `for_update/3` 构造会把新旧
  两个闭包都挂上（旧块先写库、新块必 race），无法单测新 change。
  action 级行为（经 Ash.update 真实 action 面）由 Events.EventLifecycleTest
  与 Courses.CourseLifecycleTest 覆盖。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Courses.Course
  alias Cgc2046.EventsFixtures
  alias Cgc2046.Recruitment.RecruitmentCohort
  alias Cgc2046.Repo
  alias Cgc2046.StatusTransition
  alias Cgc2046.StatusTransition.Change

  # run_before_actions/1 的空列表子句返回 {changeset, notifications}、
  # valid? false 子句返回裸 changeset——归一成 changeset。
  defp run_ba(cs) do
    case Ash.Changeset.run_before_actions(cs) do
      {cs, _notifications} -> cs
      cs -> cs
    end
  end

  # 裸 changeset：不经过 for_update（否则挂上 action 声明里的旧匿名 CAS 块），
  # 只手动设 action struct 供闭包内 `cs.action.name` 取动词。
  defp bare_cs(record, action_name) do
    cs = Ash.Changeset.new(record)
    %{cs | action: Ash.Resource.Info.action(cs.resource, action_name)}
  end

  defp fetch_status!(table, id) do
    {:ok, %{rows: [[status]]}} =
      Repo.query("SELECT status FROM #{table} WHERE id = $1", [Repo.uuid!(id)])

    status
  end

  # create_course fixture 直接 force_open，草稿课程手动建（同 MCP 测试）。
  defp draft_course(workspace, admin) do
    Course
    |> Ash.Changeset.for_create(
      :create,
      %{title: "Change 单测课程", registration_deadline: EventsFixtures.days_from_now(7)},
      tenant: workspace.id
    )
    |> Ash.create!(tenant: workspace.id, actor: admin)
  end

  describe "change/3 契约" do
    test "成功：CAS 推进 DB 行，changeset status 被 force 为 to" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      course = EventsFixtures.create_course(workspace, admin)

      cs =
        course
        |> bare_cs(:close)
        |> Change.change([from: :open, to: :closed], %{})
        |> run_ba()

      refute Enum.any?(cs.errors)
      assert Ash.Changeset.get_attribute(cs, :status) == :closed
      assert fetch_status!("courses", course.id) == "closed"
    end

    test "竞态：陈旧 changeset 二拍 → 竞态文案逐字节" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      course = EventsFixtures.create_course(workspace, admin)

      # 并发另一路先抢占（DB 已 closed，changeset 内存态仍 open）
      assert :ok = StatusTransition.run(Ash.Changeset.new(course), :courses, :closed)

      cs =
        course
        |> bare_cs(:close)
        |> Change.change([from: :open, to: :closed], %{})
        |> run_ba()

      assert Enum.any?(
               cs.errors,
               &(&1.message ==
                   "close failed: status changed concurrently, retry on fresh read")
             )

      assert fetch_status!("courses", course.id) == "closed"
    end

    test "状态非法：from 不匹配 → cannot 文案逐字节" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      course = draft_course(workspace, admin)

      # 内存态 draft，声明 from: :open → 非法分支
      cs =
        course
        |> bare_cs(:close)
        |> Change.change([from: :open, to: :closed], %{})
        |> run_ba()

      assert Enum.any?(cs.errors, &(&1.message == "cannot close from status=draft"))
      assert fetch_status!("courses", course.id) == "draft"
    end

    test "白名单之外的资源被拒绝（recruitment_cohorts 不在 [:events, :courses]）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      # RecruitmentCohort：status 字段存在（:draft）→ 闭包走到 table 推导；
      # 表不在白名单 → to_existing_atom 或 run/3 白名单任一层 raise ArgumentError，
      # 两种路径均为 ArgumentError，且都不触任何 SQL 写入。
      cohort =
        RecruitmentCohort
        |> Ash.Changeset.for_create(
          :create,
          %{name: "白名单拒绝批次", apply_deadline_at: ~U[2026-10-10 15:59:00Z]},
          tenant: workspace.id
        )
        |> Ash.create!(tenant: workspace.id, actor: admin)

      cs =
        cohort
        |> bare_cs(:close)
        |> Change.change([from: :draft, to: :open], %{})

      assert_raise ArgumentError, fn -> run_ba(cs) end
    end
  end
end
