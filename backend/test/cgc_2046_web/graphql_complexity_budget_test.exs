defmodule Cgc2046Web.GraphqlComplexityBudgetTest do
  @moduledoc """
  #297.1 预算回归钉：最重的**第一方** GraphQL 文档必须低于 max_complexity。

  起因（2026-09-15 生产事故）：预算 1_000 依据「现网最大 ~600（inviteBatches）」
  设定，但漏测了小程序端两个文档——发现页 Catalog（first=50，实测 1350）与
  我的报名 MyEnrollments（first=100，约 1_4xx），线上小程序两个页签全部
  `Operation … is too complex` 拒绝。已发布客户端无法自救（改文档要发版），
  只能由后端预算兜底。

  本测试把这两个最重文档（文档属主 `miniprogram/src/api/operations.ts`，
  改那边时**必须**回来同步这里）钉在预算之下：文档增长撞线时这里先红，
  迫使有意识地调预算而不是把线上客户端打挂。
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures

  # ── miniprogram/src/api/operations.ts 的 CatalogQueryDocument（first=50）──
  # 两份连接各 10/11 字段；real.ts 固定 first: 50。
  @catalog_doc """
  query Catalog($first: Int) {
    listEvents(first: $first, filter: { status: { eq: "open" }, visibility: { eq: "public" } }) {
      results {
        id
        title
        status
        enrollmentPolicy
        registrationDeadline
        pricingEnabled
        availablePriceTiers
        startsAt
        endsAt
        venue
        enrollmentBadge
      }
    }
    listCourses(first: $first, filter: { status: { eq: "open" }, visibility: { eq: "public" } }) {
      results {
        id
        title
        status
        enrollmentPolicy
        registrationDeadline
        pricingEnabled
        availablePriceTiers
        startsAt
        endsAt
        enrollmentBadge
      }
    }
  }
  """

  # ── MyEnrollmentsQueryDocument（first=100，real.ts 的我的报名加载）──
  # 13 字段 × 100 → 全库最重的第一方文档。
  @my_enrollments_doc """
  query MyEnrollments($userId: ID!, $first: Int) {
    enrollments(first: $first, filter: { userId: { eq: $userId } }) {
      results {
        id
        workspaceId
        eventId
        courseId
        userId
        status
        targetTitle
        approvalDeadline
        rejectionReason
        approvedAt
        expiredAt
        cancelledAt
        insertedAt
      }
    }
  }
  """

  test "发现页 Catalog（first=50）不被复杂度上限拒绝" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{
        "query" => @catalog_doc,
        "variables" => %{"first" => 50}
      })

    body = json_response(conn, 200)

    refute Enum.any?(body["errors"] || [], &String.contains?(&1["message"] || "", "too complex")),
           "Catalog 撞复杂度上限：#{inspect(body["errors"])}"

    assert %{"listEvents" => _, "listCourses" => _} = body["data"]
  end

  test "我的报名 MyEnrollments（first=100）不被复杂度上限拒绝" do
    user = Fixtures.register_user("complexity-budget")

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token_for(user)}")
      |> post("/api/graphql", %{
        "query" => @my_enrollments_doc,
        "variables" => %{"userId" => user.id, "first" => 100}
      })

    body = json_response(conn, 200)

    refute Enum.any?(body["errors"] || [], &String.contains?(&1["message"] || "", "too complex")),
           "MyEnrollments 撞复杂度上限：#{inspect(body["errors"])}"

    assert %{"enrollments" => _} = body["data"]
  end

  defp token_for(user) do
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
end
