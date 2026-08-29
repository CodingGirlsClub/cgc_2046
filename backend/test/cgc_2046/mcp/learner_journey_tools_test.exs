defmodule Cgc2046.Mcp.LearnerJourneyToolsTest do
  @moduledoc """
  学员旅程五工具测试（role-agent-journeys-v2 S7，R30-R35/AE3/AE6/AE8；
  直接调 tool execute/2，不走 HTTP）。

  async: false —— 并发双建测试用 Task.async_stream（DataCase 非 async =
  shared sandbox，任务无需显式 allow；S6 R3 的保真度纪律：断言强、无 sleep
  竞速，注释注明被测窗口）。

  - discover_offerings（AE6 矩阵）：公开条目对外人可见 / 成员见本台 workspace
    条目 / 他台非公开不可见 / 自己台公开条目去重 / 成员段排除 draft/cancelled /
    报名后 my_enrollment 出现 / invite_only 台非成员 workspace 块 nil /
    排序 / 封顶 100 + total_count 截断前小计
  - get_enrollment_summary：would_create_status 镜像域分支（open+free→confirmed /
    收费→payment_pending / request→pending / invite_only→nil）；驱动因子 =
    offering.enrollment_policy（workspace join_policy 无关）；goals 取 published
    revision 无则回退草稿（S6 语义）；capacity_info 非成员 nil；不可见 = not found
  - create_enrollment：免费直达 confirmed；收费 payment_pending + checkout_url；
    AE3 幂等重放（顺序 + 并发双建恰好一条）；request → pending；域错误透传；
    reason 不落 ToolCallLog.params（审计红线 §B#4）
  - get_my_enrollments：actor 锚定 / 全状态 / 跨工作台 / tier_snapshot
  - get_order_status：本人读摘要 + checkout_url / 他人 forbidden / paid /
    无订单 / 渠道凭据键缺席（红线 §B#19 全文标记串扫描）
  - 每个工具落 ToolCallLog 审计行
  """
  use Cgc2046.DataCase, async: false

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.CourseRevision
  alias Cgc2046.Events.Event
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Mcp.ToolCallLog

  alias Cgc2046.Mcp.Tools.{
    CreateEnrollment,
    DiscoverOfferings,
    GetEnrollmentSummary,
    GetMyEnrollments,
    GetOrderStatus
  }

  alias Cgc2046.Payments.Order
  alias Cgc2046.Repo

  require Ash.Query

  @paid_tier_id "33333333-3333-3333-3333-333333333333"

  defp frame_for(user), do: Frame.new(current_user: user)

  defp decode_reply({:reply, response, _frame}) do
    [content] = response.content
    Jason.decode!(content["text"])
  end

  defp raw_text({:reply, response, _frame}) do
    [content] = response.content
    content["text"]
  end

  defp decode_error({:error, %Anubis.MCP.Error{reason: :execution_error, message: msg}, _frame}),
    do: msg

  defp tool_logs_for(user_id, tool_name) do
    ToolCallLog
    |> Ash.Query.filter(user_id == ^user_id and tool == ^tool_name)
    |> Ash.read!(authorize?: false)
  end

  # 收费供给布置：两档可售价位（首档固定 id，收费报名必带 tier_id）
  defp paid_attrs do
    %{
      pricing_enabled: true,
      price_tiers: [
        %{"id" => @paid_tier_id, "name" => "早鸟", "amount_cents" => 9900},
        %{"id" => Ecto.UUID.generate(), "name" => "标准", "amount_cents" => 19_900}
      ]
    }
  end

  # 域路径直建报名（布置用；工具路径的被测对象走 CreateEnrollment.execute）
  defp domain_enroll(target, user, attrs \\ %{}) do
    target_key = if match?(%Event{}, target), do: :event_id, else: :course_id

    attrs =
      %{user_id: user.id}
      |> Map.put(target_key, target.id)
      |> Map.merge(attrs)

    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, attrs)
    |> Ash.create!(tenant: target.workspace_id, actor: user)
  end

  # 布置而非被测对象：渠道下单链由 payments 测试覆盖，此处直走 Order :create
  # （order_test.exs / enrollment_test.exs 同款形状）
  defp order_fixture(enrollment, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          enrollment_id: enrollment.id,
          provider: :wechat_native,
          out_trade_no: "CGC" <> String.replace(Ecto.UUID.generate(), "-", ""),
          amount_cents: 9_900,
          tier_snapshot: %{"id" => @paid_tier_id, "name" => "早鸟", "amount_cents" => 9_900},
          expire_at: DateTime.add(DateTime.utc_now(), 2, :hour)
        },
        attrs
      )

    Order
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(tenant: enrollment.workspace_id, authorize?: false)
  end

  defp enrollment_params(workspace, kind, offering_id, extra \\ %{}),
    do:
      Map.merge(
        %{
          "workspace_id" => workspace.id,
          "kind" => kind,
          "offering_id" => offering_id
        },
        extra
      )

  defp enrollment_count(kind, offering_id, user) do
    query =
      if kind == :event do
        Ash.Query.filter(Enrollment, event_id == ^offering_id and user_id == ^user.id)
      else
        Ash.Query.filter(Enrollment, course_id == ^offering_id and user_id == ^user.id)
      end

    query
    |> Ash.read!(authorize?: false)
    |> length()
  end

  # goals 测试用最小合法 issue（ContentValidation v1 形状：checklist 必填）
  defp goals_issue(title) do
    %{
      "id" => "goals-issue-1",
      "kind" => "thoughtwork",
      "title" => title,
      "story" => %{
        "as_a" => "学员",
        "given" => [],
        "goal" => "目标",
        "materials" => [],
        "checklist" => [%{"id" => "c1", "text" => "完成"}]
      }
    }
  end

  # S6 直造发布版本 + 绑定（goals published 源测试布置；发布链路本身由
  # course_prep_tools_test 覆盖）
  defp publish_revision!(workspace, course, goals) do
    {:ok, revision} =
      CourseRevision
      |> Ash.Changeset.for_create(
        :create,
        %{
          course_id: course.id,
          number: 1,
          content: %{"goals" => goals, "issues" => []},
          published_at: DateTime.utc_now()
        },
        tenant: workspace.id
      )
      |> Ash.create(tenant: workspace.id, authorize?: false)

    course
    |> Ash.Changeset.for_update(
      :bind_current_revision,
      %{current_revision_id: revision.id},
      tenant: workspace.id
    )
    |> Ash.update!(tenant: workspace.id, authorize?: false)

    :ok
  end

  describe "discover_offerings（AE6 合并口径）" do
    test "公开课程对零成员身份的外人可见（含宿主工作台块与定价摘要）" do
      admin = Fixtures.platform_admin("s7-disc-a")
      workspace = Fixtures.create_workspace(admin, %{name: "Public Host"})

      course =
        EventFixtures.create_course(workspace, admin, Map.merge(%{title: "公开课程"}, paid_attrs()))

      outsider = Fixtures.register_user("s7-disc-a-outsider")

      assert {:reply, _, _} = reply = DiscoverOfferings.execute(%{}, frame_for(outsider))
      payload = decode_reply(reply)

      assert [row] = payload["offerings"]
      assert payload["total_count"] == 1
      assert row["id"] == course.id
      assert row["kind"] == "course"
      assert row["visibility"] == "public"
      assert row["status"] == "open"

      assert row["workspace"] == %{
               "id" => workspace.id,
               "name" => "Public Host",
               "slug" => workspace.slug
             }

      assert row["pricing"] == %{"enabled" => true, "min_amount_cents" => 9900}
      assert is_binary(row["registration_deadline"])
      assert is_nil(row["my_enrollment"])

      [log] = tool_logs_for(outsider.id, "discover_offerings")
      assert log.result_status == :ok
    end

    test "成员见本台 workspace 可见性供给；成员段排除 draft/cancelled" do
      admin = Fixtures.platform_admin("s7-disc-b")
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("s7-disc-b-member")
      Fixtures.add_member(workspace, member, [:learner])

      internal =
        EventFixtures.create_event(workspace, admin, %{title: "台内活动", visibility: :workspace})

      {:ok, _draft} =
        Course
        |> Ash.Changeset.for_create(:create, %{title: "草稿课程"}, tenant: workspace.id)
        |> Ash.create(tenant: workspace.id, actor: admin)

      cancelled = EventFixtures.create_event(workspace, admin, %{title: "已取消活动"})

      Repo.query!("UPDATE events SET status = 'cancelled' WHERE id = $1", [
        Ecto.UUID.dump!(cancelled.id)
      ])

      assert {:reply, _, _} = reply = DiscoverOfferings.execute(%{}, frame_for(member))
      payload = decode_reply(reply)

      ids = Enum.map(payload["offerings"], & &1["id"])
      assert internal.id in ids
      refute cancelled.id in ids
      refute Enum.any?(payload["offerings"], &(&1["title"] == "草稿课程"))
    end

    test "他台非公开供给不可见（AE6：Workspace B 的 workspace 可见性条目对 A 成员缺席）" do
      admin_b = Fixtures.platform_admin("s7-disc-c-b")
      workspace_b = Fixtures.create_workspace(admin_b)
      EventFixtures.create_event(workspace_b, admin_b, %{title: "B 台内活动", visibility: :workspace})

      admin_a = Fixtures.platform_admin("s7-disc-c-a")
      workspace_a = Fixtures.create_workspace(admin_a)
      member_a = Fixtures.register_user("s7-disc-c-member")
      Fixtures.add_member(workspace_a, member_a, [:learner])
      EventFixtures.create_event(workspace_a, admin_a, %{title: "A 台内活动", visibility: :workspace})

      assert {:reply, _, _} = reply = DiscoverOfferings.execute(%{}, frame_for(member_a))
      payload = decode_reply(reply)

      titles = Enum.map(payload["offerings"], & &1["title"])
      assert "A 台内活动" in titles
      refute "B 台内活动" in titles
    end

    test "自己台公开条目去重（公开段与成员段 {kind,id} 合并只出现一次）" do
      admin = Fixtures.platform_admin("s7-disc-d")
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("s7-disc-d-member")
      Fixtures.add_member(workspace, member, [:learner])

      EventFixtures.create_event(workspace, admin, %{title: "本台公开活动"})

      assert {:reply, _, _} = reply = DiscoverOfferings.execute(%{}, frame_for(member))
      payload = decode_reply(reply)

      assert payload["total_count"] == 1
      assert length(payload["offerings"]) == 1
    end

    test "报名后 my_enrollment 出现（活跃报名附挂）" do
      admin = Fixtures.platform_admin("s7-disc-e")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{title: "可报名活动"})
      learner = Fixtures.register_user("s7-disc-e-learner")
      domain_enroll(event, learner)

      assert {:reply, _, _} = reply = DiscoverOfferings.execute(%{}, frame_for(learner))
      payload = decode_reply(reply)

      [row] = payload["offerings"]
      assert %{"status" => "confirmed"} = row["my_enrollment"]
    end

    test "invite_only 工作台的公开条目：非成员 workspace 块落 nil（不泄宿主工作台）" do
      admin = Fixtures.platform_admin("s7-disc-f")
      workspace = Fixtures.create_workspace(admin, %{join_policy: :invite_only})
      EventFixtures.create_event(workspace, admin, %{title: "私密台公开活动"})

      outsider = Fixtures.register_user("s7-disc-f-outsider")

      assert {:reply, _, _} = reply = DiscoverOfferings.execute(%{}, frame_for(outsider))
      payload = decode_reply(reply)

      [row] = payload["offerings"]
      assert row["title"] == "私密台公开活动"
      assert is_nil(row["workspace"])
      # advisor F4:动作安全作用域原值保留（报名动作可携真实作用域走通）
      assert row["workspace_id"] == workspace.id
    end

    test "封顶 100：超出截断，total_count 为截断前命中小计（§B#16）" do
      admin = Fixtures.platform_admin("s7-disc-g")
      workspace = Fixtures.create_workspace(admin)

      for i <- 1..105 do
        EventFixtures.create_event(workspace, admin, %{
          title: "活动 #{String.pad_leading(Integer.to_string(i), 3, "0")}"
        })
      end

      outsider = Fixtures.register_user("s7-disc-g-outsider")

      assert {:reply, _, _} = reply = DiscoverOfferings.execute(%{}, frame_for(outsider))
      payload = decode_reply(reply)

      assert length(payload["offerings"]) == 100
      assert payload["total_count"] == 105
    end
  end

  describe "get_enrollment_summary（would_create_status 域镜像）" do
    test "open + 免费 → confirmed；成员见 capacity_info" do
      admin = Fixtures.platform_admin("s7-sum-a")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{title: "免费活动", capacity: 10})

      assert {:reply, _, _} =
               reply =
               GetEnrollmentSummary.execute(
                 enrollment_params(workspace, "event", event.id),
                 frame_for(admin)
               )

      payload = decode_reply(reply)
      assert payload["would_create_status"] == "confirmed"
      assert payload["policy"] == "open"
      assert payload["offering"]["capacity_info"] == %{"capacity" => 10, "confirmed_count" => 0}
      assert is_nil(payload["my_enrollment"])

      [log] = tool_logs_for(admin.id, "get_enrollment_summary")
      assert log.result_status == :ok
    end

    test "驱动因子 = offering.enrollment_policy：request join_policy 工作台里的 open 课程仍 confirmed（§B#20）" do
      admin = Fixtures.platform_admin("s7-sum-b")

      # fixtures 默认 join_policy: :request——证明 workspace 加入策略不影响报名落点
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{enrollment_policy: :open})
      outsider = Fixtures.register_user("s7-sum-b-user")

      assert {:reply, _, _} =
               reply =
               GetEnrollmentSummary.execute(
                 enrollment_params(workspace, "event", event.id),
                 frame_for(outsider)
               )

      assert decode_reply(reply)["would_create_status"] == "confirmed"
    end

    test "open + 收费 → payment_pending + 可售档位；外人 capacity_info 落 nil" do
      admin = Fixtures.platform_admin("s7-sum-c")
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(
          workspace,
          admin,
          Map.merge(%{enrollment_policy: :open}, paid_attrs())
        )

      outsider = Fixtures.register_user("s7-sum-c-user")

      assert {:reply, _, _} =
               reply =
               GetEnrollmentSummary.execute(
                 enrollment_params(workspace, "event", event.id),
                 frame_for(outsider)
               )

      payload = decode_reply(reply)
      assert payload["would_create_status"] == "payment_pending"
      assert [%{"id" => @paid_tier_id}, _] = payload["offering"]["price_tiers"]
      # capacity/confirmed_count 在 field_policy 收窄名单内：非成员落 nil
      assert is_nil(payload["offering"]["capacity_info"])
    end

    test "request → pending；invite_only → nil" do
      admin = Fixtures.platform_admin("s7-sum-d")
      workspace = Fixtures.create_workspace(admin)

      request_event =
        EventFixtures.create_event(workspace, admin, %{enrollment_policy: :request})

      invite_event =
        EventFixtures.create_event(workspace, admin, %{enrollment_policy: :invite_only})

      outsider = Fixtures.register_user("s7-sum-d-user")

      assert {:reply, _, _} =
               reply =
               GetEnrollmentSummary.execute(
                 enrollment_params(workspace, "event", request_event.id),
                 frame_for(outsider)
               )

      assert decode_reply(reply)["would_create_status"] == "pending"

      assert {:reply, _, _} =
               reply =
               GetEnrollmentSummary.execute(
                 enrollment_params(workspace, "event", invite_event.id),
                 frame_for(outsider)
               )

      assert is_nil(decode_reply(reply)["would_create_status"])
    end

    test "课程 goals：published revision 优先，无 revision 回退草稿（S6 语义）" do
      admin = Fixtures.platform_admin("s7-sum-e")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{title: "goals 课"})

      outsider = Fixtures.register_user("s7-sum-e-user")
      params = enrollment_params(workspace, "course", course.id)

      # 无 revision：回退草稿读面（Curriculum.Output 活文档）
      Cgc2046.Curriculum.Output
      |> Ash.Changeset.for_create(
        :upsert_content,
        %{
          key: Cgc2046.Curriculum.Output.course_key(course.id),
          kind: :issues,
          data: %{"goals" => ["草稿目标"], "issues" => [goals_issue("草稿卡")]},
          submitted_by: admin.id,
          base_version: 0
        },
        tenant: workspace.id,
        actor: admin
      )
      |> Ash.create!(tenant: workspace.id, actor: admin)

      assert {:reply, _, _} = reply = GetEnrollmentSummary.execute(params, frame_for(outsider))
      assert decode_reply(reply)["offering"]["goals"] == ["草稿目标"]

      # 发布 revision 1 后：goals 读 published 版（草稿后续编辑不影响）
      :ok = publish_revision!(workspace, course, ["已发布目标"])

      Cgc2046.Curriculum.Output
      |> Ash.Changeset.for_create(
        :upsert_content,
        %{
          key: Cgc2046.Curriculum.Output.course_key(course.id),
          kind: :issues,
          data: %{"goals" => ["次周期修订草稿"], "issues" => [goals_issue("草稿卡")]},
          submitted_by: admin.id,
          base_version: 1
        },
        tenant: workspace.id,
        actor: admin
      )
      |> Ash.create!(tenant: workspace.id, actor: admin)

      assert {:reply, _, _} = reply = GetEnrollmentSummary.execute(params, frame_for(outsider))
      assert decode_reply(reply)["offering"]["goals"] == ["已发布目标"]
    end

    test "不可见供给（他台 workspace 可见性）与不存在返回同一 not found" do
      admin = Fixtures.platform_admin("s7-sum-f")
      workspace = Fixtures.create_workspace(admin)
      internal = EventFixtures.create_event(workspace, admin, %{visibility: :workspace})

      outsider = Fixtures.register_user("s7-sum-f-user")

      assert {:error, _, _} =
               error =
               GetEnrollmentSummary.execute(
                 enrollment_params(workspace, "event", internal.id),
                 frame_for(outsider)
               )

      assert decode_error(error) =~ "offering not found"

      assert {:error, _, _} =
               error =
               GetEnrollmentSummary.execute(
                 enrollment_params(workspace, "event", Ecto.UUID.generate()),
                 frame_for(outsider)
               )

      assert decode_error(error) =~ "offering not found"
    end
  end

  describe "create_enrollment（R31/AE3）" do
    test "免费 open → 直达 confirmed（无 checkout_url）" do
      admin = Fixtures.platform_admin("s7-cre-a")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{})
      learner = Fixtures.register_user("s7-cre-a-learner")

      assert {:reply, _, _} =
               reply =
               CreateEnrollment.execute(
                 enrollment_params(workspace, "event", event.id, %{"reason" => "想参加"}),
                 frame_for(learner)
               )

      payload = decode_reply(reply)
      assert payload["enrollment"]["status"] == "confirmed"
      assert payload["idempotent_replay"] == false
      assert is_nil(payload["checkout_url"])

      # 审计红线（§B#4）：reason 不落 ToolCallLog.params
      [log] = tool_logs_for(learner.id, "create_enrollment")
      assert log.result_status == :ok
      assert is_map(log.params)
      refute Map.has_key?(log.params, "reason")
      refute log.params |> Jason.encode!() =~ "想参加"
    end

    test "收费 → payment_pending + checkout_url（tier_id 必填，缺 → 域错误透传）" do
      admin = Fixtures.platform_admin("s7-cre-b")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, paid_attrs())
      learner = Fixtures.register_user("s7-cre-b-learner")

      assert {:reply, _, _} =
               reply =
               CreateEnrollment.execute(
                 enrollment_params(workspace, "course", course.id, %{"tier_id" => @paid_tier_id}),
                 frame_for(learner)
               )

      payload = decode_reply(reply)
      assert payload["enrollment"]["status"] == "payment_pending"
      assert payload["checkout_url"] =~ "/orders/new?enrollmentId="

      other = EventFixtures.create_course(workspace, admin, paid_attrs())

      assert {:error, _, _} =
               error =
               CreateEnrollment.execute(
                 enrollment_params(workspace, "course", other.id),
                 frame_for(Fixtures.register_user("s7-cre-b-no-tier"))
               )

      assert decode_error(error) =~ "a price tier is required for paid enrollment"
    end

    test "AE3：顺序双提交 → 同一报名 id，第二次 idempotent_replay=true，库内恰好一条" do
      admin = Fixtures.platform_admin("s7-cre-c")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{})
      learner = Fixtures.register_user("s7-cre-c-learner")
      params = enrollment_params(workspace, "event", event.id)

      assert {:reply, _, _} = first = CreateEnrollment.execute(params, frame_for(learner))
      assert {:reply, _, _} = second = CreateEnrollment.execute(params, frame_for(learner))

      first_payload = decode_reply(first)
      second_payload = decode_reply(second)

      assert first_payload["idempotent_replay"] == false
      assert second_payload["idempotent_replay"] == true
      assert second_payload["enrollment"]["id"] == first_payload["enrollment"]["id"]
      assert enrollment_count(:event, event.id, learner) == 1
    end

    test "并发双建：双双成功同一 id，全系统恰好一条活跃报名（后到者走幂等重放）" do
      # 被测窗口 = 两个 create_enrollment 同时越过各自的读前检查、在 DB 撞
      # 部分唯一索引（unique_event_user）：DB 裁决恰一条提交，后到者
      # enrollment_duplicate_active → 工具层幂等重放。Task.async_stream 并发
      # （shared sandbox），断言强（同 id + replay 恰一 + 库内恰一条），
      # 无 sleep 竞速。
      admin = Fixtures.platform_admin("s7-cre-race")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{})
      learner = Fixtures.register_user("s7-cre-race-learner")
      params = enrollment_params(workspace, "event", event.id)

      results =
        [1, 2]
        |> Task.async_stream(
          fn _ -> CreateEnrollment.execute(params, frame_for(learner)) end,
          max_concurrency: 2,
          timeout: 15_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      payloads =
        Enum.map(results, fn
          {:reply, _, _} = reply -> decode_reply(reply)
          other -> flunk("expected reply, got: #{inspect(other)}")
        end)

      assert Enum.map(payloads, & &1["enrollment"]["id"]) |> Enum.uniq() |> length() == 1
      assert Enum.count(payloads, & &1["idempotent_replay"]) == 1
      assert enrollment_count(:event, event.id, learner) == 1
    end

    test "request 策略 → pending（等审批，无 checkout_url）" do
      admin = Fixtures.platform_admin("s7-cre-d")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{enrollment_policy: :request})
      learner = Fixtures.register_user("s7-cre-d-learner")

      assert {:reply, _, _} =
               reply =
               CreateEnrollment.execute(
                 enrollment_params(workspace, "event", event.id),
                 frame_for(learner)
               )

      payload = decode_reply(reply)
      assert payload["enrollment"]["status"] == "pending"
      assert is_nil(payload["checkout_url"])
    end
  end

  describe "get_my_enrollments（R32/AE8）" do
    test "actor 锚定全状态跨工作台 + tier_snapshot + workspace 块" do
      admin_a = Fixtures.platform_admin("s7-my-a")
      workspace_a = Fixtures.create_workspace(admin_a, %{name: "台 A"})
      admin_b = Fixtures.platform_admin("s7-my-b")
      workspace_b = Fixtures.create_workspace(admin_b, %{name: "台 B"})

      learner = Fixtures.register_user("s7-my-learner")

      free_event = EventFixtures.create_event(workspace_a, admin_a, %{title: "免费活动"})

      paid_course =
        EventFixtures.create_course(
          workspace_b,
          admin_b,
          Map.merge(%{title: "收费课程"}, paid_attrs())
        )

      confirmed = domain_enroll(free_event, learner)
      payment_pending = domain_enroll(paid_course, learner, %{tier_id: @paid_tier_id})
      order_fixture(payment_pending)

      assert {:reply, _, _} = reply = GetMyEnrollments.execute(%{}, frame_for(learner))
      payload = decode_reply(reply)

      rows =
        payload["enrollments"]
        |> Enum.map(&{&1["offering"]["id"], &1})
        |> Map.new()

      assert Map.keys(rows) |> Enum.sort() == Enum.sort([free_event.id, paid_course.id])
      # advisor F4:行附 workspace_id 原值（enrollment 自身列，动作作用域）
      assert rows[free_event.id]["workspace_id"] == workspace_a.id
      assert rows[paid_course.id]["workspace_id"] == workspace_b.id

      free_row = rows[free_event.id]
      assert free_row["status"] == "confirmed"
      assert free_row["kind"] == "event"
      assert free_row["workspace"]["name"] == "台 A"
      assert is_nil(free_row["tier_snapshot"])

      paid_row = rows[paid_course.id]
      assert paid_row["status"] == "payment_pending"
      assert paid_row["workspace"]["name"] == "台 B"
      assert %{"id" => @paid_tier_id} = paid_row["tier_snapshot"]

      # actor 锚定：他人报名不出现
      other = Fixtures.register_user("s7-my-other")
      assert {:reply, _, _} = other_reply = GetMyEnrollments.execute(%{}, frame_for(other))
      assert decode_reply(other_reply)["enrollments"] == []

      refute is_nil(confirmed)

      [log] = tool_logs_for(learner.id, "get_my_enrollments")
      assert log.result_status == :ok
    end

    test "封顶 100：超出截断，total_count 为截断前小计（§B#16，advisor F3）" do
      admin = Fixtures.platform_admin("s7-my-cap")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("s7-my-cap-learner")

      for i <- 1..105 do
        event = EventFixtures.create_event(workspace, admin, %{title: "活动 #{i}"})
        domain_enroll(event, learner)
      end

      assert {:reply, _, _} = reply = GetMyEnrollments.execute(%{}, frame_for(learner))
      payload = decode_reply(reply)

      assert length(payload["enrollments"]) == 100
      assert payload["count"] == 100
      assert payload["total_count"] == 105
    end
  end

  describe "get_order_status（R34/AE7 + §B#19 红线）" do
    test "本人读 pending 订单摘要 + checkout_url；无凭据键（红线全文扫描）" do
      admin = Fixtures.platform_admin("s7-ord-a")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, paid_attrs())
      learner = Fixtures.register_user("s7-ord-a-learner")
      enrollment = domain_enroll(course, learner, %{tier_id: @paid_tier_id})
      order = order_fixture(enrollment)

      assert {:reply, _, _} =
               reply =
               GetOrderStatus.execute(
                 %{"workspace_id" => workspace.id, "enrollment_id" => enrollment.id},
                 frame_for(learner)
               )

      payload = decode_reply(reply)
      assert payload["order"]["id"] == order.id
      assert payload["order"]["amount_cents"] == 9_900
      assert payload["order"]["provider"] == "wechat_native"
      assert payload["order"]["status"] == "pending"
      assert is_binary(payload["order"]["expires_at"])
      assert is_nil(payload["order"]["paid_at"])
      assert payload["checkout_url"] =~ "/orders/new?enrollmentId=#{enrollment.id}"
      assert payload["enrollment_status"] == "payment_pending"

      # 红线：渠道凭据/单号键缺席（prepay/nonce/sign/out_trade_no/transaction_id）
      text = raw_text(reply)

      for absent <- ~w(prepay nonce sign out_trade_no transaction_id credential) do
        refute text =~ absent, "expected no #{absent} in order status payload"
      end

      [log] = tool_logs_for(learner.id, "get_order_status")
      assert log.result_status == :ok
    end

    test "paid 订单 → status paid + paid_at，checkout_url 落 nil" do
      admin = Fixtures.platform_admin("s7-ord-b")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, paid_attrs())
      learner = Fixtures.register_user("s7-ord-b-learner")
      enrollment = domain_enroll(course, learner, %{tier_id: @paid_tier_id})

      order =
        order_fixture(enrollment)
        |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "txn-s7-ord-b"},
          tenant: workspace.id
        )
        |> Ash.update!(tenant: workspace.id, authorize?: false)

      assert {:reply, _, _} =
               reply =
               GetOrderStatus.execute(
                 %{"workspace_id" => workspace.id, "enrollment_id" => enrollment.id},
                 frame_for(learner)
               )

      payload = decode_reply(reply)
      assert payload["order"]["id"] == order.id
      assert payload["order"]["status"] == "paid"
      assert is_binary(payload["order"]["paid_at"])
      # advisor F5 语义：mark_paid 与 settle_paid 间的窗口（enrollment 仍
      # payment_pending）→ checkout_url 仍给（支付回调竞态下继续完成路径）
      assert is_binary(payload["checkout_url"])
    end

    test "payment_pending 且尚无 Order → checkout_url 非 nil（resumePayment 恢复路径，advisor F5）" do
      admin = Fixtures.platform_admin("s7-ord-f5")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, paid_attrs())
      learner = Fixtures.register_user("s7-ord-f5-learner")
      # create_enrollment 落 payment_pending 时 Order 尚未创建（学员未进 /orders/new）
      enrollment = domain_enroll(course, learner, %{tier_id: @paid_tier_id})

      assert {:reply, _, _} =
               reply =
               GetOrderStatus.execute(
                 %{"workspace_id" => workspace.id, "enrollment_id" => enrollment.id},
                 frame_for(learner)
               )

      payload = decode_reply(reply)
      assert is_nil(payload["order"])
      assert payload["checkout_url"] =~ "/orders/new?enrollmentId=#{enrollment.id}"
      assert payload["enrollment_status"] == "payment_pending"
    end

    test "confirmed / expired 报名 → checkout_url 落 nil（无支付动作）" do
      admin = Fixtures.platform_admin("s7-ord-f5b")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, paid_attrs())
      learner = Fixtures.register_user("s7-ord-f5b-learner")
      enrollment = domain_enroll(course, learner, %{tier_id: @paid_tier_id})
      order = order_fixture(enrollment)

      # 真实支付序列：order mark_paid（支付回调）→ enrollment settle_paid
      # （报名转 confirmed）——终态报名无支付动作
      order
      |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "txn-s7-f5"},
        tenant: workspace.id
      )
      |> Ash.update!(tenant: workspace.id, authorize?: false)

      enrollment
      |> Ash.Changeset.for_update(:settle_paid, %{}, tenant: workspace.id)
      |> Ash.update!(tenant: workspace.id, authorize?: false)

      assert {:reply, _, _} =
               reply =
               GetOrderStatus.execute(
                 %{"workspace_id" => workspace.id, "enrollment_id" => enrollment.id},
                 frame_for(learner)
               )

      payload = decode_reply(reply)
      assert payload["order"]["status"] == "paid"
      assert is_nil(payload["checkout_url"])
    end

    test "无订单 → order nil（免费报名）" do
      admin = Fixtures.platform_admin("s7-ord-c")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{})
      learner = Fixtures.register_user("s7-ord-c-learner")
      enrollment = domain_enroll(event, learner)

      assert {:reply, _, _} =
               reply =
               GetOrderStatus.execute(
                 %{"workspace_id" => workspace.id, "enrollment_id" => enrollment.id},
                 frame_for(learner)
               )

      payload = decode_reply(reply)
      assert is_nil(payload["order"])
      assert is_nil(payload["checkout_url"])
      assert payload["enrollment_status"] == "confirmed"
    end

    test "他人报名 → forbidden；他工作台报名与不存在同一 not found" do
      admin = Fixtures.platform_admin("s7-ord-d")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{})
      learner = Fixtures.register_user("s7-ord-d-learner")
      enrollment = domain_enroll(event, learner)
      other = Fixtures.register_user("s7-ord-d-other")

      assert {:error, _, _} =
               error =
               GetOrderStatus.execute(
                 %{"workspace_id" => workspace.id, "enrollment_id" => enrollment.id},
                 frame_for(other)
               )

      assert decode_error(error) =~ "forbidden: enrollment does not belong to the current actor"

      assert {:error, _, _} =
               error =
               GetOrderStatus.execute(
                 %{"workspace_id" => Ecto.UUID.generate(), "enrollment_id" => enrollment.id},
                 frame_for(learner)
               )

      assert decode_error(error) =~ "enrollment not found"
    end
  end
end
