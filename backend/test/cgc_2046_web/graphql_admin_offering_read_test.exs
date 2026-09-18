defmodule Cgc2046Web.GraphqlAdminOfferingReadTest do
  @moduledoc """
  U2 治理读面（后端）：`listAdminEvents` / `listAdminCourses` / `getAdminEvent` /
  `getAdminCourse` 与 `reconciliationFindings` 的 entity_id 成对过滤。

  - 跨租户列表与过滤（AE1 后端面：不选工作台即见全租户全状态，含 draft/cancelled）；
  - 分页契约：first 封顶 200、非法 after 回退；
  - 详情：权威报名计数（Enrollment 现取，与 confirmed_count 展示投影解耦）、
    主理人清单读面、解除挂载来源标记、课程占位标题与版本指针；
  - findings 成对过滤（KTD5）；
  - 门控：非平台管理员 forbidden / 未登录 unauthorized；列表文档在复杂度预算内。
  """

  use Cgc2046Web.ConnCase, async: true

  require Ash.Query

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Reconciliation.Finding

  @password Fixtures.password()
  @tier_id "66666666-6666-6666-6666-666666666666"

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

  defp graphql(query, token \\ nil) do
    conn = build_conn() |> put_req_header("content-type", "application/json")
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn

    conn |> post("/api/graphql", %{"query" => query}) |> json_response(200)
  end

  defp data!(body) do
    assert %{"data" => data} = body
    data
  end

  # 两个工作台 + 一个两台都不是成员的平台管理员（治理读面必须在无成员身份下可用）
  defp tenant_pair do
    %{
      admin: Fixtures.platform_admin("admin-offering-read"),
      a: Fixtures.workspace_with_member(),
      b: Fixtures.workspace_with_member()
    }
  end

  defp draft_event(workspace, actor, attrs) do
    attrs = Map.merge(%{title: "治理活动", enrollment_policy: :open}, attrs)

    Cgc2046.Events.Event
    |> Ash.Changeset.for_create(:create, attrs, tenant: workspace.id)
    |> Ash.create!(tenant: workspace.id, actor: actor)
  end

  defp transition(event, action, workspace, actor) do
    event
    |> Ash.Changeset.for_update(action, %{})
    |> Ash.update!(tenant: workspace.id, actor: actor)
  end

  defp enroll(workspace_id, learner, attrs) do
    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, Map.put(attrs, :user_id, learner.id))
    |> Ash.create!(tenant: workspace_id, actor: learner)
  end

  defp ids(rows), do: Enum.map(rows, & &1["id"])

  defp list_admin_events(token, args) do
    """
    query {
      listAdminEvents(#{args}) { id workspaceId title slug status }
    }
    """
    |> graphql(token)
    |> data!()
    |> Map.fetch!("listAdminEvents")
  end

  defp get_admin_event(token, id) do
    """
    query {
      getAdminEvent(id: "#{id}") {
        id
        workspaceId
        title
        slug
        status
        confirmedCount
        paymentPendingCount
        moderators { id userId }
        detachedRuleProvenance
      }
    }
    """
    |> graphql(token)
    |> data!()
    |> Map.fetch!("getAdminEvent")
  end

  describe "listAdminEvents" do
    test "平台管理员不选工作台即见全租户、全状态的活动（AE1 后端面）" do
      %{admin: admin, a: a, b: b} = tenant_pair()
      token = sign_in_token(admin)

      draft = draft_event(a.workspace, a.owner, %{title: "甲台草稿"})

      open =
        a.workspace
        |> draft_event(a.owner, %{title: "甲台发布"})
        |> transition(:launch, a.workspace, a.owner)

      cancelled =
        a.workspace
        |> draft_event(a.owner, %{title: "甲台取消"})
        |> transition(:launch, a.workspace, a.owner)
        |> transition(:cancel, a.workspace, a.owner)

      b_draft = draft_event(b.workspace, b.owner, %{title: "乙台草稿"})

      rows = list_admin_events(token, "first: 100")

      assert Enum.sort(ids(rows)) ==
               Enum.sort([draft.id, open.id, cancelled.id, b_draft.id])

      # draft 与 cancelled 都在（工作台列表按定义看不到这两态）
      assert Enum.sort(Enum.map(rows, & &1["status"])) == ["cancelled", "draft", "draft", "open"]
      # 行带 workspace_id：前端以既有 workspaces 数据映射名称
      assert Enum.all?(rows, &(&1["workspaceId"] in [a.workspace.id, b.workspace.id]))
    end

    test "workspaceId 过滤：命中只返回该台行，不命中返回空" do
      %{admin: admin, a: a, b: b} = tenant_pair()
      token = sign_in_token(admin)

      a_event = draft_event(a.workspace, a.owner, %{title: "甲台"})
      b_event = draft_event(b.workspace, b.owner, %{title: "乙台"})

      assert ids(list_admin_events(token, ~s(workspaceId: "#{a.workspace.id}"))) == [a_event.id]
      assert ids(list_admin_events(token, ~s(workspaceId: "#{b.workspace.id}"))) == [b_event.id]

      assert list_admin_events(token, ~s(workspaceId: "#{Ecto.UUID.generate()}")) == []
    end

    test "search 命中 title 或 slug；status 按枚举过滤" do
      %{admin: admin, a: a} = tenant_pair()
      token = sign_in_token(admin)

      alpha =
        draft_event(a.workspace, a.owner, %{title: "Alpha 治理", slug: "gov-alpha-2026"})

      beta = draft_event(a.workspace, a.owner, %{title: "Beta 治理", slug: "gov-beta-2026"})
      open_beta = transition(beta, :launch, a.workspace, a.owner)

      closed =
        a.workspace
        |> draft_event(a.owner, %{title: "已结束治理"})
        |> transition(:launch, a.workspace, a.owner)
        |> transition(:close, a.workspace, a.owner)

      # title contains
      assert ids(list_admin_events(token, ~s(search: "Alpha"))) == [alpha.id]
      # slug contains（定位场景：按公开 URL 段搜）
      assert ids(list_admin_events(token, ~s(search: "gov-beta"))) == [beta.id]
      # 不命中
      assert list_admin_events(token, ~s(search: "不存在的名字")) == []

      assert ids(list_admin_events(token, ~s(status: "draft"))) == [alpha.id]
      assert ids(list_admin_events(token, ~s(status: "open"))) == [open_beta.id]
      assert ids(list_admin_events(token, ~s(status: "closed"))) == [closed.id]
      assert ids(list_admin_events(token, ~s(status: "cancelled"))) == []
      # 工作台过滤与状态过滤可组合（定位闭环：某台 + 某状态）
      assert ids(list_admin_events(token, ~s(workspaceId: "#{a.workspace.id}", status: "draft"))) ==
               [alpha.id]
    end

    test "分页：first 封顶 200；after 偏移；非法 after 回退（不过滤偏移）" do
      %{admin: admin, a: a} = tenant_pair()
      token = sign_in_token(admin)

      for i <- 1..205 do
        draft_event(a.workspace, a.owner, %{title: "分页场 #{i}"})
      end

      # first: 500 的文档复杂度 500 × (3+2) = 2_500 < 4_000，不被预算层拒绝，
      # 封顶由 AdminList（@max_first 200）承担
      assert length(list_admin_events(token, "first: 500")) == 200

      assert length(list_admin_events(token, "first: 10")) == 10
      assert length(list_admin_events(token, "first: 10 after: \"5\"")) == 10

      # 非法 after（非数字）回退为首页，不报错
      first_page = ids(list_admin_events(token, "first: 10"))
      assert ids(list_admin_events(token, ~s(first: 10 after: "not-a-number"))) == first_page
    end

    test "非平台管理员 forbidden、未登录 unauthorized（无数据暴露）" do
      %{a: a} = tenant_pair()
      draft_event(a.workspace, a.owner, %{title: "不该外泄"})

      doc = """
      query {
        listAdminEvents(first: 10) { id title }
      }
      """

      assert %{"errors" => [member_error | _]} = graphql(doc, sign_in_token(a.owner))
      assert member_error["message"] == "forbidden"

      assert %{"errors" => [anonymous_error | _]} = graphql(doc)
      assert anonymous_error["message"] == "unauthorized"
    end

    test "治理列表文档（first: 100，行字段全集）在复杂度预算内" do
      %{admin: admin} = tenant_pair()

      doc = """
      query {
        listAdminEvents(first: 100) {
          id
          workspaceId
          title
          slug
          status
          visibility
          capacity
          registrationDeadline
          startsAt
          endsAt
          pricingEnabled
          depositEnabled
          depositAmountCents
          insertedAt
          updatedAt
        }
        listAdminCourses(first: 100) {
          id
          workspaceId
          title
          provisionalTitle
          slug
          status
          visibility
          capacity
          registrationDeadline
          startsAt
          endsAt
          pricingEnabled
          insertedAt
          updatedAt
        }
      }
      """

      body = graphql(doc, sign_in_token(admin))

      refute Enum.any?(
               body["errors"] || [],
               &String.contains?(&1["message"] || "", "too complex")
             ),
             "治理列表撞复杂度上限：#{inspect(body["errors"])}"

      assert %{"listAdminEvents" => _, "listAdminCourses" => _} = data!(body)
    end
  end

  describe "getAdminEvent" do
    test "计数 = 权威 Enrollment 行数（免费场零待付），与 confirmed_count 展示投影解耦" do
      %{admin: admin, a: a} = tenant_pair()
      token = sign_in_token(admin)

      event = EventFixtures.create_event(a.workspace, a.owner, %{title: "甲台免费场", capacity: 10})

      for name <- ["count-l1", "count-l2"] do
        enroll(event.workspace_id, Fixtures.register_user(name), %{event_id: event.id})
      end

      # 展示投影被人为推高（滞后/漂移现场）：详情必须回权威行数，不回该列
      projected = EventFixtures.set_confirmed_count(event, :events, 7)
      assert projected.confirmed_count == 7

      payload = get_admin_event(token, event.id)

      assert payload["confirmedCount"] == 2
      assert payload["paymentPendingCount"] == 0
      assert payload["confirmedCount"] == count_enrollments(:event_id, event.id, :confirmed)
    end

    test "收费场：confirmed 与 payment_pending 分列计数" do
      %{admin: admin, a: a} = tenant_pair()
      token = sign_in_token(admin)

      paid =
        EventFixtures.create_event(a.workspace, a.owner, %{
          title: "甲台收费场",
          capacity: 10,
          pricing_enabled: true,
          price_tiers: [
            %{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900}
          ]
        })

      enrollment =
        enroll(paid.workspace_id, Fixtures.register_user("count-paid"), %{
          event_id: paid.id,
          tier_id: @tier_id
        })

      assert enrollment.status == :payment_pending

      payload = get_admin_event(token, paid.id)

      assert payload["confirmedCount"] == 0
      assert payload["paymentPendingCount"] == 1

      assert payload["paymentPendingCount"] ==
               count_enrollments(:event_id, paid.id, :payment_pending)
    end

    test "非成员平台管理员读主理人清单不 forbidden" do
      %{admin: admin, a: a} = tenant_pair()
      token = sign_in_token(admin)
      event = EventFixtures.create_event(a.workspace, a.owner, %{title: "甲台主理人场"})

      assert {:ok, _assigned} =
               Cgc2046.Events.Moderators.assign(
                 event.id,
                 a.workspace.id,
                 a.member.id,
                 a.owner
               )

      refute Cgc2046.Accounts.MembershipContext.membership_of(admin, a.workspace.id)

      payload = get_admin_event(token, event.id)

      # 创建者（Owner）在 create 时自动成为主理人，加显式指派 = 两行
      assert Enum.sort(Enum.map(payload["moderators"], & &1["userId"])) ==
               Enum.sort([a.owner.id, a.member.id])
    end

    test "不存在的 id 返回 null（前端「未找到」态，不起 GraphQL 错误）" do
      %{admin: admin} = tenant_pair()

      assert %{"data" => %{"getAdminEvent" => nil}} =
               graphql(
                 """
                 query {
                   getAdminEvent(id: "#{Ecto.UUID.generate()}") { id }
                 }
                 """,
                 sign_in_token(admin)
               )
    end
  end

  describe "listAdminCourses / getAdminCourse" do
    test "课程行与详情：占位标题标记 + 权威计数" do
      %{admin: admin, a: a} = tenant_pair()
      token = sign_in_token(admin)

      # 零输入草稿：create 不给 title → 系统生成占位标题（发布前置门）
      placeholder =
        Cgc2046.Courses.Course
        |> Ash.Changeset.for_create(:create, %{enrollment_policy: :open}, tenant: a.workspace.id)
        |> Ash.create!(tenant: a.workspace.id, actor: a.owner)

      course = EventFixtures.create_course(a.workspace, a.owner, %{title: "甲台课程"})
      enroll(course.workspace_id, Fixtures.register_user("course-count"), %{course_id: course.id})

      rows =
        """
        query {
          listAdminCourses(first: 10) {
            id workspaceId title provisionalTitle status
          }
        }
        """
        |> graphql(token)
        |> data!()
        |> Map.fetch!("listAdminCourses")

      assert Enum.sort(ids(rows)) == Enum.sort([placeholder.id, course.id])
      assert Enum.find(rows, &(&1["id"] == placeholder.id))["provisionalTitle"] == true
      assert Enum.find(rows, &(&1["id"] == course.id))["provisionalTitle"] == false

      detail =
        """
        query {
          getAdminCourse(id: "#{course.id}") {
            title
            workspaceId
            status
            provisionalTitle
            confirmedCount
            paymentPendingCount
          }
        }
        """
        |> graphql(token)
        |> data!()
        |> Map.fetch!("getAdminCourse")

      assert detail["title"] == "甲台课程"
      assert detail["workspaceId"] == a.workspace.id
      assert detail["status"] == "open"
      assert detail["provisionalTitle"] == false
      assert detail["confirmedCount"] == 1
      assert detail["paymentPendingCount"] == 0

      placeholder_detail =
        """
        query {
          getAdminCourse(id: "#{placeholder.id}") { title provisionalTitle confirmedCount }
        }
        """
        |> graphql(token)
        |> data!()
        |> Map.fetch!("getAdminCourse")

      assert placeholder_detail["provisionalTitle"] == true
      assert placeholder_detail["title"] == placeholder.title
      assert placeholder_detail["confirmedCount"] == 0
    end
  end

  describe "reconciliationFindings 关联过滤（KTD5）" do
    test "entityId 必须与 entityType 成对，否则拒绝" do
      %{admin: admin} = tenant_pair()
      event_id = Ecto.UUID.generate()

      assert %{"errors" => [error | _]} =
               graphql(
                 """
                 query {
                   reconciliationFindings(entityId: "#{event_id}") { id }
                 }
                 """,
                 sign_in_token(admin)
               )

      assert error["code"] == "invalid_input"
      assert error["message"] =~ "entity_type"
    end

    test "成对过滤命中该实体的发现；entityType 单独用仍可用" do
      %{admin: admin, a: a} = tenant_pair()
      token = sign_in_token(admin)

      event = EventFixtures.create_event(a.workspace, a.owner, %{title: "排查场"})
      other = EventFixtures.create_event(a.workspace, a.owner, %{title: "无关场"})

      target = create_finding(%{entity_type: :event, entity_id: event.id})
      other_finding = create_finding(%{entity_type: :event, entity_id: other.id})

      paired =
        """
        query {
          reconciliationFindings(entityType: "event", entityId: "#{event.id}") { id entityType entityId }
        }
        """
        |> graphql(token)
        |> data!()
        |> Map.fetch!("reconciliationFindings")

      assert [row] = paired

      assert row == %{
               "id" => target.id,
               "entityType" => "event",
               "entityId" => event.id
             }

      # entity_type 单独用（既有面）不受成对约束影响
      unpaired =
        """
        query {
          reconciliationFindings(entityType: "event", first: 100) { id }
        }
        """
        |> graphql(token)
        |> data!()
        |> Map.fetch!("reconciliationFindings")

      assert Enum.sort(ids(unpaired)) == Enum.sort([target.id, other_finding.id])
    end
  end

  defp count_enrollments(offering_field, offering_id, status) do
    Enrollment
    |> Ash.Query.filter(^[{offering_field, offering_id}])
    |> Ash.Query.filter(status == ^status)
    |> Ash.count!(authorize?: false)
  end

  defp create_finding(attrs) do
    Finding
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          rule: :capacity_projection_drift,
          entity_type: :event,
          entity_id: Ecto.UUID.generate(),
          detail: %{}
        },
        attrs
      )
    )
    |> Ash.create!(authorize?: false)
  end
end
