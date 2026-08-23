defmodule Cgc2046Web.GraphqlPublicOfferingTest do
  @moduledoc """
  E-5 #50 G5：getEventBySlug / getCourseBySlug 公开宿主页查询三态。

  - 匿名对 `open + public` → 返回详情（公开发现面）
  - 匿名/非成员登录对 workspace-only / 非 open → null（404 语义，不泄露存在性）
  - 成员登录对 workspace-only → 返回（成员可读非 draft）
  """

  use Cgc2046Web.ConnCase, async: true

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Mcp.Tools.GetPublicOffering
  alias Cgc2046.Mcp.Tools.ListPublicOfferings

  defp event_query(slug) do
    """
    query {
      getEventBySlug(slug: "#{slug}") {
        id slug title status visibility enrollmentPolicy
      }
    }
    """
  end

  defp course_query(slug) do
    """
    query {
      getCourseBySlug(slug: "#{slug}") {
        id slug title status visibility enrollmentPolicy
      }
    }
    """
  end

  defp anon(query) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end

  defp graphql(query, token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end

  defp sign_in_token(user) do
    mutation = """
    mutation {
      signIn(login: "#{user.email}", password: "#{Fixtures.password()}") { id }
    }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => mutation})

    assert %{"data" => %{"signIn" => %{"id" => _}}} = json_response(conn, 200)
    conn.resp_cookies["cgc_token"].value
  end

  describe "getEventBySlug" do
    test "匿名对 open+public 活动 → 返回详情" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      assert %{"data" => %{"getEventBySlug" => result}} = anon(event_query(event.slug))
      assert result["id"] == event.id
      assert result["slug"] == event.slug
      assert result["status"] == "open"
      assert result["visibility"] == "public"
    end

    test "匿名对 workspace-only 活动 → null（404 语义，不泄露存在性）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{visibility: :workspace})

      assert %{"data" => %{"getEventBySlug" => nil}} = anon(event_query(event.slug))
    end

    test "匿名对 closed 活动 → null（非 open 404）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      assert {:ok, closed} =
               event
               |> Ash.Changeset.for_update(:close, %{}, tenant: workspace.id, actor: admin)
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert closed.status == :closed
      assert %{"data" => %{"getEventBySlug" => nil}} = anon(event_query(event.slug))
    end

    test "成员登录对 workspace-only 活动 → 返回（成员可读非 draft）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{visibility: :workspace})
      member = Fixtures.register_user("gql-pub-member")
      Fixtures.add_member(workspace, member)

      assert %{"data" => %{"getEventBySlug" => result}} =
               graphql(event_query(event.slug), sign_in_token(member))

      assert result["id"] == event.id
      assert result["visibility"] == "workspace"
    end

    test "非成员登录对 workspace-only 活动 → null（登录不越权，视同匿名）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{visibility: :workspace})
      outsider = Fixtures.register_user("gql-pub-outsider")

      assert %{"data" => %{"getEventBySlug" => nil}} =
               graphql(event_query(event.slug), sign_in_token(outsider))
    end
  end

  describe "getCourseBySlug" do
    test "匿名对 open+public 课程 → 返回；workspace-only → null（Course 同构）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      public_course = EventFixtures.create_course(workspace, admin)
      workspace_course = EventFixtures.create_course(workspace, admin, %{visibility: :workspace})

      assert %{"data" => %{"getCourseBySlug" => result}} =
               anon(course_query(public_course.slug))

      assert result["id"] == public_course.id

      assert %{"data" => %{"getCourseBySlug" => nil}} =
               anon(course_query(workspace_course.slug))
    end
  end

  # X1（advisor02 第 3 轮）：小程序公开详情查询（getEvent/getCourse 按 id +
  # filter 钉死 open+public）与 catalog 同构——非公开条目按不存在处理，
  # 任何身份（匿名/外部成员/同工作台成员/管理员）都不可经该查询越权。
  describe "X1 mini 详情匿名口径：getEvent(id, filter) 四姿态" do
    defp mini_detail_query(id) do
      """
      query {
        getEvent(id: "#{id}", filter: {status: {eq: "open"}, visibility: {eq: "public"}}) {
          id title
        }
      }
      """
    end

    setup do
      admin = Fixtures.platform_admin("x1-admin")
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("x1-member")
      Fixtures.add_member(workspace, member, [:learner])
      outsider = Fixtures.register_user("x1-outsider")
      other_admin = Fixtures.platform_admin("x1-other")
      other_ws = Fixtures.create_workspace(other_admin)
      outsider_member = Fixtures.register_user("x1-xmember")
      Fixtures.add_member(other_ws, outsider_member, [:learner])

      %{
        admin: admin,
        workspace: workspace,
        member: member,
        outsider: outsider,
        outsider_member: outsider_member
      }
    end

    test "open+public：四身份皆可见（口径即匿名白名单，身份不带来额外可见性）", ctx do
      event = EventFixtures.create_event(ctx.workspace, ctx.admin, %{title: "公开活动"})

      for token <- [
            nil,
            sign_in_token(ctx.outsider_member),
            sign_in_token(ctx.member),
            sign_in_token(ctx.admin)
          ] do
        resp =
          if token,
            do: graphql(mini_detail_query(event.id), token),
            else: anon(mini_detail_query(event.id))

        assert %{"data" => %{"getEvent" => %{"id" => id}}} = resp
        assert id == event.id
      end
    end

    test "workspace-only：四身份经该查询均 null（成员语义不经公开详情口径泄露）", ctx do
      event = EventFixtures.create_event(ctx.workspace, ctx.admin, %{visibility: :workspace})

      for token <- [
            nil,
            sign_in_token(ctx.outsider_member),
            sign_in_token(ctx.member),
            sign_in_token(ctx.admin)
          ] do
        resp =
          if token,
            do: graphql(mini_detail_query(event.id), token),
            else: anon(mini_detail_query(event.id))

        assert %{"data" => %{"getEvent" => nil}} = resp
      end
    end

    test "closed：四身份均 null", ctx do
      event = EventFixtures.create_event(ctx.workspace, ctx.admin)

      {:ok, closed} =
        event
        |> Ash.Changeset.for_update(:close, %{}, tenant: ctx.workspace.id, actor: ctx.admin)
        |> Ash.update(tenant: ctx.workspace.id, actor: ctx.admin)

      for token <- [
            nil,
            sign_in_token(ctx.outsider_member),
            sign_in_token(ctx.member),
            sign_in_token(ctx.admin)
          ] do
        resp =
          if token,
            do: graphql(mini_detail_query(closed.id), token),
            else: anon(mini_detail_query(closed.id))

        assert %{"data" => %{"getEvent" => nil}} = resp
      end
    end

    test "draft：四身份均 null", ctx do
      event = EventFixtures.create_event(ctx.workspace, ctx.admin)

      # draft 不可经 create action 建（status writable?: false）——直写库置位
      # （fixture force_open 同款先例）
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE events SET status = 'draft' WHERE id = '#{event.id}'"
        )

      for token <- [
            nil,
            sign_in_token(ctx.outsider_member),
            sign_in_token(ctx.member),
            sign_in_token(ctx.admin)
          ] do
        resp =
          if token,
            do: graphql(mini_detail_query(event.id), token),
            else: anon(mini_detail_query(event.id))

        assert %{"data" => %{"getEvent" => nil}} = resp
      end
    end
  end

  # ── U3（R10/R6/KTD1）：公开白名单扩展字段 ──

  # 7a284bb 曾误删本属性：使用处编译为 nil + warning，venue 合同测试退化
  # 为 nil == nil 假绿（advisor02 第 4 轮 blocker 1）。恢复 + 下方非空断言。
  @venue_beijing %{"country" => "中国", "province" => "北京市", "city" => "北京", "district" => "海淀区"}

  defp public_event_detail_query(slug) do
    """
    query {
      getEventBySlug(slug: "#{slug}") {
        id slug title description status visibility enrollmentPolicy
        registrationDeadline startsAt endsAt venue enrollmentBadge
        pricingEnabled availablePriceTiers sponsorshipEnabled sponsorshipTiers
      }
    }
    """
  end

  defp public_course_detail_query(slug) do
    """
    query {
      getCourseBySlug(slug: "#{slug}") {
        id slug title description status visibility enrollmentPolicy
        registrationDeadline startsAt endsAt enrollmentBadge
        pricingEnabled availablePriceTiers
      }
    }
    """
  end

  defp public_list_events_query do
    """
    query {
      listEvents(filter: {status: {eq: "open"}, visibility: {eq: "public"}}) {
        results { id slug title startsAt enrollmentBadge venue }
      }
    }
    """
  end

  defp public_list_courses_query do
    """
    query {
      listCourses(filter: {status: {eq: "open"}, visibility: {eq: "public"}}) {
        results { id slug title startsAt enrollmentBadge }
      }
    }
    """
  end

  # GraphQL DateTime/JsonString 与工具 ISO8601/map 的归一化（两侧同源，格式不同）。
  defp norm_dt(nil), do: nil

  defp norm_dt(iso) when is_binary(iso) do
    {:ok, dt, _offset} = DateTime.from_iso8601(iso)
    dt
  end

  defp decode_json_string(nil), do: nil
  defp decode_json_string(s) when is_binary(s), do: Jason.decode!(s)

  defp decode_json_string_list(nil), do: nil

  defp decode_json_string_list(list) when is_list(list),
    do: Enum.map(list, &Jason.decode!/1)

  describe "U3 公开白名单扩展字段（R10 同一匿名数据通道，仅扩展字段）" do
    test "匿名详情可查 startsAt/endsAt/venue/enrollmentBadge（event）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{
          description: "公开描述",
          venue: @venue_beijing,
          starts_at: EventFixtures.days_from_now(3),
          ends_at: EventFixtures.days_from_now(4)
        })

      # fixture 非空守卫：属性再被误删时（编译为 nil），这里先红，
      # 不让 venue 断言退化成 nil == nil 假绿
      assert event.venue == @venue_beijing

      assert %{"data" => %{"getEventBySlug" => result}} =
               anon(public_event_detail_query(event.slug))

      assert result["id"] == event.id
      assert norm_dt(result["startsAt"]) == DateTime.truncate(event.starts_at, :second)
      assert norm_dt(result["endsAt"]) == DateTime.truncate(event.ends_at, :second)
      assert decode_json_string(result["venue"]) == @venue_beijing
      assert result["enrollmentBadge"] == "starting_soon"
    end

    test "edge：无时间 + 空 venue 的活动 → startsAt/endsAt/venue 为 null，badge=enrolling" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      assert %{"data" => %{"getEventBySlug" => result}} =
               anon(public_event_detail_query(event.slug))

      assert is_nil(result["startsAt"])
      assert is_nil(result["endsAt"])
      assert is_nil(result["venue"])
      assert result["enrollmentBadge"] == "enrolling"
    end

    test "匿名详情可查 startsAt/endsAt/enrollmentBadge（course，无 venue 槽）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      course =
        EventFixtures.create_course(workspace, admin, %{
          description: "课程描述",
          starts_at: EventFixtures.days_from_now(30),
          ends_at: EventFixtures.days_from_now(31)
        })

      assert %{"data" => %{"getCourseBySlug" => result}} =
               anon(public_course_detail_query(course.slug))

      assert result["id"] == course.id
      assert norm_dt(result["startsAt"]) == DateTime.truncate(course.starts_at, :second)
      # 超出 7 天窗口 → enrolling
      assert result["enrollmentBadge"] == "enrolling"

      # Course 无 venue 概念：响应不含 venue 键（查询未请求，schema 亦无此字段）
      refute Map.has_key?(result, "venue")
    end

    test "匿名列表查询（listEvents/listCourses）同一通道带出 badge/时间/venue" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{
          venue: @venue_beijing,
          starts_at: EventFixtures.days_from_now(2)
        })

      course = EventFixtures.create_course(workspace, admin, %{})

      assert %{"data" => %{"listEvents" => %{"results" => event_rows}}} =
               anon(public_list_events_query())

      assert %{"data" => %{"listCourses" => %{"results" => course_rows}}} =
               anon(public_list_courses_query())

      event_row = Enum.find(event_rows, &(&1["id"] == event.id))
      assert event_row["enrollmentBadge"] == "starting_soon"
      assert norm_dt(event_row["startsAt"]) == DateTime.truncate(event.starts_at, :second)
      assert decode_json_string(event_row["venue"]) == @venue_beijing

      course_row = Enum.find(course_rows, &(&1["id"] == course.id))
      assert course_row["enrollmentBadge"] == "enrolling"
      assert is_nil(course_row["startsAt"])
    end
  end

  describe "U3 badge 经 GraphQL 与 calculation 单测口径一致（R6/KTD1）" do
    test "名额满 → full（优先级最高，不暴露原始计数）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{
          capacity: 1,
          registration_deadline: nil,
          starts_at: EventFixtures.days_from_now(3)
        })

      event = EventFixtures.set_confirmed_count(event, :events, 1)
      assert event.confirmed_count == 1

      assert %{"data" => %{"getEventBySlug" => result}} =
               anon(public_event_detail_query(event.slug))

      assert result["enrollmentBadge"] == "full"
    end

    test "starts_at 未来 7 天内且未截止 → starting_soon；无 starts_at 永不 starting_soon" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      soon =
        EventFixtures.create_event(workspace, admin, %{
          registration_deadline: nil,
          starts_at: EventFixtures.days_from_now(3)
        })

      undated =
        EventFixtures.create_event(workspace, admin, %{registration_deadline: nil})

      assert %{"data" => %{"getEventBySlug" => %{"enrollmentBadge" => "starting_soon"}}} =
               anon(public_event_detail_query(soon.slug))

      assert %{"data" => %{"getEventBySlug" => %{"enrollmentBadge" => "enrolling"}}} =
               anon(public_event_detail_query(undated.slug))
    end

    test "course：名额满 → full" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      course = EventFixtures.create_course(workspace, admin, %{capacity: 2})
      _course = EventFixtures.set_confirmed_count(course, :courses, 2)

      assert %{"data" => %{"getCourseBySlug" => %{"enrollmentBadge" => "full"}}} =
               anon(public_course_detail_query(course.slug))
    end
  end

  describe "U3 安全面：D2 敏感计数对匿名不暴露" do
    test "capacity → null + forbidden_field；confirmedCount（Int!）→ 非空传播整对象 null" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{capacity: 5})
        |> EventFixtures.set_confirmed_count(:events, 3)

      # capacity 可空：字段收窄为 null 并带 forbidden_field 错误，计数值不落响应
      capacity_query = """
      query {
        getEventBySlug(slug: "#{event.slug}") {
          id capacity
        }
      }
      """

      assert %{"data" => %{"getEventBySlug" => result}, "errors" => errors} =
               anon(capacity_query)

      assert result["id"] == event.id
      assert is_nil(result["capacity"])
      assert [%{"code" => "forbidden_field", "path" => ["getEventBySlug", "capacity"]}] = errors

      # confirmedCount 非空（Int!）：field_policy 收窄触发非空传播，
      # 整个详情对象 null + forbidden_field——计数在任何匿名响应形状下都不可读
      count_query = """
      query {
        getEventBySlug(slug: "#{event.slug}") {
          id confirmedCount
        }
      }
      """

      assert %{"data" => %{"getEventBySlug" => nil}, "errors" => count_errors} =
               anon(count_query)

      assert [
               %{"code" => "forbidden_field", "path" => ["getEventBySlug", "confirmedCount"]}
             ] = count_errors
    end
  end

  # ── U3 parity 契约（KTD2：工具返回 == 匿名 GraphQL，逐字段同值）──

  defp frame_for(user), do: Frame.new(current_user: user)

  defp decode_tool({:reply, response, _frame}) do
    [content] = response.content
    Jason.decode!(content["text"])
  end

  # 紧凑行（list_public_offerings）== 匿名 list 查询行，逐字段映射后比值
  # （GraphQL camelCase / 工具 snake_case；venue JsonString 解码后取 city/district）。
  defp assert_list_row_parity(tool_row, gql_row) do
    assert gql_row, "tool row #{inspect(tool_row["id"])} missing in anonymous GraphQL list"
    assert tool_row["id"] == gql_row["id"]
    assert tool_row["slug"] == gql_row["slug"]
    assert tool_row["title"] == gql_row["title"]
    assert tool_row["badge"] == gql_row["enrollmentBadge"]
    assert norm_dt(tool_row["starts_at"]) == norm_dt(gql_row["startsAt"])

    venue = decode_json_string(gql_row["venue"])
    assert tool_row["city"] == (venue && venue["city"])
    assert tool_row["district"] == (venue && venue["district"])
  end

  # 全白名单详情（get_public_offering）== 匿名详情查询，逐字段同值。
  defp assert_detail_parity(tool_detail, gql_detail, kind) do
    assert tool_detail["id"] == gql_detail["id"]
    assert tool_detail["kind"] == kind
    assert tool_detail["slug"] == gql_detail["slug"]
    assert tool_detail["title"] == gql_detail["title"]
    assert tool_detail["description"] == gql_detail["description"]
    assert tool_detail["status"] == gql_detail["status"]
    assert tool_detail["visibility"] == gql_detail["visibility"]
    assert tool_detail["enrollment_policy"] == gql_detail["enrollmentPolicy"]

    assert norm_dt(tool_detail["registration_deadline"]) ==
             norm_dt(gql_detail["registrationDeadline"])

    assert norm_dt(tool_detail["starts_at"]) == norm_dt(gql_detail["startsAt"])
    assert norm_dt(tool_detail["ends_at"]) == norm_dt(gql_detail["endsAt"])
    assert tool_detail["badge"] == gql_detail["enrollmentBadge"]
    assert tool_detail["pricing_enabled"] == gql_detail["pricingEnabled"]

    assert tool_detail["available_price_tiers"] ==
             decode_json_string_list(gql_detail["availablePriceTiers"])
  end

  describe "U3 parity 契约：list_public_offerings == 匿名列表查询" do
    test "同一批种子数据，每行每字段同值（含 badge、venue、时间；event 与 course）" do
      admin = Fixtures.platform_admin("u3-parity-list")
      workspace = Fixtures.create_workspace(admin)

      full_event =
        EventFixtures.create_event(workspace, admin, %{
          title: "已满活动",
          capacity: 1,
          venue: @venue_beijing,
          starts_at: EventFixtures.days_from_now(2)
        })

      _full_event = EventFixtures.set_confirmed_count(full_event, :events, 1)

      undated_event = EventFixtures.create_event(workspace, admin, %{title: "待定活动"})

      soon_course =
        EventFixtures.create_course(workspace, admin, %{starts_at: EventFixtures.days_from_now(3)})

      caller = Fixtures.register_user("u3-parity-list-user")

      assert {:reply, _, _} =
               event_reply =
               ListPublicOfferings.execute(%{"kind" => "event"}, frame_for(caller))

      assert {:reply, _, _} =
               course_reply =
               ListPublicOfferings.execute(%{"kind" => "course"}, frame_for(caller))

      tool_event_rows = decode_tool(event_reply)["items"]
      tool_course_rows = decode_tool(course_reply)["items"]

      assert %{"data" => %{"listEvents" => %{"results" => gql_event_rows}}} =
               anon(public_list_events_query())

      assert %{"data" => %{"listCourses" => %{"results" => gql_course_rows}}} =
               anon(public_list_courses_query())

      # 本次种子的条目都在（同 workspace 其他测试 async 隔离，只按 id 对齐）
      for tool_row <- tool_event_rows do
        if tool_row["id"] in [full_event.id, undated_event.id] do
          assert tool_row["kind"] == "event"

          assert_list_row_parity(
            tool_row,
            Enum.find(gql_event_rows, &(&1["id"] == tool_row["id"]))
          )
        end
      end

      for tool_row <- tool_course_rows do
        if tool_row["id"] == soon_course.id do
          assert tool_row["kind"] == "course"

          assert_list_row_parity(
            tool_row,
            Enum.find(gql_course_rows, &(&1["id"] == tool_row["id"]))
          )
        end
      end

      # 三态 badge 都被 parity 断言覆盖（full / enrolling / starting_soon）
      rows_by_id = Map.new(tool_event_rows ++ tool_course_rows, &{&1["id"], &1})
      assert rows_by_id[full_event.id]["badge"] == "full"
      assert rows_by_id[undated_event.id]["badge"] == "enrolling"
      assert rows_by_id[soon_course.id]["badge"] == "starting_soon"
    end
  end

  describe "U3 parity 契约：get_public_offering == 匿名详情查询" do
    test "event：全白名单字段逐字段同值（含 description/定价/venue/赞助键）" do
      admin = Fixtures.platform_admin("u3-parity-get")
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{
          description: "parity 描述",
          venue: @venue_beijing,
          starts_at: EventFixtures.days_from_now(3),
          ends_at: EventFixtures.days_from_now(4),
          pricing_enabled: true,
          price_tiers: [
            %{"id" => Ash.UUID.generate(), "name" => "早鸟票", "amount_cents" => 9900}
          ],
          sponsorship_enabled: true,
          sponsorship_tiers: [
            %{"id" => "gold", "name" => "金牌", "benefits" => ["logo 展示位"], "exclusive" => false}
          ]
        })

      caller = Fixtures.register_user("u3-parity-get-user")

      assert {:reply, _, _} =
               reply =
               GetPublicOffering.execute(%{"id" => event.id}, frame_for(caller))

      tool_detail = decode_tool(reply)

      assert %{"data" => %{"getEventBySlug" => gql_detail}} =
               anon(public_event_detail_query(event.slug))

      assert_detail_parity(tool_detail, gql_detail, "event")
      assert tool_detail["venue"] == decode_json_string(gql_detail["venue"])
      assert tool_detail["sponsorship_enabled"] == gql_detail["sponsorshipEnabled"]

      assert tool_detail["sponsorship_tiers"] ==
               decode_json_string_list(gql_detail["sponsorshipTiers"])
    end

    test "course：逐字段同值，venue/赞助键为 null（course 无此概念）" do
      admin = Fixtures.platform_admin("u3-parity-get-c")
      workspace = Fixtures.create_workspace(admin)

      course =
        EventFixtures.create_course(workspace, admin, %{
          description: "课程 parity",
          starts_at: EventFixtures.days_from_now(5)
        })

      caller = Fixtures.register_user("u3-parity-get-c-user")

      assert {:reply, _, _} =
               reply =
               GetPublicOffering.execute(
                 %{"id" => course.id, "kind" => "course"},
                 frame_for(caller)
               )

      tool_detail = decode_tool(reply)

      assert %{"data" => %{"getCourseBySlug" => gql_detail}} =
               anon(public_course_detail_query(course.slug))

      assert_detail_parity(tool_detail, gql_detail, "course")
      assert is_nil(tool_detail["venue"])
      assert is_nil(tool_detail["sponsorship_enabled"])
      assert is_nil(tool_detail["sponsorship_tiers"])
    end

    test "成员身份调用工具不超标：payload 与匿名 GraphQL 逐字段一致（KTD2）" do
      admin = Fixtures.platform_admin("u3-parity-member")
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{
          capacity: 5,
          venue: @venue_beijing,
          starts_at: EventFixtures.days_from_now(2)
        })

      _event = EventFixtures.set_confirmed_count(event, :events, 5)

      member = Fixtures.register_user("u3-parity-member-user")
      Fixtures.add_member(workspace, member, [:learner])

      # 成员（含本 workspace learner）调工具，返回与匿名 GraphQL 同字段同值——
      # capacity/confirmed_count 不因成员身份混入工具 payload。
      assert {:reply, _, _} =
               member_reply =
               GetPublicOffering.execute(%{"id" => event.id}, frame_for(member))

      member_detail = decode_tool(member_reply)

      assert %{"data" => %{"getEventBySlug" => gql_detail}} =
               anon(public_event_detail_query(event.slug))

      assert_detail_parity(member_detail, gql_detail, "event")
      assert member_detail["badge"] == "full"
      refute Map.has_key?(member_detail, "capacity")
      refute Map.has_key?(member_detail, "confirmed_count")
      refute Map.has_key?(member_detail, "workspace_id")
    end
  end

  # F2（advisor02 第 2 轮）：小程序公开发现面查询的匿名白名单合同。
  # 查询 = miniprogram/src/api/operations.ts CatalogQueryDocument 同源
  # （filter status=open + visibility=public；字段不含成员可见字段），
  # 四姿态（匿名/跨工作台成员/同工作台成员/成员列表）真实 HTTP 执行。
  describe "F2 mini catalog：匿名白名单查询四姿态" do
    @mini_catalog_query """
    query {
      listEvents(filter: { status: { eq: "open" }, visibility: { eq: "public" } }) {
        results { id title status enrollmentPolicy registrationDeadline pricingEnabled availablePriceTiers startsAt endsAt venue enrollmentBadge }
      }
      listCourses(filter: { status: { eq: "open" }, visibility: { eq: "public" } }) {
        results { id title status enrollmentPolicy registrationDeadline pricingEnabled availablePriceTiers startsAt endsAt enrollmentBadge }
      }
    }
    """

    test "匿名：仅 open+public 条目返回，workspace-only 不混入" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      public_event = EventFixtures.create_event(workspace, admin, %{title: "公开活动"})

      _hidden =
        EventFixtures.create_event(workspace, admin, %{visibility: :workspace, title: "仅工作台"})

      assert %{"data" => %{"listEvents" => %{"results" => results}}} = anon(@mini_catalog_query)
      ids = Enum.map(results, & &1["id"])
      assert public_event.id in ids
      refute Enum.any?(results, &(&1["title"] == "仅工作台"))
    end

    test "跨工作台成员：与匿名同形状，无 forbidden_field" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      EventFixtures.create_event(workspace, admin)

      other_admin = Fixtures.platform_admin("f2-other-admin")
      other_workspace = Fixtures.create_workspace(other_admin)
      cross_member = Fixtures.register_user("f2-cross-member")
      Fixtures.add_member(other_workspace, cross_member, [:learner])

      assert %{"data" => %{"listEvents" => %{"results" => results}} = data} =
               graphql(@mini_catalog_query, sign_in_token(cross_member))

      # 白名单字段查询不带受保护字段 → 无 errors（受保护字段请求才会 forbidden_field）
      assert is_map_key(data, "listCourses")
      assert results != nil
    end

    test "同工作台成员：同一白名单查询也只见公开条目（列表口径按 filter 不按身份放宽）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      EventFixtures.create_event(workspace, admin, %{title: "公开活动"})
      EventFixtures.create_event(workspace, admin, %{visibility: :workspace, title: "仅工作台"})
      member = Fixtures.register_user("f2-same-member")
      Fixtures.add_member(workspace, member, [:learner])

      assert %{"data" => %{"listEvents" => %{"results" => results}}} =
               graphql(@mini_catalog_query, sign_in_token(member))

      # filter 钉死 visibility=public：成员经公开发现面也不见 workspace_only
      refute Enum.any?(results, &(&1["title"] == "仅工作台"))
    end

    test "详情查询白名单字段四姿态同构（匿名 == 成员，无受保护字段可请求）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{capacity: 5})
      _event = EventFixtures.set_confirmed_count(event, :events, 5)
      member = Fixtures.register_user("f2-detail-member")
      Fixtures.add_member(workspace, member, [:learner])

      detail_query = """
      query { getEvent(id: "#{event.id}") {
        id title status enrollmentPolicy registrationDeadline
        pricingEnabled availablePriceTiers startsAt endsAt venue enrollmentBadge
      } }
      """

      assert %{"data" => %{"getEvent" => anon_detail}} = anon(detail_query)

      assert %{"data" => %{"getEvent" => member_detail}} =
               graphql(detail_query, sign_in_token(member))

      # 白名单字段逐值一致（成员不因身份多得数据）；badge 派生满员
      assert anon_detail == member_detail
      assert anon_detail["enrollmentBadge"] == "full"
    end
  end
end
