defmodule Cgc2046Web.GraphqlAdminOfferingGovernanceTest do
  @moduledoc """
  平台治理 offering 写链路（U1）：八个治理 mutations（admin{Launch,Close,Cancel,Update}{Event,Course}）
  + 治理写变更投影读面（`adminActionLog.offeringChange`）。

  - 门控：非平台管理员 forbidden / 未登录 unauthorized（with_admin）；
  - 动作：与工作台同 action 同守卫（slug 锁经同一 action 落稳定 code）；
  - 读面：admin_event_update / admin_course_update 行返回闭集标量前后值投影，
    launch/close/cancel 行投影 null（未收录 action 默认拒不破）；
    rule 族 metadata 对 offering action 仍 null（形状不混槽）。
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures

  @password Fixtures.password()

  defp sign_in_token(user) do
    query = """
    mutation {
      signIn(login: "#{user.email}", password: "#{@password}") {
        id
      }
    }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => query})

    assert %{"data" => %{"signIn" => %{"id" => _id}}} = json_response(conn, 200)
    conn.resp_cookies["cgc_token"].value
  end

  defp graphql(query, token) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn

    conn |> post("/api/graphql", %{"query" => query}) |> json_response(200)
  end

  defp status_mutation(field, id) do
    """
    mutation {
      #{field}(id: "#{id}") {
        result { id status slug title }
        errors { message code fields }
      }
    }
    """
  end

  defp update_mutation(field, id, input_pairs) do
    pairs =
      Enum.map_join(input_pairs, ", ", fn
        {key, value} when is_binary(value) -> ~s(#{key}: "#{value}")
        {key, value} -> "#{key}: #{value}"
      end)

    """
    mutation {
      #{field}(id: "#{id}", input: {#{pairs}}) {
        result { id status title capacity visibility }
        errors { message code fields }
      }
    }
    """
  end

  defp audit_query(action) do
    """
    query {
      listAdminActionLogs(action: "#{action}", first: 100) {
        action
        targetId
        actorId
        metadata { ruleKey }
        offeringChange {
          titleBefore titleAfter
          visibilityBefore visibilityAfter
          capacityBefore capacityAfter
          pricingEnabledBefore pricingEnabledAfter
          depositEnabledBefore depositEnabledAfter
        }
      }
    }
    """
  end

  defp audit_row(resp, target_id) do
    assert %{"data" => %{"listAdminActionLogs" => logs}} = resp
    Enum.find(logs, &(&1["targetId"] == target_id))
  end

  # 非成员平台管理员 + 普通用户 Owner 的工作台
  defp tenant do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
    %{owner: owner, workspace: workspace, admin: Fixtures.platform_admin()}
  end

  describe "adminEvent 治理写" do
    test "平台管理员经治理面完成 draft → open → closed 与元数据编辑；每笔留痕" do
      %{owner: owner, workspace: workspace, admin: admin} = tenant()
      token = sign_in_token(admin)

      draft =
        Cgc2046.Events.Event
        |> Ash.Changeset.for_create(
          :create,
          %{title: "治理面活动", enrollment_policy: :open, capacity: 10},
          tenant: workspace.id
        )
        |> Ash.create!(tenant: workspace.id, actor: owner)

      assert %{"data" => %{"adminUpdateEvent" => %{"result" => updated, "errors" => []}}} =
               graphql(
                 update_mutation("adminUpdateEvent", draft.id, [
                   {"title", "治理面改名"},
                   {"capacity", 12},
                   {"visibility", "workspace"}
                 ]),
                 token
               )

      assert updated["title"] == "治理面改名"
      assert updated["capacity"] == 12
      assert updated["visibility"] == "workspace"

      assert %{"data" => %{"adminLaunchEvent" => %{"result" => launched, "errors" => []}}} =
               graphql(status_mutation("adminLaunchEvent", draft.id), token)

      assert launched["status"] == "open"

      assert %{"data" => %{"adminCloseEvent" => %{"result" => closed, "errors" => []}}} =
               graphql(status_mutation("adminCloseEvent", draft.id), token)

      assert closed["status"] == "closed"

      # 另一场走 cancel（close 已把上一场推入终态）
      open_event = EventFixtures.create_event(workspace, owner)

      assert %{"data" => %{"adminCancelEvent" => %{"result" => cancelled, "errors" => []}}} =
               graphql(status_mutation("adminCancelEvent", open_event.id), token)

      assert cancelled["status"] == "cancelled"

      # 留痕：四笔治理写各一行，操作者 = 平台管理员，target = 该场
      assert audit_row(graphql(audit_query("admin_event_update"), token), draft.id)["actorId"] ==
               admin.id

      assert audit_row(graphql(audit_query("admin_event_launch"), token), draft.id)
      assert audit_row(graphql(audit_query("admin_event_close"), token), draft.id)
      assert audit_row(graphql(audit_query("admin_event_cancel"), token), open_event.id)
    end

    test "治理 update 改已发布场 slug：errors 带稳定 code event_slug_locked（AE5 管理面路径）" do
      %{owner: owner, workspace: workspace, admin: admin} = tenant()
      token = sign_in_token(admin)
      event = EventFixtures.create_event(workspace, owner, %{slug: "gov-gql-slug-lock"})

      assert %{
               "data" => %{
                 "adminUpdateEvent" => %{"result" => nil, "errors" => [error]}
               }
             } =
               graphql(
                 update_mutation("adminUpdateEvent", event.id, [{"slug", "gov-gql-slug-lock-2"}]),
                 token
               )

      assert error["code"] == "event_slug_locked"

      assert Ash.get!(Cgc2046.Events.Event, event.id, authorize?: false).slug ==
               "gov-gql-slug-lock"
    end

    test "非平台管理员（工作台 Owner）与匿名调用被拒（with_admin 门控）" do
      %{owner: owner, workspace: workspace} = tenant()
      event = EventFixtures.create_event(workspace, owner)

      assert %{"errors" => [%{"message" => "forbidden"}]} =
               graphql(status_mutation("adminCloseEvent", event.id), sign_in_token(owner))

      assert %{"errors" => [%{"message" => "unauthorized"}]} =
               graphql(status_mutation("adminCloseEvent", event.id), nil)

      assert Ash.get!(Cgc2046.Events.Event, event.id, authorize?: false).status == :open
    end
  end

  describe "adminCourse 治理写" do
    test "平台管理员经治理面完成 draft → open → cancelled 与元数据编辑；每笔留痕" do
      %{owner: owner, workspace: workspace, admin: admin} = tenant()
      token = sign_in_token(admin)

      draft =
        Cgc2046.Courses.Course
        |> Ash.Changeset.for_create(
          :create,
          %{title: "治理面课程", enrollment_policy: :open, capacity: 8},
          tenant: workspace.id
        )
        |> Ash.create!(tenant: workspace.id, actor: owner)

      assert %{"data" => %{"adminUpdateCourse" => %{"result" => updated, "errors" => []}}} =
               graphql(
                 update_mutation("adminUpdateCourse", draft.id, [
                   {"title", "治理面课程改名"},
                   {"capacity", 9}
                 ]),
                 token
               )

      assert updated["title"] == "治理面课程改名"
      assert updated["capacity"] == 9

      assert %{"data" => %{"adminLaunchCourse" => %{"result" => launched, "errors" => []}}} =
               graphql(status_mutation("adminLaunchCourse", draft.id), token)

      assert launched["status"] == "open"

      cancel_course = EventFixtures.create_course(workspace, owner)

      assert %{"data" => %{"adminCancelCourse" => %{"result" => cancelled, "errors" => []}}} =
               graphql(status_mutation("adminCancelCourse", cancel_course.id), token)

      assert cancelled["status"] == "cancelled"

      close_course = EventFixtures.create_course(workspace, owner)

      assert %{"data" => %{"adminCloseCourse" => %{"result" => closed, "errors" => []}}} =
               graphql(status_mutation("adminCloseCourse", close_course.id), token)

      assert closed["status"] == "closed"

      assert audit_row(graphql(audit_query("admin_course_update"), token), draft.id)["actorId"] ==
               admin.id

      assert audit_row(graphql(audit_query("admin_course_launch"), token), draft.id)
      assert audit_row(graphql(audit_query("admin_course_cancel"), token), cancel_course.id)
      assert audit_row(graphql(audit_query("admin_course_close"), token), close_course.id)
    end

    test "非平台管理员（工作台 Owner）调用被拒" do
      %{owner: owner, workspace: workspace} = tenant()
      course = EventFixtures.create_course(workspace, owner)

      assert %{"errors" => [%{"message" => "forbidden"}]} =
               graphql(status_mutation("adminCancelCourse", course.id), sign_in_token(owner))

      assert Ash.get!(Cgc2046.Courses.Course, course.id, authorize?: false).status == :open
    end
  end

  describe "治理写变更投影（adminActionLog.offeringChange）" do
    test "update 行返回闭集标量前后值；launch 行投影 null；rule 槽对 offering action 仍 null" do
      %{owner: owner, workspace: workspace, admin: admin} = tenant()
      token = sign_in_token(admin)

      draft =
        Cgc2046.Events.Event
        |> Ash.Changeset.for_create(
          :create,
          %{title: "投影活动", enrollment_policy: :open, capacity: 10},
          tenant: workspace.id
        )
        |> Ash.create!(tenant: workspace.id, actor: owner)

      assert %{"data" => %{"adminLaunchEvent" => %{"errors" => []}}} =
               graphql(status_mutation("adminLaunchEvent", draft.id), token)

      assert %{"data" => %{"adminUpdateEvent" => %{"errors" => []}}} =
               graphql(
                 update_mutation("adminUpdateEvent", draft.id, [
                   {"capacity", 20},
                   {"visibility", "workspace"},
                   {"description", "自由文本 secret"}
                 ]),
                 token
               )

      update_row = audit_row(graphql(audit_query("admin_event_update"), token), draft.id)
      assert update_row["actorId"] == admin.id

      change = update_row["offeringChange"]
      assert change["capacityBefore"] == 10
      assert change["capacityAfter"] == 20
      assert change["visibilityBefore"] == "public"
      assert change["visibilityAfter"] == "workspace"
      # 未变更的闭集列不落键 → 读面 null（不是 0/false 假值）
      assert change["titleBefore"] == nil
      assert change["pricingEnabledBefore"] == nil
      assert change["depositEnabledBefore"] == nil
      # rule 族 metadata 槽只收 rule 形状的 action：offering 行必须 null（不混槽）
      assert update_row["metadata"] == nil
      # 自由文本不进变更投影（结构性：键名不在闭集内）
      refute Jason.encode!(update_row) =~ "自由文本 secret"

      # launch 未收录 → 投影 null（行本身仍可见）
      launch_row = audit_row(graphql(audit_query("admin_event_launch"), token), draft.id)
      assert launch_row["offeringChange"] == nil
      assert launch_row["metadata"] == nil
    end

    test "Course 行的 deposit 两列恒 null（该资源无押金槽位）" do
      %{owner: owner, workspace: workspace, admin: admin} = tenant()
      token = sign_in_token(admin)

      course =
        Cgc2046.Courses.Course
        |> Ash.Changeset.for_create(
          :create,
          %{title: "投影课程", enrollment_policy: :open, capacity: 4},
          tenant: workspace.id
        )
        |> Ash.create!(tenant: workspace.id, actor: owner)

      assert %{"data" => %{"adminUpdateCourse" => %{"errors" => []}}} =
               graphql(
                 update_mutation("adminUpdateCourse", course.id, [{"capacity", 6}]),
                 token
               )

      row = audit_row(graphql(audit_query("admin_course_update"), token), course.id)
      assert row["offeringChange"]["capacityBefore"] == 4
      assert row["offeringChange"]["capacityAfter"] == 6
      assert row["offeringChange"]["depositEnabledBefore"] == nil
      assert row["offeringChange"]["depositEnabledAfter"] == nil
    end

    test "非标量值不透传：读面省略该列而非原样带出" do
      %{owner: owner, workspace: workspace, admin: admin} = tenant()
      token = sign_in_token(admin)

      draft =
        Cgc2046.Events.Event
        |> Ash.Changeset.for_create(
          :create,
          %{title: "污染行", enrollment_policy: :open},
          tenant: workspace.id
        )
        |> Ash.create!(tenant: workspace.id, actor: owner)

      # 直连写入面造一条「未来某条路径往闭集列塞了嵌套结构」的行
      {:ok, _} =
        Cgc2046.Accounts.AdminActionLog.log(%{
          actor_id: admin.id,
          action: :admin_event_update,
          target_type: :event,
          target_id: draft.id,
          metadata: %{
            capacity_after: %{"nested" => "leak@example.com"},
            title_after: "标题照出"
          }
        })

      row = audit_row(graphql(audit_query("admin_event_update"), token), draft.id)

      refute Jason.encode!(row) =~ "leak@example.com"
      assert row["offeringChange"]["titleAfter"] == "标题照出"
      assert row["offeringChange"]["capacityAfter"] == nil
    end

    test "只改自由文本（闭集列零变更）的行投影 null，不渲染全空对象" do
      %{owner: owner, workspace: workspace, admin: admin} = tenant()
      token = sign_in_token(admin)

      draft =
        Cgc2046.Events.Event
        |> Ash.Changeset.for_create(
          :create,
          %{title: "自由文本行", enrollment_policy: :open},
          tenant: workspace.id
        )
        |> Ash.create!(tenant: workspace.id, actor: owner)

      assert %{"data" => %{"adminUpdateEvent" => %{"errors" => []}}} =
               graphql(
                 update_mutation("adminUpdateEvent", draft.id, [
                   {"description", "只改描述"}
                 ]),
                 token
               )

      row = audit_row(graphql(audit_query("admin_event_update"), token), draft.id)
      assert row["offeringChange"] == nil
    end
  end

  describe "R7 字段闭集（独立评审收口）" do
    test "平台管理员经既有工作台 updateEvent 写教研字段被拒——无旁路" do
      %{owner: owner, workspace: workspace, admin: admin} = tenant()
      token = sign_in_token(admin)
      draft = EventFixtures.create_event(workspace, owner)

      %{"data" => %{"updateEvent" => %{"result" => nil, "errors" => [error]}}} =
        graphql(
          """
          mutation {
            updateEvent(id: "#{draft.id}", input: {title: "旁路尝试", curriculumEnabled: false}) {
              result { id }
              errors { message code }
            }
          }
          """,
          token
        )

      assert error["code"] == "forbidden"

      reloaded = Ash.get!(Cgc2046.Events.Event, draft.id, authorize?: false)
      assert reloaded.title == draft.title
      assert reloaded.curriculum_enabled == draft.curriculum_enabled
    end

    test "治理 mutation 只写闭集字段不受新闭集影响；attributes 判定不吞挂载 force-write" do
      %{owner: owner, workspace: workspace, admin: admin} = tenant()
      draft = EventFixtures.create_event(workspace, owner)

      # 域级：显式输入（attributes）⊆ 闭集 + force_change 外溢（挂载规则写入路径）
      # 不进 attributes → check 放行，不误拒挂载场的治理元数据更新。
      cs =
        draft
        |> Ash.Changeset.for_update(:update, %{title: "治理改名"})
        |> Ash.Changeset.force_change_attribute(:deposit_enabled, false)

      assert Cgc2046.Offering.PlatformAdminGovernanceWrite.match?(
               admin,
               %{action: %{name: :update}, changeset: cs},
               []
             )

      # 显式输入含教研字段 → 拒绝（R7）。
      deny_cs =
        Ash.Changeset.for_update(draft, :update, %{curriculum_requirements: %{"audience" => "x"}})

      refute Cgc2046.Offering.PlatformAdminGovernanceWrite.match?(
               admin,
               %{action: %{name: :update}, changeset: deny_cs},
               []
             )
    end
  end
end
