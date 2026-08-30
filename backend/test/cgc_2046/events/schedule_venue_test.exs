defmodule Cgc2046.Events.ScheduleVenueTest do
  @moduledoc """
  U1 / R1 / R2 / KTD5 / KTD6：starts_at/ends_at 与结构化 venue 数据面。

  - starts_at/ends_at：`:utc_datetime` 可空；两值同时存在时 ends_at 须晚于
    starts_at（create/update 同挂，message-only）；只填一个合法；start 在过去合法。
  - venue：Event 独有（Course 线上无场地），恰四键 country/province/city/district
    的字符串 map；缺键/多键/非字符串拒绝；nil 合法。
  - field_policy 回归：新字段走 :* 白名单匿名可读，capacity/confirmed_count 仍收窄。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Courses.Course
  alias Cgc2046.Events.Event
  alias Cgc2046.EventsFixtures, as: EventFixtures

  @venue %{
    "country" => "中国",
    "province" => "浙江省",
    "city" => "杭州市",
    "district" => "西湖区"
  }

  setup do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    %{admin: admin, workspace: workspace}
  end

  describe "starts_at/ends_at 写入（R1）" do
    test "两值齐全且 end > start 可写可读；start 在过去合法", ctx do
      # :utc_datetime 列按秒截断，等值断言前先 truncate（registration_deadline 同款精度）
      starts_at = DateTime.add(DateTime.utc_now(), -7, :day) |> DateTime.truncate(:second)
      ends_at = DateTime.add(DateTime.utc_now(), 7, :day) |> DateTime.truncate(:second)

      assert {:ok, event} =
               create_event(ctx, %{starts_at: starts_at, ends_at: ends_at})

      assert DateTime.compare(event.starts_at, starts_at) == :eq
      assert DateTime.compare(event.ends_at, ends_at) == :eq
    end

    test "只填一个时间合法（starts_at only / ends_at only / 都不填）", ctx do
      assert {:ok, e1} = create_event(ctx, %{starts_at: DateTime.utc_now()})
      assert e1.ends_at == nil

      assert {:ok, e2} =
               create_event(ctx, %{ends_at: DateTime.add(DateTime.utc_now(), 1, :day)})

      assert e2.starts_at == nil

      assert {:ok, e3} = create_event(ctx, %{})
      assert e3.starts_at == nil and e3.ends_at == nil
    end

    test "Course 同构：开课/结课时间可写", ctx do
      starts_at = DateTime.utc_now() |> DateTime.truncate(:second)
      ends_at = DateTime.add(starts_at, 30, :day)

      assert {:ok, course} =
               create_course(ctx, %{starts_at: starts_at, ends_at: ends_at})

      assert DateTime.compare(course.starts_at, starts_at) == :eq
    end
  end

  describe "end > start 校验（KTD6，create/update 同挂）" do
    test "create：ends_at < starts_at 拒绝", ctx do
      starts_at = DateTime.add(DateTime.utc_now(), 7, :day)

      assert {:error, error} =
               create_event(ctx, %{starts_at: starts_at, ends_at: DateTime.utc_now()})

      assert Exception.message(error) =~ "ends_at"

      assert {:error, _} =
               create_course(ctx, %{starts_at: starts_at, ends_at: DateTime.utc_now()})
    end

    test "create：ends_at == starts_at 拒绝（须严格晚于）", ctx do
      at = DateTime.add(DateTime.utc_now(), 7, :day)
      assert {:error, error} = create_event(ctx, %{starts_at: at, ends_at: at})
      assert Exception.message(error) =~ "ends_at"
    end

    test "update：改出 ends_at <= starts_at 拒绝；合法修改通过", ctx do
      starts_at = DateTime.add(DateTime.utc_now(), 7, :day)
      event = EventFixtures.create_event(ctx.workspace, ctx.admin, %{starts_at: starts_at})

      assert {:error, error} =
               event
               |> Ash.Changeset.for_update(:update, %{ends_at: DateTime.utc_now()})
               |> Ash.update(tenant: ctx.workspace.id, actor: ctx.admin)

      assert Exception.message(error) =~ "ends_at"

      assert {:ok, updated} =
               event
               |> Ash.Changeset.for_update(:update, %{
                 ends_at: DateTime.add(starts_at, 2, :hour)
               })
               |> Ash.update(tenant: ctx.workspace.id, actor: ctx.admin)

      assert updated.ends_at != nil
    end
  end

  describe "venue 形状（KTD5）" do
    test "恰四键字符串 map 可写可读", ctx do
      assert {:ok, event} = create_event(ctx, %{venue: @venue})
      assert event.venue == @venue

      {:ok, reloaded} = Ash.get(Event, event.id, authorize?: false)
      assert reloaded.venue == @venue
    end

    test "nil venue 合法（线上/未定）", ctx do
      assert {:ok, event} = create_event(ctx, %{venue: nil})
      assert event.venue == nil
    end

    test "缺键 / 多键 / 非字符串值拒绝", ctx do
      assert {:error, error} = create_event(ctx, %{venue: Map.delete(@venue, "district")})
      assert Exception.message(error) =~ "venue"

      assert {:error, _} = create_event(ctx, %{venue: Map.put(@venue, "address", "某路 1 号")})
      assert {:error, _} = create_event(ctx, %{venue: Map.put(@venue, "city", 123)})
      assert {:error, _} = create_event(ctx, %{venue: "not-a-map"})
    end

    test "update 路径同样校验", ctx do
      event = EventFixtures.create_event(ctx.workspace, ctx.admin)

      assert {:ok, updated} =
               event
               |> Ash.Changeset.for_update(:update, %{venue: @venue})
               |> Ash.update(tenant: ctx.workspace.id, actor: ctx.admin)

      assert updated.venue == @venue

      assert {:error, _} =
               event
               |> Ash.Changeset.for_update(:update, %{venue: Map.delete(@venue, "country")})
               |> Ash.update(tenant: ctx.workspace.id, actor: ctx.admin)
    end

    test "Course 无 venue 字段（线上课程，R2）", _ctx do
      assert :venue in Ash.Resource.Info.attribute_names(Event)
      refute :venue in Ash.Resource.Info.attribute_names(Course)
    end
  end

  describe "field_policy 回归（R6：新字段匿名可读，计数仍收窄）" do
    test "匿名读 open+public：starts_at/ends_at/venue/enrollment_badge 可读，capacity/confirmed_count 仍 ForbiddenField",
         ctx do
      starts_at = DateTime.add(DateTime.utc_now(), 3, :day) |> DateTime.truncate(:second)

      event =
        EventFixtures.create_event(ctx.workspace, ctx.admin, %{
          capacity: 5,
          starts_at: starts_at,
          registration_deadline: nil,
          venue: @venue
        })

      {:ok, anon_view} = Ash.get(Event, event.id, authorize?: true)
      assert DateTime.compare(anon_view.starts_at, starts_at) == :eq
      assert anon_view.ends_at == nil
      assert anon_view.venue == @venue
      assert match?(%Ash.ForbiddenField{}, anon_view.capacity)
      assert match?(%Ash.ForbiddenField{}, anon_view.confirmed_count)

      loaded = Ash.load!(anon_view, :enrollment_badge, authorize?: true)
      assert loaded.enrollment_badge == :starting_soon
    end
  end

  # ── 布置 ──

  defp create_event(ctx, attrs) do
    Event
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :title, "排期活动"), tenant: ctx.workspace.id)
    |> Ash.create(actor: ctx.admin)
  end

  defp create_course(ctx, attrs) do
    Course
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :title, "排期课程"), tenant: ctx.workspace.id)
    |> Ash.create(actor: ctx.admin)
  end
end
