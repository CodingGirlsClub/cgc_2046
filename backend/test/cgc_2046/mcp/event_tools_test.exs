defmodule Cgc2046.Mcp.EventToolsTest do
  @moduledoc """
  活动管理工具面测试（role-agent-journeys-v2 S3 event 六件 + list_enrollments
  kind=event 分派；直接调 tool execute/2，不走 HTTP；workspace_admin_tools_test
  同款模式）。

  - 授权：plain member / tutor / learner / 非成员对活动五件写工具一律 forbidden
    （非成员撞 Wrapper member 门；成员撞工具层 Owner/Admin 判定）；
    list_workspace_events 为 member-only 发现面（成员可读全部状态含 draft）
  - create_event 直接写生成 draft（venue/pricing 落库，slug 缺省生成 e-<hex>），
    不经 pending
  - update/launch/close/cancel 确认流两段式；close/cancel 摘要含终态不可逆提示
  - update_event pricing_enabled true→false 摘要含批量免缴影响（R9/KTD4）
  - list_enrollments kind=event 分派：活动报名行 + 跨 kind 隔离 + 非法 kind 报错
  - confirm_enrollment 成功投影补 event_id（课程字段为 nil 原样返回）
  - 跨租户：他工作台 event_id / offering_id ≡ not found（不泄露存在性）
  """
  use Cgc2046.DataCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Events.Event
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Mcp.{PendingOperation, ToolCallLog}

  alias Cgc2046.Mcp.Tools.{
    CancelEvent,
    CloseEvent,
    ConfirmEnrollment,
    ConfirmOperation,
    CreateEvent,
    LaunchEvent,
    ListEnrollments,
    ListWorkspaceEvents,
    UpdateEvent
  }

  require Ash.Query

  @tier_id "88888888-8888-8888-8888-888888888888"
  @tier %{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900}

  @venue %{"country" => "中国", "province" => "浙江省", "city" => "杭州市", "district" => "西湖区"}

  # 活动五件写工具（list_workspace_events 为 member-only 发现面，不在此列）
  @event_write_tools %{
    "create_event" => CreateEvent,
    "update_event" => UpdateEvent,
    "launch_event" => LaunchEvent,
    "close_event" => CloseEvent,
    "cancel_event" => CancelEvent
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

  defp pending_count do
    PendingOperation |> Ash.read!(authorize?: false) |> length()
  end

  # 草稿活动（不经 EventFixtures 的 force_open——launch 路径需要 draft 起点）
  defp draft_event(workspace, actor, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{title: "S3 Draft Event", registration_deadline: EventFixtures.days_from_now(7)},
        attrs
      )

    Event
    |> Ash.Changeset.for_create(:create, attrs, tenant: workspace.id)
    |> Ash.create!(tenant: workspace.id, actor: actor)
  end

  defp open_event(workspace, actor, attrs \\ %{}),
    do: EventFixtures.create_event(workspace, actor, attrs)

  defp paid_event(workspace, actor),
    do: open_event(workspace, actor, %{pricing_enabled: true, price_tiers: [@tier]})

  defp enroll(event, learner, attrs \\ %{}) do
    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(
        :create_enrollment,
        Map.merge(%{event_id: event.id, user_id: learner.id}, attrs)
      )
      |> Ash.create(tenant: event.workspace_id, actor: learner)

    enrollment
  end

  # 收费活动报名（open 策略 + tier_id）→ payment_pending；每次调用注册新学员
  defp payment_pending_enrollment(event, prefix) do
    learner = Fixtures.register_user(prefix)
    enrollment = enroll(event, learner, %{tier_id: @tier_id})
    assert enrollment.status == :payment_pending
    {learner, enrollment}
  end

  describe "授权：非 Owner/Admin 对活动五件写工具 forbidden" do
    test "plain member / tutor / learner 撞工具层判定；非成员撞 member 门" do
      owner = Fixtures.platform_admin("s3-ev-authz-owner")
      workspace = Fixtures.create_workspace(owner)

      member = Fixtures.register_user("s3-ev-authz-member")
      Fixtures.add_member(workspace, member, [])

      tutor = Fixtures.register_user("s3-ev-authz-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])

      learner = Fixtures.register_user("s3-ev-authz-learner")
      Fixtures.add_member(workspace, learner, [:learner])

      outsider = Fixtures.register_user("s3-ev-authz-outsider")

      base_params = %{
        "workspace_id" => workspace.id,
        "title" => "X",
        "event_id" => Ecto.UUID.generate()
      }

      for {tool_name, module} <- @event_write_tools do
        for {user, expected} <- [
              {member, "owner or admin required"},
              {tutor, "owner or admin required"},
              {learner, "owner or admin required"},
              {outsider, "not a member"}
            ] do
          assert {:error, %Anubis.MCP.Error{message: msg}, _} =
                   apply(module, :execute, [base_params, frame_for(user)]),
                 "expected #{tool_name} to reject #{user.email}"

          assert msg =~ "forbidden", "expected forbidden for #{tool_name}, got: #{msg}"
          assert msg =~ expected, "expected #{inspect(expected)} for #{tool_name}, got: #{msg}"

          [log] = tool_logs_for(user.id, tool_name)
          assert log.result_status == :forbidden
        end
      end

      # 无任何 pending / 活动副作用
      assert pending_count() == 0
      assert [] = Ash.read!(Event, authorize?: false, tenant: workspace.id)
    end
  end

  describe "create_event（直接写）" do
    test "Owner 直接创建 draft（venue/赞助/定价落库，slug 缺省生成）" do
      owner = Fixtures.platform_admin("s3-ev-cc-owner")
      workspace = Fixtures.create_workspace(owner)

      assert {:reply, _, _} =
               reply =
               CreateEvent.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "title" => "杭州站见面会",
                   "description" => "线下交流",
                   "venue" => @venue,
                   "visibility" => "workspace",
                   "pricing_enabled" => true,
                   "price_tiers" => [@tier],
                   "capacity" => 50,
                   "starts_at" => "2027-01-10T10:00:00Z",
                   "ends_at" => "2027-01-10T12:00:00Z",
                   "registration_deadline" => "2027-01-01T00:00:00Z"
                 },
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["title"] == "杭州站见面会"
      assert payload["status"] == "draft"
      assert payload["pricing_enabled"] == true
      assert payload["visibility"] == "workspace"
      assert payload["slug"] =~ ~r/^e-[0-9a-f]{8}$/

      event = Ash.get!(Event, payload["event_id"], authorize?: false, tenant: workspace.id)
      assert event.status == :draft
      assert event.capacity == 50
      assert event.venue == @venue
      assert [%{"id" => @tier_id}] = event.price_tiers

      [log] = tool_logs_for(owner.id, "create_event")
      assert log.result_status == :ok
      # 直接写：不经 pending
      assert pending_count() == 0
    end
  end

  describe "update_event（确认流）" do
    test "两段：摘要列出将变更字段 → 无副作用 → confirm 落库" do
      owner = Fixtures.platform_admin("s3-ev-uc-owner")
      workspace = Fixtures.create_workspace(owner)
      event = open_event(workspace, owner, %{title: "旧标题"})

      assert {:reply, _, _} =
               reply =
               UpdateEvent.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "event_id" => event.id,
                   "title" => "新标题",
                   "venue" => @venue
                 },
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"
      assert payload["summary"] =~ "title"
      assert payload["summary"] =~ "新标题"
      assert payload["summary"] =~ "venue"

      # 无副作用
      assert Ash.get!(Event, event.id, authorize?: false).title == "旧标题"

      [log] = tool_logs_for(owner.id, "update_event")
      assert log.result_status == :needs_confirmation

      assert {:reply, _, _} =
               confirm_reply =
               ConfirmOperation.execute(
                 %{"pending_id" => payload["pending_id"]},
                 frame_for(owner)
               )

      confirmed = decode_reply(confirm_reply)
      assert confirmed["status"] == "confirmed"
      assert confirmed["result"]["event_id"] == event.id
      assert Enum.sort(confirmed["result"]["updated_fields"]) == ["title", "venue"]

      updated = Ash.get!(Event, event.id, authorize?: false)
      assert updated.title == "新标题"
      assert updated.venue == @venue
    end

    test "pricing_enabled true→false：摘要含批量免缴影响（笔数），confirm 后待支付报名免缴（R9/KTD4）" do
      owner = Fixtures.platform_admin("s3-ev-uc-pricing")
      workspace = Fixtures.create_workspace(owner)
      event = paid_event(workspace, owner)
      {_l1, enrollment1} = payment_pending_enrollment(event, "s3-ev-uc-p1")
      {_l2, enrollment2} = payment_pending_enrollment(event, "s3-ev-uc-p2")

      {:reply, _, _} =
        reply =
        UpdateEvent.execute(
          %{
            "workspace_id" => workspace.id,
            "event_id" => event.id,
            "pricing_enabled" => false
          },
          frame_for(owner)
        )

      payload = decode_reply(reply)
      assert payload["summary"] =~ "pricing_enabled"
      assert payload["summary"] =~ "批量免缴"
      assert payload["summary"] =~ "2 笔"

      {:reply, _, _} =
        ConfirmOperation.execute(%{"pending_id" => payload["pending_id"]}, frame_for(owner))

      assert Ash.get!(Event, event.id, authorize?: false).pricing_enabled == false
      assert Ash.get!(Enrollment, enrollment1.id, authorize?: false).status == :confirmed
      assert Ash.get!(Enrollment, enrollment2.id, authorize?: false).status == :confirmed
    end

    test "无可更新字段 → 报错不建 pending" do
      owner = Fixtures.platform_admin("s3-ev-uc-none")
      workspace = Fixtures.create_workspace(owner)
      event = open_event(workspace, owner)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               UpdateEvent.execute(
                 %{"workspace_id" => workspace.id, "event_id" => event.id},
                 frame_for(owner)
               )

      assert msg =~ "no updatable fields"
      assert pending_count() == 0
    end

    test "跨租户：他工作台 event_id ≡ not found（不泄露存在性）" do
      owner_a = Fixtures.platform_admin("s3-ev-uc-owner-a")
      workspace_a = Fixtures.create_workspace(owner_a)
      owner_b = Fixtures.platform_admin("s3-ev-uc-owner-b")
      workspace_b = Fixtures.create_workspace(owner_b)
      event_b = open_event(workspace_b, owner_b)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               UpdateEvent.execute(
                 %{
                   "workspace_id" => workspace_a.id,
                   "event_id" => event_b.id,
                   "title" => "越租户改写"
                 },
                 frame_for(owner_a)
               )

      assert msg =~ "event not found"
      assert pending_count() == 0
      assert Ash.get!(Event, event_b.id, authorize?: false).title == "Test Event"
    end
  end

  describe "launch/close/cancel（确认流）" do
    test "launch：draft → open（两段；第一段仍 draft）" do
      owner = Fixtures.platform_admin("s3-ev-launch-owner")
      workspace = Fixtures.create_workspace(owner)
      event = draft_event(workspace, owner)

      assert {:reply, _, _} =
               reply =
               LaunchEvent.execute(
                 %{"workspace_id" => workspace.id, "event_id" => event.id},
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"
      assert payload["summary"] =~ event.id
      assert payload["summary"] =~ "draft → open"

      assert Ash.get!(Event, event.id, authorize?: false).status == :draft

      assert {:reply, _, _} =
               confirm_reply =
               ConfirmOperation.execute(
                 %{"pending_id" => payload["pending_id"]},
                 frame_for(owner)
               )

      confirmed = decode_reply(confirm_reply)
      assert confirmed["result"]["status"] == "open"
      assert Ash.get!(Event, event.id, authorize?: false).status == :open
    end

    test "close：open → closed；cancel：open → cancelled（摘要含终态不可逆提示）" do
      owner = Fixtures.platform_admin("s3-ev-cc-lc-owner")
      workspace = Fixtures.create_workspace(owner)
      event = open_event(workspace, owner)

      for {module, tool, expected} <- [
            {CloseEvent, "close_event", "closed"},
            {CancelEvent, "cancel_event", "cancelled"}
          ] do
        {:reply, _, _} =
          reply =
          apply(module, :execute, [
            %{"workspace_id" => workspace.id, "event_id" => event.id},
            frame_for(owner)
          ])

        payload = decode_reply(reply)
        assert payload["status"] == "needs_confirmation"
        assert payload["summary"] =~ "终态不可逆"
        assert Ash.get!(Event, event.id, authorize?: false).status == :open

        {:reply, _, _} =
          ConfirmOperation.execute(%{"pending_id" => payload["pending_id"]}, frame_for(owner))

        assert Ash.get!(Event, event.id, authorize?: false).status ==
                 String.to_existing_atom(expected)

        # 回到 open 供下一段（布置而非被测对象）
        {:ok, _} =
          Cgc2046.Repo.query("UPDATE events SET status = 'open' WHERE id = $1", [
            Ecto.UUID.dump!(event.id)
          ])

        [log] = tool_logs_for(owner.id, tool)
        assert log.result_status == :needs_confirmation
      end
    end

    test "错误路径：launch 已 open 活动 → 报错不建 pending" do
      owner = Fixtures.platform_admin("s3-ev-launch-open")
      workspace = Fixtures.create_workspace(owner)
      event = open_event(workspace, owner)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               LaunchEvent.execute(
                 %{"workspace_id" => workspace.id, "event_id" => event.id},
                 frame_for(owner)
               )

      assert msg =~ "cannot launch from status=open"
      assert pending_count() == 0
    end

    test "错误路径：close draft 活动 → 报错不建 pending" do
      owner = Fixtures.platform_admin("s3-ev-close-draft")
      workspace = Fixtures.create_workspace(owner)
      event = draft_event(workspace, owner)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               CloseEvent.execute(
                 %{"workspace_id" => workspace.id, "event_id" => event.id},
                 frame_for(owner)
               )

      assert msg =~ "cannot close from status=draft"
      assert pending_count() == 0
    end
  end

  describe "list_workspace_events（member-only 活动发现面）" do
    test "member 见本台全部状态活动（含 draft）与报名徽章；status 过滤；非 member forbidden" do
      owner = Fixtures.platform_admin("s3-ev-lwe-owner")
      workspace = Fixtures.create_workspace(owner)
      member = Fixtures.register_user("s3-ev-lwe-member")
      Fixtures.add_member(workspace, member, [])

      draft = draft_event(workspace, owner, %{title: "Draft 活动"})
      open = open_event(workspace, owner, %{title: "Open 活动"})

      assert {:reply, _, _} =
               reply =
               ListWorkspaceEvents.execute(%{"workspace_id" => workspace.id}, frame_for(member))

      payload = decode_reply(reply)
      assert payload["count"] == 2

      by_id = Map.new(payload["events"], &{&1["event_id"], &1})
      assert by_id[draft.id]["status"] == "draft"
      assert by_id[open.id]["status"] == "open"

      assert by_id[open.id]["enrollment_badge"] in [
               "enrolling",
               "starting_soon",
               "closed",
               "full"
             ]

      # status 过滤收窄
      assert {:reply, _, _} =
               filtered =
               ListWorkspaceEvents.execute(
                 %{"workspace_id" => workspace.id, "status" => "draft"},
                 frame_for(member)
               )

      assert [row] = decode_reply(filtered)["events"]
      assert row["event_id"] == draft.id

      # 非 member 撞 Wrapper member 门
      outsider = Fixtures.register_user("s3-ev-lwe-outsider")

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ListWorkspaceEvents.execute(%{"workspace_id" => workspace.id}, frame_for(outsider))

      assert msg =~ "not a member"
    end

    test "跨租户隔离：他工作台活动不漏" do
      owner_a = Fixtures.platform_admin("s3-ev-lwe-owner-a")
      workspace_a = Fixtures.create_workspace(owner_a)
      event_a = open_event(workspace_a, owner_a)

      owner_b = Fixtures.platform_admin("s3-ev-lwe-owner-b")
      workspace_b = Fixtures.create_workspace(owner_b)
      event_b = open_event(workspace_b, owner_b)

      {:reply, _, _} =
        reply =
        ListWorkspaceEvents.execute(%{"workspace_id" => workspace_a.id}, frame_for(owner_a))

      ids = Enum.map(decode_reply(reply)["events"], & &1["event_id"])
      assert event_a.id in ids
      refute event_b.id in ids
    end
  end

  describe "list_enrollments（kind=event 分派）" do
    test "Owner 见本活动报名（报名人摘要/状态/档位）；跨 kind 隔离（同工作台课程报名不漏）" do
      owner = Fixtures.platform_admin("s3-ev-le-owner")
      workspace = Fixtures.create_workspace(owner)
      event = paid_event(workspace, owner)
      {learner, enrollment} = payment_pending_enrollment(event, "s3-ev-le-paid")

      # 同工作台课程报名不得漏进活动列表（跨 kind 隔离）
      course = EventFixtures.create_course(workspace, owner)
      course_learner = Fixtures.register_user("s3-ev-le-course")

      {:ok, _course_enrollment} =
        Enrollment
        |> Ash.Changeset.for_create(
          :create_enrollment,
          %{course_id: course.id, user_id: course_learner.id}
        )
        |> Ash.create(tenant: workspace.id, actor: course_learner)

      assert {:reply, _, _} =
               reply =
               ListEnrollments.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "kind" => "event",
                   "offering_id" => event.id
                 },
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["kind"] == "event"
      assert payload["offering_id"] == event.id
      assert payload["count"] == 1

      [row] = payload["enrollments"]
      assert row["enrollment_id"] == enrollment.id
      assert row["status"] == "payment_pending"
      assert row["user"]["id"] == learner.id
      assert row["tier"]["id"] == @tier_id
    end

    test "非法 kind → 参数错误；他工作台 event offering_id = not found" do
      owner = Fixtures.platform_admin("s3-ev-le-kind-owner")
      workspace = Fixtures.create_workspace(owner)
      event = open_event(workspace, owner)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ListEnrollments.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "kind" => "bogus",
                   "offering_id" => event.id
                 },
                 frame_for(owner)
               )

      assert msg =~ "invalid kind"

      owner_b = Fixtures.platform_admin("s3-ev-le-kind-owner-b")
      workspace_b = Fixtures.create_workspace(owner_b)
      event_b = open_event(workspace_b, owner_b)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ListEnrollments.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "kind" => "event",
                   "offering_id" => event_b.id
                 },
                 frame_for(owner)
               )

      assert msg =~ "event not found"
    end
  end

  describe "confirm_enrollment（event 投影）" do
    test "request 活动 pending → confirmed；成功返回投影含 event_id、course_id 为 nil" do
      owner = Fixtures.platform_admin("s3-ev-ce-owner")
      workspace = Fixtures.create_workspace(owner)
      event = open_event(workspace, owner, %{enrollment_policy: :request})
      learner = Fixtures.register_user("s3-ev-ce-learner")
      enrollment = enroll(event, learner)
      assert enrollment.status == :pending

      assert {:reply, _, _} =
               reply =
               ConfirmEnrollment.execute(
                 %{"workspace_id" => workspace.id, "enrollment_id" => enrollment.id},
                 frame_for(owner)
               )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"

      assert {:reply, _, _} =
               confirm_reply =
               ConfirmOperation.execute(
                 %{"pending_id" => payload["pending_id"]},
                 frame_for(owner)
               )

      confirmed = decode_reply(confirm_reply)
      assert confirmed["result"]["status"] == "confirmed"
      assert confirmed["result"]["event_id"] == event.id
      assert confirmed["result"]["course_id"] == nil

      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :confirmed
    end
  end
end
