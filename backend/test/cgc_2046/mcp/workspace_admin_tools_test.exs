defmodule Cgc2046.Mcp.WorkspaceAdminToolsTest do
  @moduledoc """
  工作台管理十三工具测试（role-agent-journeys-v2 S3，直接调 tool execute/2，
  不走 HTTP；member_tools_test 同款模式）。

  - 授权：plain member / tutor / learner / 非成员对全部 13 工具一律 forbidden
    （非成员撞 Wrapper member 门；成员撞工具层 Owner/Admin 判定）
  - 读：list_course_enrollments / list_workspace_orders 只回本工作台行
    （跨租户隔离：第二工作台的课程/报名/订单不漏；他台 course_id ≡ not found）
  - 写：needs_confirmation → 无副作用 → confirm → domain effect → 审计行
    （create_course 为唯一直接写）；cancel 路径不留副作用（refund_order /
    update_course）
  - create_course 零输入草稿：临时占位标题 + provisional_title 标记；
    launch 命名门（第一段快速失败 + 域 action 层双拦截，R21/AE1）
  - update_course 影响摘要：pricing_enabled true→false 时摘要含批量免缴笔数
  - 错误路径：refund 非 paid 订单 / waive 非 payment_pending 报名 / launch
    已 open 课程——错误以消息返回，不建 pending，不炸
  """
  use Cgc2046.DataCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  alias Anubis.Server.Frame
  alias Cgc2046.Accounts.{AdminActionLog, Workspace}
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Courses.Course
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Mcp.{PendingOperation, ToolCallLog}

  alias Cgc2046.Mcp.Tools.{
    CancelCourse,
    CancelOperation,
    CloseCourse,
    ConfirmEnrollment,
    ConfirmOperation,
    CreateCourse,
    LaunchCourse,
    ListCourseEnrollments,
    ListWorkspaceOrders,
    RefundOrder,
    RejectEnrollment,
    RetryRefund,
    UpdateCourse,
    UpdateJoinPolicy,
    WaivePayment
  }

  alias Cgc2046.Payments.Order
  alias Cgc2046.Payments.Workers.PaymentRefundWorker

  require Ash.Query

  @tier_id "88888888-8888-8888-8888-888888888888"
  @tier %{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900}

  @tool_modules %{
    "create_course" => CreateCourse,
    "update_course" => UpdateCourse,
    "launch_course" => LaunchCourse,
    "close_course" => CloseCourse,
    "cancel_course" => CancelCourse,
    "list_course_enrollments" => ListCourseEnrollments,
    "confirm_enrollment" => ConfirmEnrollment,
    "reject_enrollment" => RejectEnrollment,
    "waive_payment" => WaivePayment,
    "list_workspace_orders" => ListWorkspaceOrders,
    "refund_order" => RefundOrder,
    "retry_refund" => RetryRefund,
    "update_join_policy" => UpdateJoinPolicy
  }

  defp frame_for(user), do: Frame.new(current_user: user)

  defp decode_reply({:reply, response, _frame}) do
    [content] = response.content
    Jason.decode!(content["text"])
  end

  defp tool_logs_for(user_id, tool_name) do
    ToolCallLog
    |> Ash.Query.filter(user_id == ^user_id and tool == ^tool_name)
    |> Ash.read!(authorize?: false)
  end

  defp pending_status(pending_id) do
    Ash.get!(PendingOperation, pending_id, authorize?: false).status
  end

  defp pending_count do
    PendingOperation |> Ash.read!(authorize?: false) |> length()
  end

  # 草稿课程（不经 EventFixtures 的 force_open——launch 路径需要 draft 起点）
  defp draft_course(workspace, actor, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{title: "S3 Draft Course", registration_deadline: EventFixtures.days_from_now(7)},
        attrs
      )

    Course
    |> Ash.Changeset.for_create(:create, attrs, tenant: workspace.id)
    |> Ash.create!(tenant: workspace.id, actor: actor)
  end

  defp open_course(workspace, actor, attrs \\ %{}),
    do: EventFixtures.create_course(workspace, actor, attrs)

  defp paid_course(workspace, actor),
    do: open_course(workspace, actor, %{pricing_enabled: true, price_tiers: [@tier]})

  defp request_course(workspace, actor),
    do: open_course(workspace, actor, %{enrollment_policy: :request})

  defp enroll(course, learner, attrs \\ %{}) do
    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(
        :create_enrollment,
        Map.merge(%{course_id: course.id, user_id: learner.id}, attrs)
      )
      |> Ash.create(tenant: course.workspace_id, actor: learner)

    enrollment
  end

  # 收费课程报名（open 策略 + tier_id）→ payment_pending；每次调用注册新学员
  defp payment_pending_enrollment(course, prefix) do
    learner = Fixtures.register_user(prefix)
    enrollment = enroll(course, learner, %{tier_id: @tier_id})
    assert enrollment.status == :payment_pending
    {learner, enrollment}
  end

  defp pending_order(workspace, enrollment) do
    {:ok, order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        enrollment_id: enrollment.id,
        provider: :wechat_native,
        out_trade_no: "oto-" <> Ecto.UUID.generate(),
        amount_cents: 19_900,
        tier_snapshot: @tier,
        expire_at: DateTime.add(DateTime.utc_now(), 2, :hour)
      })
      |> Ash.create(tenant: workspace.id, authorize?: false)

    order
  end

  # paid 订单链（refund_test 同款布置）：pending 单 → mark_paid → 报名 settle_paid
  defp paid_order(workspace, enrollment) do
    order = pending_order(workspace, enrollment)

    {:ok, paid} =
      order
      |> Ash.Changeset.for_update(:mark_paid, %{
        transaction_id: "txn-" <> Ecto.UUID.generate()
      })
      |> Ash.update(tenant: workspace.id, authorize?: false)

    {:ok, _} =
      enrollment
      |> Ash.Changeset.for_update(:settle_paid, %{})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    paid
  end

  defp refund_failed_order(workspace, enrollment, actor) do
    paid = paid_order(workspace, enrollment)

    {:ok, refunding} =
      paid
      |> Ash.Changeset.for_update(:refund, %{})
      |> Ash.update(tenant: workspace.id, actor: actor)

    {:ok, failed} =
      refunding
      |> Ash.Changeset.for_update(:mark_refund_failed, %{})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    failed
  end

  defp admin_logs(action, target_id) do
    AdminActionLog
    |> Ash.Query.filter(action == ^action and target_id == ^target_id)
    |> Ash.read!(authorize?: false)
  end

  describe "授权：非 Owner/Admin 对全部 13 工具 forbidden" do
    test "plain member / tutor / learner 撞工具层判定；非成员撞 member 门" do
      owner = Fixtures.platform_admin("s3-authz-owner")
      workspace = Fixtures.create_workspace(owner)

      member = Fixtures.register_user("s3-authz-member")
      Fixtures.add_member(workspace, member, [])

      tutor = Fixtures.register_user("s3-authz-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])

      learner = Fixtures.register_user("s3-authz-learner")
      Fixtures.add_member(workspace, learner, [:learner])

      outsider = Fixtures.register_user("s3-authz-outsider")

      base_params = %{
        "workspace_id" => workspace.id,
        "title" => "X",
        "course_id" => Ecto.UUID.generate(),
        "enrollment_id" => Ecto.UUID.generate(),
        "order_id" => Ecto.UUID.generate(),
        "join_policy" => "open"
      }

      for {tool_name, module} <- @tool_modules do
        params = Map.put(base_params, "workspace_id", workspace.id)

        for {user, expected} <- [
              {member, "owner or admin required"},
              {tutor, "owner or admin required"},
              {learner, "owner or admin required"},
              {outsider, "not a member"}
            ] do
          assert {:error, %Anubis.MCP.Error{message: msg}, _} =
                   apply(module, :execute, [params, frame_for(user)]),
                 "expected #{tool_name} to reject #{user.email}"

          assert msg =~ "forbidden", "expected forbidden for #{tool_name}, got: #{msg}"
          assert msg =~ expected, "expected #{inspect(expected)} for #{tool_name}, got: #{msg}"

          [log] = tool_logs_for(user.id, tool_name)
          assert log.result_status == :forbidden
        end
      end

      # 无任何 pending / 课程副作用
      assert pending_count() == 0
      assert [] = Ash.read!(Course, authorize?: false, tenant: workspace.id)
    end

    test "非 Owner/Admin 调 confirm_operation 无 pending 可确认（他人 pending 不可见）" do
      owner = Fixtures.platform_admin("s3-cf-owner")
      workspace = Fixtures.create_workspace(owner)
      course = draft_course(workspace, owner)
      member = Fixtures.register_user("s3-cf-member")
      Fixtures.add_member(workspace, member, [])

      {:reply, _, _} =
        reply =
        LaunchCourse.execute(
          %{"workspace_id" => workspace.id, "course_id" => course.id},
          frame_for(owner)
        )

      %{"pending_id" => pending_id} = decode_reply(reply)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ConfirmOperation.execute(%{"pending_id" => pending_id}, frame_for(member))

      assert msg =~ "pending operation not found"
      assert Ash.get!(Course, course.id, authorize?: false).status == :draft
    end
  end

  describe "create_course（直接写）" do
    test "Owner 直接创建 draft（标题/定价/可见性落库，slug 缺省生成）" do
      owner = Fixtures.platform_admin("s3-cc-owner")
      workspace = Fixtures.create_workspace(owner)

      assert {:reply, _, _} =
               reply =
               CreateCourse.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "title" => "Elixir 入门",
                   "description" => "从零到一",
                   "visibility" => "workspace",
                   "pricing_enabled" => true,
                   "price_tiers" => [@tier],
                   "capacity" => 30,
                   "registration_deadline" => "2027-01-01T00:00:00Z"
                 },
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["title"] == "Elixir 入门"
      assert payload["status"] == "draft"
      assert payload["pricing_enabled"] == true
      assert payload["visibility"] == "workspace"
      assert payload["slug"] =~ ~r/^c-[0-9a-f]{8}$/

      course = Ash.get!(Course, payload["course_id"], authorize?: false, tenant: workspace.id)
      assert course.status == :draft
      assert course.capacity == 30
      assert [%{"id" => @tier_id}] = course.price_tiers

      [log] = tool_logs_for(owner.id, "create_course")
      assert log.result_status == :ok
      # 直接写：不经 pending
      assert pending_count() == 0
    end

    test "缺 title → 零输入草稿（R21/AE1）：临时占位标题 + provisional_title 标记" do
      owner = Fixtures.platform_admin("s3-cc-notitle")
      workspace = Fixtures.create_workspace(owner)

      assert {:reply, _, _} =
               reply =
               CreateCourse.execute(%{"workspace_id" => workspace.id}, frame_for(owner))

      payload = decode_reply(reply)
      assert payload["title"] =~ ~r/^未命名课程 [0-9a-f]{8}$/
      assert payload["status"] == "draft"

      course = Ash.get!(Course, payload["course_id"], authorize?: false, tenant: workspace.id)
      assert course.provisional_title == true

      # 带 title 创建 → 非占位
      assert {:reply, _, _} =
               titled_reply =
               CreateCourse.execute(
                 %{"workspace_id" => workspace.id, "title" => "正式课程"},
                 frame_for(owner)
               )

      titled =
        Ash.get!(Course, decode_reply(titled_reply)["course_id"],
          authorize?: false,
          tenant: workspace.id
        )

      assert titled.provisional_title == false
    end
  end

  describe "update_course（确认流）" do
    test "两段：摘要列出将变更字段 → 无副作用 → confirm 落库" do
      owner = Fixtures.platform_admin("s3-uc-owner")
      workspace = Fixtures.create_workspace(owner)
      course = open_course(workspace, owner, %{title: "旧标题"})

      assert {:reply, _, _} =
               reply =
               UpdateCourse.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "course_id" => course.id,
                   "title" => "新标题",
                   "capacity" => 10
                 },
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"
      assert payload["summary"] =~ "title"
      assert payload["summary"] =~ "新标题"
      assert payload["summary"] =~ "capacity"
      assert payload["summary"] =~ "10"

      # 无副作用
      assert Ash.get!(Course, course.id, authorize?: false).title == "旧标题"

      [log] = tool_logs_for(owner.id, "update_course")
      assert log.result_status == :needs_confirmation

      assert {:reply, _, _} =
               confirm_reply =
               ConfirmOperation.execute(
                 %{"pending_id" => payload["pending_id"]},
                 frame_for(owner)
               )

      confirmed = decode_reply(confirm_reply)
      assert confirmed["status"] == "confirmed"
      assert confirmed["result"]["course_id"] == course.id
      assert Enum.sort(confirmed["result"]["updated_fields"]) == ["capacity", "title"]

      updated = Ash.get!(Course, course.id, authorize?: false)
      assert updated.title == "新标题"
      assert updated.capacity == 10
    end

    test "pricing_enabled true→false：摘要含批量免缴影响（笔数），confirm 后待支付报名免缴（R9/KTD4）" do
      owner = Fixtures.platform_admin("s3-uc-pricing")
      workspace = Fixtures.create_workspace(owner)
      course = paid_course(workspace, owner)
      {_l1, enrollment1} = payment_pending_enrollment(course, "s3-uc-p1")
      {_l2, enrollment2} = payment_pending_enrollment(course, "s3-uc-p2")

      {:reply, _, _} =
        reply =
        UpdateCourse.execute(
          %{
            "workspace_id" => workspace.id,
            "course_id" => course.id,
            "pricing_enabled" => false
          },
          frame_for(owner)
        )

      payload = decode_reply(reply)

      # 影响摘要：pricing_enabled true→false 必须展示将触发的批量免缴影响（含笔数）
      assert payload["summary"] =~ "pricing_enabled"
      assert payload["summary"] =~ "批量免缴"
      assert payload["summary"] =~ "2 笔"

      {:reply, _, _} =
        ConfirmOperation.execute(%{"pending_id" => payload["pending_id"]}, frame_for(owner))

      assert Ash.get!(Course, course.id, authorize?: false).pricing_enabled == false
      assert Ash.get!(Enrollment, enrollment1.id, authorize?: false).status == :confirmed
      assert Ash.get!(Enrollment, enrollment2.id, authorize?: false).status == :confirmed

      # 批量免缴与单笔 waive_payment 同语义：审计行不可省（逐笔一行）
      assert [%{action: :waive_payment, target_type: :enrollment}] =
               admin_logs(:waive_payment, enrollment1.id)

      assert [%{action: :waive_payment, target_type: :enrollment}] =
               admin_logs(:waive_payment, enrollment2.id)
    end

    test "非定价变更不附带批量免缴影响摘要" do
      owner = Fixtures.platform_admin("s3-uc-no-waive")
      workspace = Fixtures.create_workspace(owner)
      course = paid_course(workspace, owner)

      {:reply, _, _} =
        reply =
        UpdateCourse.execute(
          %{"workspace_id" => workspace.id, "course_id" => course.id, "capacity" => 50},
          frame_for(owner)
        )

      refute decode_reply(reply)["summary"] =~ "批量免缴"
    end

    test "cancel 路径：pending 取消后课程不变" do
      owner = Fixtures.platform_admin("s3-uc-cancel")
      workspace = Fixtures.create_workspace(owner)
      course = open_course(workspace, owner, %{title: "原标题"})

      {:reply, _, _} =
        reply =
        UpdateCourse.execute(
          %{"workspace_id" => workspace.id, "course_id" => course.id, "title" => "改掉"},
          frame_for(owner)
        )

      %{"pending_id" => pending_id} = decode_reply(reply)

      assert {:reply, _, _} =
               cancel_reply =
               CancelOperation.execute(%{"pending_id" => pending_id}, frame_for(owner))

      assert decode_reply(cancel_reply)["status"] == "cancelled"
      assert pending_status(pending_id) == :cancelled
      assert Ash.get!(Course, course.id, authorize?: false).title == "原标题"
    end

    test "无可更新字段 → 报错不建 pending" do
      owner = Fixtures.platform_admin("s3-uc-none")
      workspace = Fixtures.create_workspace(owner)
      course = open_course(workspace, owner)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               UpdateCourse.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(owner)
               )

      assert msg =~ "no updatable fields"
      assert pending_count() == 0
    end

    test "跨租户：他工作台 course_id ≡ not found（不泄露存在性）" do
      owner_a = Fixtures.platform_admin("s3-uc-owner-a")
      workspace_a = Fixtures.create_workspace(owner_a)
      owner_b = Fixtures.platform_admin("s3-uc-owner-b")
      workspace_b = Fixtures.create_workspace(owner_b)
      course_b = open_course(workspace_b, owner_b)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               UpdateCourse.execute(
                 %{
                   "workspace_id" => workspace_a.id,
                   "course_id" => course_b.id,
                   "title" => "越租户改写"
                 },
                 frame_for(owner_a)
               )

      assert msg =~ "course not found"
      assert pending_count() == 0
      assert Ash.get!(Course, course_b.id, authorize?: false).title == "Test Course"
    end
  end

  describe "launch/close/cancel（确认流）" do
    test "launch：draft → open（两段；第一段仍 draft）" do
      owner = Fixtures.platform_admin("s3-launch-owner")
      workspace = Fixtures.create_workspace(owner)
      course = draft_course(workspace, owner)

      assert {:reply, _, _} =
               reply =
               LaunchCourse.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"
      assert payload["summary"] =~ course.id
      assert payload["summary"] =~ "draft → open"

      assert Ash.get!(Course, course.id, authorize?: false).status == :draft

      assert {:reply, _, _} =
               confirm_reply =
               ConfirmOperation.execute(
                 %{"pending_id" => payload["pending_id"]},
                 frame_for(owner)
               )

      confirmed = decode_reply(confirm_reply)
      assert confirmed["result"]["status"] == "open"
      assert Ash.get!(Course, course.id, authorize?: false).status == :open
    end

    test "命名门：provisional_title 课程 launch 第一段快速失败（不建 pending）" do
      owner = Fixtures.platform_admin("s3-launch-prov")
      workspace = Fixtures.create_workspace(owner)

      {:reply, _, _} =
        create_reply = CreateCourse.execute(%{"workspace_id" => workspace.id}, frame_for(owner))

      course_id = decode_reply(create_reply)["course_id"]

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               LaunchCourse.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course_id},
                 frame_for(owner)
               )

      assert msg =~ "尚未命名"
      assert pending_count() == 0
      assert Ash.get!(Course, course_id, authorize?: false).status == :draft
    end

    test "命名门：域 action 层同款拦截（GraphQL/直调同语义）；补名后可发布" do
      owner = Fixtures.platform_admin("s3-launch-gate")
      workspace = Fixtures.create_workspace(owner)

      {:reply, _, _} =
        create_reply = CreateCourse.execute(%{"workspace_id" => workspace.id}, frame_for(owner))

      course_id = decode_reply(create_reply)["course_id"]
      course = Ash.get!(Course, course_id, authorize?: false, tenant: workspace.id)
      assert course.provisional_title == true

      # 域层命名门（不经 MCP 工具）：provisional_title 课程 launch 被拒
      assert {:error, %Ash.Error.Invalid{} = err} =
               course
               |> Ash.Changeset.for_update(:launch, %{}, tenant: workspace.id)
               |> Ash.update(actor: owner, tenant: workspace.id)

      assert Exception.message(err) =~ "尚未命名"
      assert Ash.get!(Course, course_id, authorize?: false).status == :draft

      # 设置正式标题 → provisional_title 清除 → 可发布
      {:ok, named} =
        course
        |> Ash.Changeset.for_update(:update, %{title: "正式课程名"}, tenant: workspace.id)
        |> Ash.update(actor: owner, tenant: workspace.id)

      assert named.provisional_title == false

      assert {:ok, launched} =
               named
               |> Ash.Changeset.for_update(:launch, %{}, tenant: workspace.id)
               |> Ash.update(actor: owner, tenant: workspace.id)

      assert launched.status == :open
    end

    test "close：open → closed；cancel：open → cancelled（终态不可逆提示）" do
      owner = Fixtures.platform_admin("s3-cc-lc-owner")
      workspace = Fixtures.create_workspace(owner)
      course = open_course(workspace, owner)

      for {module, tool, expected} <- [
            {CloseCourse, "close_course", "closed"},
            {CancelCourse, "cancel_course", "cancelled"}
          ] do
        {:reply, _, _} =
          reply =
          apply(module, :execute, [
            %{"workspace_id" => workspace.id, "course_id" => course.id},
            frame_for(owner)
          ])

        payload = decode_reply(reply)
        assert payload["status"] == "needs_confirmation"
        assert payload["summary"] =~ "终态不可逆"
        assert Ash.get!(Course, course.id, authorize?: false).status == :open

        {:reply, _, _} =
          ConfirmOperation.execute(%{"pending_id" => payload["pending_id"]}, frame_for(owner))

        assert Ash.get!(Course, course.id, authorize?: false).status ==
                 String.to_existing_atom(expected)

        # 回到 open 供下一段（布置而非被测对象）
        {:ok, _} =
          Cgc2046.Repo.query("UPDATE courses SET status = 'open' WHERE id = $1", [
            Ecto.UUID.dump!(course.id)
          ])

        [log] = tool_logs_for(owner.id, tool)
        assert log.result_status == :needs_confirmation
      end
    end

    test "错误路径：launch 已 open 课程 → 报错不建 pending" do
      owner = Fixtures.platform_admin("s3-launch-open")
      workspace = Fixtures.create_workspace(owner)
      course = open_course(workspace, owner)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               LaunchCourse.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(owner)
               )

      assert msg =~ "cannot launch from status=open"
      assert pending_count() == 0
    end
  end

  describe "list_course_enrollments（读）" do
    test "Owner 见本课程报名（报名人摘要/状态/档位），status 过滤生效" do
      owner = Fixtures.platform_admin("s3-lce-owner")
      workspace = Fixtures.create_workspace(owner)
      course = paid_course(workspace, owner)
      {learner, enrollment} = payment_pending_enrollment(course, "s3-lce-paid")

      free_learner = Fixtures.register_user("s3-lce-free")
      free_enrollment = enroll(open_course(workspace, owner), free_learner)

      assert {:reply, _, _} =
               reply =
               ListCourseEnrollments.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["count"] == 1

      [row] = payload["enrollments"]
      assert row["enrollment_id"] == enrollment.id
      assert row["status"] == "payment_pending"
      assert row["user"]["id"] == learner.id
      assert row["user"]["email"] == to_string(learner.email)
      assert row["tier"]["id"] == @tier_id
      assert row["tier"]["amount_cents"] == 19_900

      # 免费课程的 confirmed 报名不在本课程列表；status 过滤收窄
      assert {:reply, _, _} =
               filtered =
               ListCourseEnrollments.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "course_id" => free_enrollment.course_id,
                   "status" => "confirmed"
                 },
                 frame_for(owner)
               )

      assert decode_reply(filtered)["count"] == 1
    end

    test "跨租户隔离：他工作台课程/报名不漏；他工作台 course_id = not found" do
      owner_a = Fixtures.platform_admin("s3-lce-owner-a")
      workspace_a = Fixtures.create_workspace(owner_a)
      course_a = open_course(workspace_a, owner_a)
      learner_a = Fixtures.register_user("s3-lce-learner-a")
      enrollment_a = enroll(course_a, learner_a)

      owner_b = Fixtures.platform_admin("s3-lce-owner-b")
      workspace_b = Fixtures.create_workspace(owner_b)
      course_b = open_course(workspace_b, owner_b)
      learner_b = Fixtures.register_user("s3-lce-learner-b")
      enrollment_b = enroll(course_b, learner_b)

      {:reply, _, _} =
        reply =
        ListCourseEnrollments.execute(
          %{"workspace_id" => workspace_a.id, "course_id" => course_a.id},
          frame_for(owner_a)
        )

      payload = decode_reply(reply)
      assert payload["count"] == 1
      ids = Enum.map(payload["enrollments"], & &1["enrollment_id"])
      assert ids == [enrollment_a.id]
      refute enrollment_b.id in ids

      # workspace_a 上下文 + workspace_b 的 course_id → not found（不泄存在性）
      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ListCourseEnrollments.execute(
                 %{"workspace_id" => workspace_a.id, "course_id" => course_b.id},
                 frame_for(owner_a)
               )

      assert msg =~ "course not found"
    end
  end

  describe "confirm/reject/waive（确认流）" do
    test "confirm_enrollment：request 课程 pending → confirmed 占位（两段）" do
      owner = Fixtures.platform_admin("s3-ce-owner")
      workspace = Fixtures.create_workspace(owner)
      course = request_course(workspace, owner)
      learner = Fixtures.register_user("s3-ce-learner")
      enrollment = enroll(course, learner)
      assert enrollment.status == :pending

      assert {:reply, _, _} =
               reply =
               ConfirmEnrollment.execute(
                 %{"workspace_id" => workspace.id, "enrollment_id" => enrollment.id},
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"
      assert payload["summary"] =~ enrollment.id
      assert payload["summary"] =~ learner.id
      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :pending

      assert {:reply, _, _} =
               confirm_reply =
               ConfirmOperation.execute(
                 %{"pending_id" => payload["pending_id"]},
                 frame_for(owner)
               )

      confirmed = decode_reply(confirm_reply)
      assert confirmed["status"] == "confirmed"
      assert confirmed["result"]["enrollment_id"] == enrollment.id
      assert confirmed["result"]["status"] == "confirmed"

      reloaded = Ash.get!(Enrollment, enrollment.id, authorize?: false)
      assert reloaded.status == :confirmed
      assert reloaded.approved_by == owner.id
    end

    test "confirm_enrollment 收费课程：审批通过落 payment_pending（KTD6-3）" do
      owner = Fixtures.platform_admin("s3-ce-paid")
      workspace = Fixtures.create_workspace(owner)

      course =
        open_course(workspace, owner, %{
          enrollment_policy: :request,
          pricing_enabled: true,
          price_tiers: [@tier]
        })

      learner = Fixtures.register_user("s3-ce-paid-learner")
      enrollment = enroll(course, learner, %{tier_id: @tier_id})
      assert enrollment.status == :pending

      {:reply, _, _} =
        reply =
        ConfirmEnrollment.execute(
          %{"workspace_id" => workspace.id, "enrollment_id" => enrollment.id},
          frame_for(owner)
        )

      {:reply, _, _} =
        confirm_reply =
        ConfirmOperation.execute(
          %{"pending_id" => decode_reply(reply)["pending_id"]},
          frame_for(owner)
        )

      assert decode_reply(confirm_reply)["result"]["status"] == "payment_pending"
    end

    test "reject_enrollment：带原因拒绝（两段，原因落库）" do
      owner = Fixtures.platform_admin("s3-rej-owner")
      workspace = Fixtures.create_workspace(owner)
      course = request_course(workspace, owner)
      learner = Fixtures.register_user("s3-rej-learner")
      enrollment = enroll(course, learner)

      {:reply, _, _} =
        reply =
        RejectEnrollment.execute(
          %{
            "workspace_id" => workspace.id,
            "enrollment_id" => enrollment.id,
            "rejection_reason" => "名额已满"
          },
          frame_for(owner)
        )

      payload = decode_reply(reply)
      assert payload["summary"] =~ "名额已满"
      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :pending

      {:reply, _, _} =
        confirm_reply =
        ConfirmOperation.execute(%{"pending_id" => payload["pending_id"]}, frame_for(owner))

      confirmed = decode_reply(confirm_reply)
      assert confirmed["result"]["status"] == "rejected"

      reloaded = Ash.get!(Enrollment, enrollment.id, authorize?: false)
      assert reloaded.status == :rejected
      assert reloaded.rejection_reason == "名额已满"
    end

    test "waive_payment：payment_pending → confirmed + 关联 pending 单作废 + 审计行" do
      owner = Fixtures.platform_admin("s3-waive-owner")
      workspace = Fixtures.create_workspace(owner)
      course = paid_course(workspace, owner)
      {_learner, enrollment} = payment_pending_enrollment(course, "s3-waive-learner")
      order = pending_order(workspace, enrollment)

      assert {:reply, _, _} =
               reply =
               WaivePayment.execute(
                 %{"workspace_id" => workspace.id, "enrollment_id" => enrollment.id},
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["summary"] =~ "免缴"
      assert payload["summary"] =~ "审计"
      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :payment_pending

      assert {:reply, _, _} =
               confirm_reply =
               ConfirmOperation.execute(
                 %{"pending_id" => payload["pending_id"]},
                 frame_for(owner)
               )

      confirmed = decode_reply(confirm_reply)
      assert confirmed["result"]["status"] == "confirmed"
      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :confirmed

      # 关联 pending 订单同事务作废（e2e #1 语义）
      assert Ash.get!(Order, order.id, authorize?: false, tenant: workspace.id).status ==
               :cancelled

      # 免缴审计留痕（LogAdminAction）
      assert [%{action: :waive_payment, target_type: :enrollment, actor_id: owner_id}] =
               admin_logs(:waive_payment, enrollment.id)

      assert owner_id == owner.id
    end

    test "错误路径：waive 非 payment_pending 报名 → 报错不建 pending" do
      owner = Fixtures.platform_admin("s3-waive-confirmed")
      workspace = Fixtures.create_workspace(owner)
      course = open_course(workspace, owner)
      learner = Fixtures.register_user("s3-waive-learner")
      enrollment = enroll(course, learner)
      assert enrollment.status == :confirmed

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               WaivePayment.execute(
                 %{"workspace_id" => workspace.id, "enrollment_id" => enrollment.id},
                 frame_for(owner)
               )

      assert msg =~ "不在待支付状态"
      assert pending_count() == 0
    end
  end

  describe "list_workspace_orders（读）" do
    test "Owner 见本工作台订单（金额/渠道/状态/报名人），course_id 过滤收窄" do
      owner = Fixtures.platform_admin("s3-lwo-owner")
      workspace = Fixtures.create_workspace(owner)
      course = paid_course(workspace, owner)
      {learner, enrollment} = payment_pending_enrollment(course, "s3-lwo-learner")
      order = pending_order(workspace, enrollment)

      other_course = paid_course(workspace, owner)

      {_other_learner, other_enrollment} =
        payment_pending_enrollment(other_course, "s3-lwo-other")

      _other_order = pending_order(workspace, other_enrollment)

      assert {:reply, _, _} =
               reply =
               ListWorkspaceOrders.execute(%{"workspace_id" => workspace.id}, frame_for(owner))

      payload = decode_reply(reply)
      assert payload["count"] == 2

      row = Enum.find(payload["orders"], &(&1["order_id"] == order.id))
      assert row["amount_cents"] == 19_900
      assert row["provider"] == "wechat_native"
      assert row["status"] == "pending"
      assert row["enrollment"]["enrollment_id"] == enrollment.id
      assert row["enrollment"]["learner_email"] == to_string(learner.email)
      assert row["offering"]["course_id"] == course.id
      assert row["tier_name"] == "标准"

      assert {:reply, _, _} =
               filtered =
               ListWorkspaceOrders.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(owner)
               )

      filtered_payload = decode_reply(filtered)
      assert filtered_payload["count"] == 1
      assert hd(filtered_payload["orders"])["order_id"] == order.id
    end

    test "跨租户隔离：他工作台订单不回；course_id 指向他工作台课程 → 0 行" do
      owner_a = Fixtures.platform_admin("s3-lwo-owner-a")
      workspace_a = Fixtures.create_workspace(owner_a)
      course_a = paid_course(workspace_a, owner_a)
      {_learner_a, enrollment_a} = payment_pending_enrollment(course_a, "s3-lwo-a")
      order_a = pending_order(workspace_a, enrollment_a)

      owner_b = Fixtures.platform_admin("s3-lwo-owner-b")
      workspace_b = Fixtures.create_workspace(owner_b)
      course_b = paid_course(workspace_b, owner_b)
      {_learner_b, enrollment_b} = payment_pending_enrollment(course_b, "s3-lwo-b")
      order_b = pending_order(workspace_b, enrollment_b)

      {:reply, _, _} =
        reply =
        ListWorkspaceOrders.execute(%{"workspace_id" => workspace_a.id}, frame_for(owner_a))

      payload = decode_reply(reply)
      ids = Enum.map(payload["orders"], & &1["order_id"])
      assert order_a.id in ids
      refute order_b.id in ids

      {:reply, _, _} =
        filtered =
        ListWorkspaceOrders.execute(
          %{"workspace_id" => workspace_a.id, "course_id" => course_b.id},
          frame_for(owner_a)
        )

      assert decode_reply(filtered)["count"] == 0
    end
  end

  describe "refund_order / retry_refund（确认流）" do
    test "refund：paid → refunding + 渠道退款 job 入队 + 审计行（两段）" do
      owner = Fixtures.platform_admin("s3-refund-owner")
      workspace = Fixtures.create_workspace(owner)
      course = paid_course(workspace, owner)
      {_learner, enrollment} = payment_pending_enrollment(course, "s3-refund-learner")
      order = paid_order(workspace, enrollment)

      assert {:reply, _, _} =
               reply =
               RefundOrder.execute(
                 %{"workspace_id" => workspace.id, "order_id" => order.id},
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"
      assert payload["summary"] =~ "退款即取消报名并释放名额"
      assert payload["summary"] =~ "19900"

      # 无副作用
      assert Ash.get!(Order, order.id, authorize?: false, tenant: workspace.id).status == :paid

      assert {:reply, _, _} =
               confirm_reply =
               ConfirmOperation.execute(
                 %{"pending_id" => payload["pending_id"]},
                 frame_for(owner)
               )

      confirmed = decode_reply(confirm_reply)
      assert confirmed["result"]["order_id"] == order.id
      assert confirmed["result"]["status"] == "refunding"

      assert Ash.get!(Order, order.id, authorize?: false, tenant: workspace.id).status ==
               :refunding

      assert_enqueued(worker: PaymentRefundWorker, args: %{"order_id" => order.id})

      assert [%{action: :order_refund, target_type: :order, actor_id: owner_id}] =
               admin_logs(:order_refund, order.id)

      assert owner_id == owner.id
    end

    test "cancel 路径：pending 取消后订单仍 paid，无退款副作用" do
      owner = Fixtures.platform_admin("s3-refund-cancel")
      workspace = Fixtures.create_workspace(owner)
      course = paid_course(workspace, owner)
      {_learner, enrollment} = payment_pending_enrollment(course, "s3-refund-cancel-learner")
      order = paid_order(workspace, enrollment)

      {:reply, _, _} =
        reply =
        RefundOrder.execute(
          %{"workspace_id" => workspace.id, "order_id" => order.id},
          frame_for(owner)
        )

      %{"pending_id" => pending_id} = decode_reply(reply)

      {:reply, _, _} =
        CancelOperation.execute(%{"pending_id" => pending_id}, frame_for(owner))

      assert pending_status(pending_id) == :cancelled
      assert Ash.get!(Order, order.id, authorize?: false, tenant: workspace.id).status == :paid
      assert [] = admin_logs(:order_refund, order.id)
      refute_enqueued(worker: PaymentRefundWorker, args: %{"order_id" => order.id})
    end

    test "retry_refund：refund_failed → refunding 重入 + 审计行" do
      owner = Fixtures.platform_admin("s3-retry-owner")
      workspace = Fixtures.create_workspace(owner)
      course = paid_course(workspace, owner)
      {_learner, enrollment} = payment_pending_enrollment(course, "s3-retry-learner")
      order = refund_failed_order(workspace, enrollment, owner)

      assert {:reply, _, _} =
               reply =
               RetryRefund.execute(
                 %{"workspace_id" => workspace.id, "order_id" => order.id},
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["summary"] =~ "refund_failed → refunding"

      assert {:reply, _, _} =
               confirm_reply =
               ConfirmOperation.execute(
                 %{"pending_id" => payload["pending_id"]},
                 frame_for(owner)
               )

      assert decode_reply(confirm_reply)["result"]["status"] == "refunding"

      assert Ash.get!(Order, order.id, authorize?: false, tenant: workspace.id).status ==
               :refunding

      assert [%{action: :order_refund_retry, target_type: :order}] =
               admin_logs(:order_refund_retry, order.id)
    end

    test "错误路径：refund 非 paid 订单 → 报错不建 pending" do
      owner = Fixtures.platform_admin("s3-refund-pending")
      workspace = Fixtures.create_workspace(owner)
      course = paid_course(workspace, owner)
      {_learner, enrollment} = payment_pending_enrollment(course, "s3-refund-pending-learner")
      order = pending_order(workspace, enrollment)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               RefundOrder.execute(
                 %{"workspace_id" => workspace.id, "order_id" => order.id},
                 frame_for(owner)
               )

      assert msg =~ "仅 paid 订单可退款"
      assert pending_count() == 0
    end
  end

  describe "update_join_policy（确认流）" do
    test "两段：摘要展示 旧 → 新 → 无副作用 → confirm 落库" do
      owner = Fixtures.platform_admin("s3-jp-owner")
      workspace = Fixtures.create_workspace(owner)
      assert workspace.join_policy == :request

      assert {:reply, _, _} =
               reply =
               UpdateJoinPolicy.execute(
                 %{"workspace_id" => workspace.id, "join_policy" => "invite_only"},
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"
      assert payload["summary"] =~ "request"
      assert payload["summary"] =~ "invite_only"
      assert Ash.get!(Workspace, workspace.id, authorize?: false).join_policy == :request

      assert {:reply, _, _} =
               confirm_reply =
               ConfirmOperation.execute(
                 %{"pending_id" => payload["pending_id"]},
                 frame_for(owner)
               )

      confirmed = decode_reply(confirm_reply)
      assert confirmed["result"]["workspace_id"] == workspace.id
      assert confirmed["result"]["join_policy"] == "invite_only"
      assert Ash.get!(Workspace, workspace.id, authorize?: false).join_policy == :invite_only
    end

    test "非法 join_policy → 报错不建 pending" do
      owner = Fixtures.platform_admin("s3-jp-invalid")
      workspace = Fixtures.create_workspace(owner)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               UpdateJoinPolicy.execute(
                 %{"workspace_id" => workspace.id, "join_policy" => "bogus"},
                 frame_for(owner)
               )

      assert msg =~ "invalid join_policy"
      assert pending_count() == 0
    end
  end
end
