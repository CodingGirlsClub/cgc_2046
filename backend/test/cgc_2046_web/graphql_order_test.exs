defmodule Cgc2046Web.GraphqlOrderTest do
  @moduledoc """
  U5：下单链路 GraphQL（R6/R11/R12/R13）。

  - createEnrollment 收费目标带 tierId（KTD9：收费必填；过期档拒绝，R2）。
  - createOrder：payment_pending 报名 → pending 订单 + 渠道凭据 + 快照 + expire_at
    = min(下单+2h, registration_deadline)（R3/R6）。
  - replaceProvider 换渠道：旧单 cancelled + 新单新 out_trade_no（R11）。
  - cancelOrder：pending 单作废，报名保持 payment_pending 可再下单（R12）。
  - orderStatus/myOrders 只暴露本人订单（R14 轮询面）。
  - 渠道下单失败零订单残留。
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Payments.Order
  alias Cgc2046.Payments.Providers.Fake

  @tier_id "11111111-1111-1111-1111-111111111111"

  describe "createEnrollment 收费目标带 tierId（KTD9/R2）" do
    test "收费报名缺 tierId 被拒；有效 tierId 落 submission_payload（域面读取，输出类型不暴露）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = paid_event(workspace, admin)
      learner = Fixtures.register_user("order-tier-required")

      response = graphql(enroll_mutation(event, learner, nil), sign_in_token(learner))
      assert [%{"message" => message} | _] = gql_errors(response)
      assert message =~ "tier"

      response = graphql(enroll_mutation(event, learner, @tier_id), sign_in_token(learner))

      assert %{"data" => %{"createEnrollment" => %{"result" => result, "errors" => []}}} =
               response

      assert result["status"] == "payment_pending"

      # tier_id 持久化在 submission_payload（GraphQL 输出类型不暴露报名表单负载，
      # 既有隐私面不动；域面读取校验）
      enrollment =
        Ash.get!(Cgc2046.Admission.Enrollment, result["id"],
          authorize?: false,
          tenant: workspace.id
        )

      assert enrollment.submission_payload["tier_id"] == @tier_id
    end

    test "过期档位报名被拒（R2：全部过期收费开启）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{
          pricing_enabled: true,
          price_tiers: [
            %{
              "id" => @tier_id,
              "name" => "早鸟",
              "amount_cents" => 9900,
              "available_until" =>
                DateTime.add(DateTime.utc_now(), -1, :day) |> DateTime.to_iso8601()
            }
          ]
        })

      learner = Fixtures.register_user("order-tier-expired")
      response = graphql(enroll_mutation(event, learner, @tier_id), sign_in_token(learner))
      assert [%{"message" => message} | _] = gql_errors(response)
      assert message =~ "tier"
    end
  end

  describe "createOrder（R3/R6/R13）" do
    setup :paid_enrollment

    test "下单成功：pending 订单 + 凭据 + 快照金额 + expire_at=min 规则", ctx do
      response =
        graphql(order_mutation(ctx.enrollment_id, "wechat_native"), sign_in_token(ctx.learner))

      assert %{"data" => %{"createOrder" => %{"result" => order, "errors" => []}}} = response
      assert order["status"] == "pending"
      assert order["amountCents"] == 9900
      assert Jason.decode!(order["tierSnapshot"])["id"] == @tier_id
      assert order["outTradeNo"] =~ ~r/^CGC/
      # 微信 APIv3 out_trade_no 上限 32 字符（2026-08-24 生产实证：35 字符必
      # 400 PARAM_ERROR）；支付宝 64——按更严渠道约束
      assert String.length(order["outTradeNo"]) <= 32

      # 无 deadline 场景：expire_at ≈ now + 2h
      expire_at = DateTime.from_iso8601(order["expireAt"]) |> elem(1)
      two_hours_later = DateTime.add(DateTime.utc_now(), 2 * 3600)
      assert DateTime.diff(expire_at, two_hours_later) |> abs() < 5
    end

    test "deadline 近于 2h：expire_at = registration_deadline", ctx do
      deadline = DateTime.add(DateTime.utc_now(), 30, :minute)

      event =
        EventFixtures.create_event(
          ctx.workspace,
          ctx.admin,
          %{
            registration_deadline: deadline
          }
          |> Map.merge(paid_attrs())
        )

      learner = Fixtures.register_user("order-deadline-near")
      {:ok, enrollment} = paid_enrollment_for(event, learner)

      response = graphql(order_mutation(enrollment.id, "alipay_page"), sign_in_token(learner))

      assert %{"data" => %{"createOrder" => %{"result" => order, "errors" => []}}} = response
      expire_at = DateTime.from_iso8601(order["expireAt"]) |> elem(1)
      assert DateTime.diff(expire_at, deadline) |> abs() < 5
    end

    test "非 payment_pending 报名下单被拒（免费 confirmed / 审批 pending）", ctx do
      # 免费活动报名 → confirmed
      free_event = EventFixtures.create_event(ctx.workspace, ctx.admin)
      learner2 = Fixtures.register_user("order-free-confirmed")
      {:ok, free} = create_enrollment(free_event, learner2)

      response = graphql(order_mutation(free.id, "wechat_native"), sign_in_token(learner2))
      assert [%{"message" => message} | _] = gql_errors(response)
      assert message =~ "payment"

      # request 审批 pending
      request_event =
        EventFixtures.create_event(ctx.workspace, ctx.admin, %{enrollment_policy: :request})

      learner3 = Fixtures.register_user("order-request-pending")
      {:ok, pending} = create_enrollment(request_event, learner3)

      response = graphql(order_mutation(pending.id, "wechat_native"), sign_in_token(learner3))
      assert [%{"message" => _}] = gql_errors(response)
    end

    test "非本人报名下单 403（forbidden 语义不泄露存在性）", ctx do
      other = Fixtures.register_user("order-not-enrollee")

      response = graphql(order_mutation(ctx.enrollment_id, "wechat_native"), sign_in_token(other))
      assert [%{"message" => _}] = gql_errors(response)
      assert Order |> list_orders(ctx.enrollment_id) |> Enum.empty?()
    end

    test "渠道下单失败零订单残留（无凭据无订单）", ctx do
      Fake.script!(create_payment: {:error, :channel_down})

      response =
        graphql(order_mutation(ctx.enrollment_id, "wechat_native"), sign_in_token(ctx.learner))

      assert [%{"message" => _}] = gql_errors(response)
      assert Order |> list_orders(ctx.enrollment_id) |> Enum.empty?()
    after
      Fake.reset!()
    end
  end

  describe "押金场 createOrder（U2/KTD1：金额源 = 押金快照）" do
    test "押金报名 order-pay 端到端：deposit 单 + 押金金额 + 渠道凭据" do
      %{enrollment_id: enrollment_id, token: token} = deposit_enrollment("e2e")

      assert %{
               "data" => %{
                 "createOrder" => %{
                   "result" => order,
                   "errors" => [],
                   "metadata" => %{"credential" => credential}
                 }
               }
             } = graphql(order_mutation(enrollment_id, "wechat_native", true), token)

      assert order["orderKind"] == "deposit"
      assert order["status"] == "pending"
      assert order["amountCents"] == 6900
      assert order["outTradeNo"] =~ ~r/^CGC/

      assert Jason.decode!(order["tierSnapshot"]) == %{
               "name" => "押金",
               "amount_cents" => 6900
             }

      # order-pay 页拉起支付所需的渠道凭据随单号回出（Fake 回显 out_trade_no）
      assert %{"out_trade_no" => out_trade_no} = Jason.decode!(credential)
      assert out_trade_no == order["outTradeNo"]
    end
  end

  # 押金同意门下沉（#727）：押金单必须显式 deposit_consent: true；判据是后端
  # order_kind/2，非押金单忽略该参数；拒单零副作用（不废旧单、不调渠道）。
  describe "押金同意门（#727）" do
    test "押金单缺 consent → order_deposit_consent_required，零订单且未调渠道" do
      %{enrollment_id: enrollment_id, token: token} = deposit_enrollment("no-consent")

      # 渠道被调即失败（script 成错误）：断言返回的是同意门错误码而非 channel 错误
      Fake.script!(create_payment: {:error, :channel_down})

      assert %{
               "data" => %{
                 "createOrder" => %{"result" => nil, "errors" => [error | _]}
               }
             } = graphql(order_mutation(enrollment_id, "wechat_native"), token)

      assert error["code"] == "order_deposit_consent_required"
      assert error["message"] =~ "deposit consent"
      assert Order |> list_orders(enrollment_id) |> Enum.empty?()
    after
      Fake.reset!()
    end

    test "押金单显式 consent: false → 同样拒（false ≠ 同意）" do
      %{enrollment_id: enrollment_id, token: token} = deposit_enrollment("false-consent")

      assert %{"data" => %{"createOrder" => %{"result" => nil, "errors" => [error | _]}}} =
               graphql(order_mutation(enrollment_id, "wechat_native", false), token)

      assert error["code"] == "order_deposit_consent_required"
      assert Order |> list_orders(enrollment_id) |> Enum.empty?()
    end

    test "拒单零副作用：不新增订单，已有 pending 押金单原样存活" do
      %{enrollment_id: enrollment_id, token: token} = deposit_enrollment("keep-pending")

      assert %{"data" => %{"createOrder" => %{"result" => %{"id" => order_id}}}} =
               graphql(order_mutation(enrollment_id, "wechat_native", true), token)

      # 老客户端重进支付页（不带 consent）：拒单，已有单必须原样存活
      # （门在废旧单/渠道下单之前 + 事务回滚双保险）
      assert %{"data" => %{"createOrder" => %{"errors" => [error | _]}}} =
               graphql(order_mutation(enrollment_id, "wechat_native"), token)

      assert error["code"] == "order_deposit_consent_required"
      assert [%Order{id: ^order_id, status: :pending}] = Order |> list_orders(enrollment_id)
    end

    test "非押金单忽略参数：不带 consent 与显式 false 都正常下单" do
      %{learner: learner, enrollment_id: enrollment_id} = paid_enrollment(%{})
      token = sign_in_token(learner)

      assert %{"data" => %{"createOrder" => %{"result" => %{"id" => first_id}, "errors" => []}}} =
               graphql(order_mutation(enrollment_id, "wechat_native"), token)

      assert %{"data" => %{"createOrder" => %{"result" => %{"id" => second_id}, "errors" => []}}} =
               graphql(order_mutation(enrollment_id, "alipay_page", false), token)

      assert first_id != second_id
    end

    test "越权不变：他人报名带 consent: true 仍被拒且零订单" do
      %{enrollment_id: enrollment_id} = deposit_enrollment("not-enrollee")
      other = Fixtures.register_user("order-deposit-other")

      assert [%{"message" => _} | _] =
               gql_errors(
                 graphql(
                   order_mutation(enrollment_id, "wechat_native", true),
                   sign_in_token(other)
                 )
               )

      assert Order |> list_orders(enrollment_id) |> Enum.empty?()
    end

    test "换渠道边界：押金单 replaceProvider 不要求 consent（继承旧单承诺）" do
      %{enrollment_id: enrollment_id, token: token} = deposit_enrollment("replace")

      assert %{"data" => %{"createOrder" => %{"result" => first}}} =
               graphql(order_mutation(enrollment_id, "wechat_native", true), token)

      assert %{"data" => %{"replaceProvider" => %{"result" => second, "errors" => []}}} =
               graphql(replace_mutation(first["id"], "alipay_page"), token)

      assert second["status"] == "pending"
      assert second["provider"] == "alipay_page"
    end
  end

  describe "replaceProvider 换渠道（R11）" do
    setup :paid_enrollment

    test "旧单 cancelled + 新单 pending 新 out_trade_no；再换旧单被拒", ctx do
      token = sign_in_token(ctx.learner)

      assert %{"data" => %{"createOrder" => %{"result" => first}}} =
               graphql(order_mutation(ctx.enrollment_id, "wechat_native"), token)

      assert %{"data" => %{"replaceProvider" => %{"result" => second, "errors" => []}}} =
               graphql(replace_mutation(first["id"], "alipay_page"), token)

      assert second["status"] == "pending"
      assert second["provider"] == "alipay_page"
      assert second["outTradeNo"] != first["outTradeNo"]

      [old, new] =
        Order
        |> list_orders(ctx.enrollment_id)
        |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})

      assert old.status == :cancelled
      assert new.status == :pending

      # 已 cancelled 的旧单不可再换
      assert [%{"message" => _}] =
               gql_errors(graphql(replace_mutation(first["id"], "alipay_wap"), token))
    end
  end

  describe "cancelOrder + 轮询面（R12/R14）" do
    setup :paid_enrollment

    test "取消 pending 单：报名保持 payment_pending，可再下单", ctx do
      token = sign_in_token(ctx.learner)

      assert %{"data" => %{"createOrder" => %{"result" => first}}} =
               graphql(order_mutation(ctx.enrollment_id, "wechat_native"), token)

      assert %{"data" => %{"cancelOrder" => %{"result" => cancelled, "errors" => []}}} =
               graphql(cancel_mutation(first["id"]), token)

      assert cancelled["status"] == "cancelled"

      enrollment = get_enrollment(ctx.enrollment_id)
      assert enrollment.status == :payment_pending

      # 可再下单（部分唯一索引只锁非终态）
      assert %{"data" => %{"createOrder" => %{"errors" => []}}} =
               graphql(order_mutation(ctx.enrollment_id, "alipay_wap"), token)
    end

    test "orderStatus 轮询只暴露本人订单；他人查询 not_found", ctx do
      token = sign_in_token(ctx.learner)

      assert %{"data" => %{"createOrder" => %{"result" => order}}} =
               graphql(order_mutation(ctx.enrollment_id, "wechat_native"), token)

      assert %{"data" => %{"orderStatus" => %{"id" => id, "status" => "pending"}}} =
               graphql(status_query(order["id"]), token)

      assert id == order["id"]

      # 他人查询：策略过滤隐藏记录 → null（not_found 语义，不泄露存在性）
      other = Fixtures.register_user("order-status-other")

      assert %{"data" => %{"orderStatus" => nil}} =
               graphql(status_query(order["id"]), sign_in_token(other))
    end

    test "myOrders 只列本人订单", ctx do
      token = sign_in_token(ctx.learner)

      assert %{"data" => %{"createOrder" => %{"result" => _}}} =
               graphql(order_mutation(ctx.enrollment_id, "wechat_native"), token)

      assert %{"data" => %{"myOrders" => %{"results" => results}}} =
               graphql(my_orders_query(), token)

      assert length(results) == 1

      other = Fixtures.register_user("order-my-other")

      assert %{"data" => %{"myOrders" => %{"results" => []}}} =
               graphql(my_orders_query(), sign_in_token(other))
    end
  end

  # ── 布置 ──

  defp paid_attrs do
    %{
      pricing_enabled: true,
      price_tiers: [%{"id" => @tier_id, "name" => "早鸟", "amount_cents" => 9900}]
    }
  end

  defp paid_event(workspace, admin, extra \\ %{}) do
    EventFixtures.create_event(workspace, admin, Map.merge(extra, paid_attrs()))
  end

  defp paid_enrollment(_ctx) do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    event = paid_event(workspace, admin)
    learner = Fixtures.register_user("order-learner")
    {:ok, enrollment} = paid_enrollment_for(event, learner)

    %{
      admin: admin,
      workspace: workspace,
      learner: learner,
      enrollment_id: enrollment.id
    }
  end

  defp paid_enrollment_for(event, learner) do
    Cgc2046.Admission.Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, %{
      event_id: event.id,
      user_id: learner.id,
      tier_id: @tier_id
    })
    |> Ash.create(tenant: event.workspace_id, actor: learner)
  end

  # 押金场 + payment_pending 报名（无 tierId：档位只属于定价态），押金同意门用例共用
  defp deposit_enrollment(tag) do
    admin = Fixtures.platform_admin("order-deposit-admin-#{tag}")
    workspace = Fixtures.create_workspace(admin)

    event =
      EventFixtures.create_event(workspace, admin, %{
        deposit_enabled: true,
        deposit_amount_cents: 6900,
        ends_at: EventFixtures.days_from_now(8)
      })

    learner = Fixtures.register_user("order-deposit-learner-#{tag}")
    token = sign_in_token(learner)

    assert %{
             "data" => %{
               "createEnrollment" => %{
                 "result" => %{"id" => enrollment_id, "status" => "payment_pending"},
                 "errors" => []
               }
             }
           } = graphql(enroll_mutation(event, learner, nil), token)

    %{
      admin: admin,
      workspace: workspace,
      event: event,
      learner: learner,
      token: token,
      enrollment_id: enrollment_id
    }
  end

  defp create_enrollment(event, user) do
    Cgc2046.Admission.Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, %{event_id: event.id, user_id: user.id})
    |> Ash.create(tenant: event.workspace_id, actor: user)
  end

  defp get_enrollment(id) do
    Ash.get!(Cgc2046.Admission.Enrollment, id, authorize?: false)
  end

  defp list_orders(Order, enrollment_id) do
    require Ash.Query

    Order
    |> Ash.Query.filter(enrollment_id == ^enrollment_id)
    |> Ash.read!(authorize?: false)
  end

  defp enroll_mutation(event, user, tier_id) do
    tier_input = if tier_id, do: ", tierId: \"#{tier_id}\"", else: ""

    """
    mutation {
      createEnrollment(input: {eventId: "#{event.id}", userId: "#{user.id}"#{tier_input}}) {
        result { id status }
        errors { message }
      }
    }
    """
  end

  # deposit_consent 三态：nil = 不带字段（老客户端/非押金路径）/ true / false
  defp order_mutation(enrollment_id, provider, deposit_consent \\ nil) do
    consent_input =
      case deposit_consent do
        nil -> ""
        value -> ", depositConsent: #{value}"
      end

    """
    mutation {
      createOrder(input: {enrollmentId: "#{enrollment_id}", provider: "#{provider}"#{consent_input}}) {
        result { id orderKind status provider outTradeNo amountCents tierSnapshot expireAt }
        errors { message code }
        metadata { credential }
      }
    }
    """
  end

  defp replace_mutation(order_id, provider) do
    """
    mutation {
      replaceProvider(input: {orderId: "#{order_id}", provider: "#{provider}"}) {
        result { id status provider outTradeNo }
        errors { message }
        metadata { credential }
      }
    }
    """
  end

  defp cancel_mutation(order_id) do
    """
    mutation {
      cancelOrder(id: "#{order_id}") {
        result { id status }
        errors { message }
      }
    }
    """
  end

  defp status_query(order_id) do
    """
    { orderStatus(id: "#{order_id}") { id status expireAt } }
    """
  end

  defp my_orders_query do
    """
    { myOrders { results { id status provider amountCents } } }
    """
  end

  defp gql_errors(response) do
    case response do
      %{"data" => %{"createOrder" => %{"errors" => errors}}} -> errors
      %{"data" => %{"createEnrollment" => %{"errors" => errors}}} -> errors
      %{"data" => %{"replaceProvider" => %{"errors" => errors}}} -> errors
      %{"data" => %{"cancelOrder" => %{"errors" => errors}}} -> errors
      %{"errors" => errors} -> errors
      _ -> []
    end
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

  defp graphql(query, token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end
end
