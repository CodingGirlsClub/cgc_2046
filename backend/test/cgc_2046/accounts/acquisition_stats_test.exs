defmodule Cgc2046.Accounts.AcquisitionStatsTest do
  @moduledoc """
  平台级获客归因聚合（Plan 012）：按用户最早登录身份的平台统计新用户 / 报名 /
  志愿者申请，零 PII。

  - 首个身份口径：多端登录用户只计首个平台（先 wechat 后 xhs 的用户归 wechat）；
  - 无身份用户归 `"none"`（web 手机号直接注册等）；
  - `initiative_slug` 过滤报名到指定 Initiative 下的场次；
  - 时间窗 `since` 之外的数据全部排除；
  - 返回结构零 PII（不含 user_id / 手机 / 邮箱 / 姓名）。
  """
  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Accounts.AcquisitionStats
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventsFixtures
  alias Cgc2046.Initiatives.{Initiative, InitiativeRule}
  alias Cgc2046.Recruitment.{RecruitmentCohort, VolunteerApplication}

  @tier_id "std"

  setup do
    # 基线快照（delta 断言）：`new_users` / 不带 slug 的 `enrollments` / `volunteer_applications`
    # 都是对全表的聚合（无 workspace 作用域），全量套件并发跑时可能有别的用例经非
    # sandbox 路径（后台 worker/信号处理）往这些表落真实提交行——直接断言绝对值在
    # 单文件跑绿、全量套件偶发红。改为「跑完 - 基线」的增量断言，既保住口径覆盖
    # 又不受套件内其他噪声影响；`initiative_slug` 过滤的用例天然免疫（自建
    # slug 全局唯一，join 出的场次只可能是本用例的）。
    since = old_since()
    {:ok, baseline} = AcquisitionStats.stats(since: since)

    admin = Fixtures.platform_admin("acq-stats-admin")
    workspace = Fixtures.create_workspace(admin)

    user_a = Fixtures.register_user("acq-stats-a")
    user_b = Fixtures.register_user("acq-stats-b")
    user_c = Fixtures.register_user("acq-stats-c")

    # A：只有 xhs 身份。
    insert_identity(user_a.id, :xhs, "a-xhs")

    # B：先 wechat 后 xhs（xhs 那条 inserted_at 调晚）——首个身份口径下应归 wechat。
    insert_identity(user_b.id, :wechat, "b-wechat", DateTime.add(DateTime.utc_now(), -2, :day))
    insert_identity(user_b.id, :xhs, "b-xhs", DateTime.add(DateTime.utc_now(), -1, :day))

    # C：无任何身份 → "none"。

    initiative =
      Initiative
      |> Ash.Changeset.for_create(:create, %{
        name: "Hacker Start 1024",
        slug: "hackerstart1024",
        created_by: admin.id
      })
      |> Ash.create!(actor: admin)

    # 挂载要求 initiative 处于 open（四规则齐备才能开——照抄 initiative_boundary_test 样板）。
    for {key, value} <- [
          deposit: %{enabled: false},
          age_gate: %{min_age: 18},
          min_participants: %{count: 1},
          deadline_rule: %{hours_before_start: 0}
        ] do
      InitiativeRule
      |> Ash.Changeset.for_create(:create, %{
        initiative_id: initiative.id,
        key: key,
        value: value,
        locked: true
      })
      |> Ash.create!(actor: admin)
    end

    initiative =
      initiative
      |> Ash.Changeset.for_update(:open, %{})
      |> Ash.update!(actor: admin)

    # 挂在 initiative 下的场次：A 免费报名（confirmed），B 付费报名（payment_pending）。
    mounted_event =
      EventsFixtures.create_event(workspace, admin, %{initiative_id: initiative.id})

    priced_event =
      EventsFixtures.create_event(workspace, admin, %{
        initiative_id: initiative.id,
        pricing_enabled: true,
        price_tiers: [%{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900}]
      })

    # 不挂 initiative 的场次：C 报名。
    other_event = EventsFixtures.create_event(workspace, admin, %{})

    enrollment_a =
      enroll(workspace, user_a, mounted_event, %{})

    enrollment_b =
      enroll(workspace, user_b, priced_event, %{tier_id: @tier_id})

    enrollment_c = enroll(workspace, user_c, other_event, %{})

    cohort =
      RecruitmentCohort
      |> Ash.Changeset.for_create(
        :create,
        %{name: "第 1 批", apply_deadline_at: DateTime.add(DateTime.utc_now(), 14, :day)},
        tenant: workspace.id
      )
      |> Ash.create!(tenant: workspace.id, actor: admin)

    cohort =
      cohort
      |> Ash.Changeset.for_update(:open, %{}, tenant: workspace.id, actor: admin)
      |> Ash.update!(tenant: workspace.id, actor: admin)

    volunteer_application =
      VolunteerApplication
      |> Ash.Changeset.for_create(
        :create,
        %{
          cohort_id: cohort.id,
          position: :tutor,
          city: "上海",
          heard_about_us: "小红书",
          has_internal_referrer: false
        },
        tenant: workspace.id
      )
      |> Ash.create!(tenant: workspace.id, actor: user_a)

    %{
      since: since,
      baseline: baseline,
      workspace: workspace,
      user_a: user_a,
      user_b: user_b,
      user_c: user_c,
      initiative: initiative,
      enrollment_a: enrollment_a,
      enrollment_b: enrollment_b,
      enrollment_c: enrollment_c,
      volunteer_application: volunteer_application
    }
  end

  describe "首个身份口径的新用户计数" do
    test "xhs +1、wechat +1（B 归首个身份）、none +2（C + 无身份的 platform_admin 固定装置）",
         %{since: since, baseline: baseline} do
      {:ok, result} = AcquisitionStats.stats(since: since)

      assert delta(result.new_users, baseline.new_users) == %{
               "xhs" => 1,
               "wechat" => 1,
               "tt" => 0,
               "wechat_web" => 0,
               "none" => 2
             }
    end
  end

  describe "报名按 platform × status 分组 + initiative_slug 过滤" do
    test "不传 slug：含 A、B、C 三条", %{since: since, baseline: baseline} do
      {:ok, result} = AcquisitionStats.stats(since: since)

      assert sort_rows(delta_rows(result.enrollments, baseline.enrollments)) ==
               sort_rows([
                 %{platform: "xhs", status: "confirmed", count: 1},
                 %{platform: "wechat", status: "payment_pending", count: 1},
                 %{platform: "none", status: "confirmed", count: 1}
               ])
    end

    test "传 slug=hackerstart1024：只含 A、B（挂载场次），不含 C" do
      {:ok, result} =
        AcquisitionStats.stats(since: old_since(), initiative_slug: "hackerstart1024")

      assert sort_rows(result.enrollments) ==
               sort_rows([
                 %{platform: "xhs", status: "confirmed", count: 1},
                 %{platform: "wechat", status: "payment_pending", count: 1}
               ])
    end

    test "未知 slug → {:error, :initiative_not_found}" do
      assert {:error, :initiative_not_found} =
               AcquisitionStats.stats(since: old_since(), initiative_slug: "does-not-exist")
    end
  end

  describe "志愿者申请按平台分组" do
    test "xhs +1（A 提交）", %{since: since, baseline: baseline} do
      {:ok, result} = AcquisitionStats.stats(since: since)

      assert sort_rows(delta_rows(result.volunteer_applications, baseline.volunteer_applications)) ==
               [%{platform: "xhs", status: "submitted", count: 1}]
    end
  end

  describe "时间窗" do
    test "since 晚于所有数据 → 各项全 0 / 空" do
      future_since = DateTime.add(DateTime.utc_now(), 1, :day)

      {:ok, result} = AcquisitionStats.stats(since: future_since)

      assert result.new_users == %{
               "xhs" => 0,
               "wechat" => 0,
               "tt" => 0,
               "wechat_web" => 0,
               "none" => 0
             }

      assert result.enrollments == []
      assert result.volunteer_applications == []
    end
  end

  describe "零 PII" do
    test "序列化后 key 集合精确等于约定集合，不含 user_id / 手机 / 邮箱 / 姓名" do
      {:ok, result} = AcquisitionStats.stats(since: old_since())

      json = result |> Jason.encode!() |> Jason.decode!()

      assert Map.keys(json) |> Enum.sort() ==
               ["enrollments", "new_users", "volunteer_applications", "window"]

      assert Map.keys(json["window"]) == ["since"]

      for row <- json["enrollments"] ++ json["volunteer_applications"] do
        assert Map.keys(row) |> Enum.sort() == ["count", "platform", "status"]
      end

      full_json = Jason.encode!(result)
      refute full_json =~ "user_id"
      refute full_json =~ "phone"
      refute full_json =~ "email"
      refute full_json =~ "@example.com"
    end
  end

  defp old_since, do: DateTime.add(DateTime.utc_now(), -30, :day)

  defp sort_rows(rows), do: Enum.sort_by(rows, &{&1.platform, &1.status})

  # 增量断言辅助：`after - before`，隔离全量套件里其他用例往同一张全局表
  # 落的噪声行（见 setup 顶部注释）。
  defp delta(after_map, before_map) do
    Map.new(after_map, fn {platform, count} ->
      {platform, count - Map.get(before_map, platform, 0)}
    end)
  end

  defp delta_rows(after_rows, before_rows) do
    before_counts =
      Map.new(before_rows, fn %{platform: p, status: s, count: c} -> {{p, s}, c} end)

    after_rows
    |> Enum.map(fn %{platform: p, status: s, count: c} = row ->
      %{row | count: c - Map.get(before_counts, {p, s}, 0)}
    end)
    |> Enum.reject(&(&1.count == 0))
  end

  defp enroll(workspace, user, event, extra_attrs) do
    attrs =
      Map.merge(%{event_id: event.id, user_id: user.id, age_confirmed: true}, extra_attrs)

    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, attrs, tenant: workspace.id)
    |> Ash.create!(tenant: workspace.id, actor: user)
  end

  defp insert_identity(user_id, provider, uid, inserted_at \\ DateTime.utc_now()) do
    Cgc2046.Repo.query!(
      """
      INSERT INTO user_identities (id, provider, uid, user_id, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, $2, $3, $4, NOW())
      """,
      [to_string(provider), uid, Ecto.UUID.dump!(user_id), inserted_at]
    )
  end
end
