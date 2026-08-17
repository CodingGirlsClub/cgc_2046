defmodule Cgc2046Web.GraphqlPublicOfferingTest do
  @moduledoc """
  E-5 #50 G5：getEventBySlug / getCourseBySlug 公开宿主页查询三态。

  - 匿名对 `open + public` → 返回详情（公开发现面）
  - 匿名/非成员登录对 workspace-only / 非 open → null（404 语义，不泄露存在性）
  - 成员登录对 workspace-only → 返回（成员可读非 draft）
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures

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
      signIn(email: "#{user.email}", password: "#{Fixtures.password()}") { id }
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
end
