defmodule Cgc2046Web.ErrorCodeContractTest do
  @moduledoc """
  业务错误 code 契约钉测（i18n Phase 0，plan 2026-08-18-001）。

  GraphQL mutation 的业务错误（domain 主动构造）必须携带稳定 code
  （`<resource>_<reason>` snake_case），前端（web/lib/payment-errors.ts、
  miniprogram/src/domain/error-copy.ts）按 code 精确查中文文案——
  本文件钉住三条主链路场景的 code 值 + 全量 code 命名规范。
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures

  @order_tier_id Ecto.UUID.generate()
  @order_tier %{"id" => @order_tier_id, "name" => "早鸟", "amount_cents" => 9900}

  @sponsor_tier %{
    "id" => "9d2f7c80-0000-4000-8000-0000000000cd",
    "name" => "冠名",
    "amount_suggestion" => 10_000,
    "benefits" => ["logo 展示位"],
    "exclusive" => true
  }

  describe "主链路场景 code 契约" do
    test "createEnrollment 重复活跃报名 → enrollment_duplicate_active" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{enrollment_policy: :open})
      learner = Fixtures.register_user("code-enroll-dup")
      token = sign_in_token(learner)

      assert %{"data" => %{"createEnrollment" => %{"result" => %{}, "errors" => []}}} =
               graphql(create_enrollment_mutation(event, learner), token)

      duplicate =
        graphql(create_enrollment_mutation(event, learner), token)

      assert %{
               "data" => %{
                 "createEnrollment" => %{"result" => nil, "errors" => [error | _]}
               }
             } = duplicate

      assert error["code"] == "enrollment_duplicate_active",
             "重复活跃报名 code 应为 enrollment_duplicate_active，实际 #{inspect(error)}"
    end

    test "cancelOrder 对已取消订单再取消 → order_already_processed" do
      %{learner: learner, enrollment_id: enrollment_id} = paid_enrollment()
      token = sign_in_token(learner)

      assert %{"data" => %{"createOrder" => %{"result" => %{"id" => order_id}}}} =
               graphql(order_mutation(enrollment_id), token)

      assert %{"data" => %{"cancelOrder" => %{"result" => %{"status" => "cancelled"}}}} =
               graphql(cancel_mutation(order_id), token)

      assert %{"data" => %{"cancelOrder" => %{"result" => nil, "errors" => [error | _]}}} =
               graphql(cancel_mutation(order_id), token)

      assert error["code"] == "order_already_processed",
             "已处理订单再操作 code 应为 order_already_processed，实际 #{inspect(error)}"
    end

    test "createOrder 对已有活跃订单的报名再下单 → order_duplicate_active（F1）" do
      %{learner: learner, enrollment_id: enrollment_id} = paid_enrollment()
      token = sign_in_token(learner)

      # 第一笔 pending 单占据 unique_active_order 部分索引
      assert %{"data" => %{"createOrder" => %{"result" => %{"id" => _}}}} =
               graphql(order_mutation(enrollment_id), token)

      # 再下单：无显式预检查，唯一防线 DB 索引 → error_handler 转 code
      assert %{"data" => %{"createOrder" => %{"result" => nil, "errors" => [error | _]}}} =
               graphql(order_mutation(enrollment_id), token)

      assert error["code"] == "order_duplicate_active",
             "已有活跃订单再下单 code 应为 order_duplicate_active，实际 #{inspect(error)}"

      assert error["message"] == "an active order already exists for this enrollment"
    end

    test "createOrder 对已确认报名下单 → order_not_payment_pending" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)
      learner = Fixtures.register_user("code-order-not-pending")
      token = sign_in_token(learner)

      # 免费 open 报名 → confirmed（非 payment_pending）
      assert %{"data" => %{"createEnrollment" => %{"result" => %{"id" => enrollment_id}}}} =
               graphql(create_enrollment_mutation(event, learner), token)

      assert %{"data" => %{"createOrder" => %{"result" => nil, "errors" => [error | _]}}} =
               graphql(order_mutation(enrollment_id), token)

      assert error["code"] == "order_not_payment_pending",
             "已确认报名下单 code 应为 order_not_payment_pending，实际 #{inspect(error)}"
    end

    test "approveSponsorship 对已 active 赞助再审批 → sponsorship_already_processed" do
      admin = Fixtures.platform_admin("code-sponsor-admin")
      workspace = Fixtures.create_workspace(admin, %{sponsorship_tiers: [@sponsor_tier]})
      owner = Fixtures.register_user("code-sponsor-owner")
      Fixtures.add_member(workspace, owner, [:owner])
      event = EventFixtures.create_event(workspace, owner, %{sponsorship_tiers: [@sponsor_tier]})
      sponsor = Fixtures.register_user("code-sponsor-sponsor")
      owner_token = sign_in_token(owner)
      sponsor_token = sign_in_token(sponsor)

      assert %{"data" => %{"createSponsorship" => %{"result" => %{"id" => sponsorship_id}}}} =
               graphql(create_sponsorship_mutation(event, sponsor), sponsor_token)

      assert %{"data" => %{"approveSponsorship" => %{"result" => %{"status" => "active"}}}} =
               graphql(approve_mutation(sponsorship_id), owner_token)

      assert %{
               "data" => %{
                 "approveSponsorship" => %{"result" => nil, "errors" => [error | _]}
               }
             } = graphql(approve_mutation(sponsorship_id), owner_token)

      assert error["code"] == "sponsorship_already_processed",
             "重复审批赞助 code 应为 sponsorship_already_processed，实际 #{inspect(error)}"
    end
  end

  describe "code 命名规范" do
    test "全部业务 code 匹配 <resource>_<reason> snake_case 规范" do
      codes = [
        # enrollment（enrollment.ex domain_error_code）
        "enrollment_exactly_one_target_required",
        "enrollment_target_not_open_or_registration_closed",
        "enrollment_target_tenant_mismatch",
        "enrollment_capacity_full_or_registration_closed",
        "enrollment_invite_code_required",
        "enrollment_invite_quota_unavailable",
        "enrollment_tier_id_required",
        "enrollment_tier_not_available",
        "enrollment_already_processed",
        "enrollment_unknown_enrollment_policy",
        "enrollment_not_expired_pending",
        "enrollment_not_payment_pending",
        "enrollment_capacity_counter_invalid",
        "enrollment_duplicate_active",
        # order（order.ex）
        "order_enrollment_required",
        "order_enrollment_not_found",
        "order_target_tenant_mismatch",
        "order_already_processed",
        "order_provider_not_configured",
        "order_not_payment_pending",
        "order_duplicate_active",
        # speaker_invitation（speaker_invitation.ex）
        "speaker_invitation_duplicate_invitation",
        "speaker_invitation_invalid_or_expired_token",
        "speaker_invitation_forbidden",
        "speaker_invitation_event_not_found",
        "speaker_invitation_event_not_open",
        "speaker_invitation_target_tenant_mismatch",
        "speaker_invitation_speaker_name_required",
        "speaker_invitation_invitation_id_unavailable",
        "speaker_invitation_materials_required",
        "speaker_invitation_not_accepted",
        "speaker_invitation_workflow_run_not_found",
        "speaker_invitation_materials_save_failed",
        "speaker_invitation_invitation_not_found",
        "speaker_invitation_workflow_run_failed",
        # sponsorship（sponsorship.ex）
        "sponsorship_event_id_required",
        "sponsorship_target_workspace_required",
        "sponsorship_level_required",
        "sponsorship_unknown_level",
        "sponsorship_sponsorship_not_open",
        "sponsorship_target_tenant_mismatch",
        "sponsorship_tier_not_found",
        "sponsorship_already_sponsoring",
        "sponsorship_already_processed",
        "sponsorship_approval_deadline_passed",
        "sponsorship_exclusive_slot_taken",
        "sponsorship_target_sponsorship_closed",
        "sponsorship_not_expired_pending",
        "sponsorship_not_active_event_sponsorship",
        "sponsorship_exactly_one_target_required",
        # sponsorship_delivery（sponsorship_delivery.ex）
        "sponsorship_delivery_already_fulfilled",
        # membership（membership_context.ex，决策 2026-08-18 Q1=A）
        "membership_already_exists",
        "membership_check_failed",
        # join_request（validate_workspace_join_policy.ex，#206）
        "join_request_invite_only",
        "join_request_open",
        "join_request_not_found",
        # {:database, _} 统一 code（六文件共用）
        "database_error"
      ]

      for code <- codes do
        assert Regex.match?(~r/^[a-z]+(_[a-z0-9]+)+$/, code),
               "code #{inspect(code)} 不符合 <resource>_<reason> snake_case 规范"
      end
    end
  end

  # ── 布置 ──

  defp paid_enrollment do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)

    event =
      EventFixtures.create_event(workspace, admin, %{
        pricing_enabled: true,
        price_tiers: [@order_tier]
      })

    learner = Fixtures.register_user("code-order-learner")

    {:ok, enrollment} =
      Cgc2046.Events.Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{
        event_id: event.id,
        user_id: learner.id,
        tier_id: @order_tier_id
      })
      |> Ash.create(tenant: event.workspace_id, actor: learner)

    %{learner: learner, enrollment_id: enrollment.id}
  end

  defp create_enrollment_mutation(event, user) do
    """
    mutation {
      createEnrollment(input: {eventId: "#{event.id}", userId: "#{user.id}"}) {
        result { id status }
        errors { message code }
      }
    }
    """
  end

  defp order_mutation(enrollment_id) do
    """
    mutation {
      createOrder(input: {enrollmentId: "#{enrollment_id}", provider: "wechat_native"}) {
        result { id status }
        errors { message code }
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
        errors { message code }
      }
    }
    """
  end

  defp create_sponsorship_mutation(event, sponsor) do
    """
    mutation {
      createSponsorship(input: {
        level: "event"
        eventId: "#{event.id}"
        sponsorUserId: "#{sponsor.id}"
        companyName: "Acme 冠名"
        contactEmail: "#{sponsor.email}"
        tierId: "#{@sponsor_tier["id"]}"
        amount: 10000
      }) {
        result { id status }
        errors { message code }
      }
    }
    """
  end

  defp approve_mutation(sponsorship_id) do
    """
    mutation {
      approveSponsorship(id: "#{sponsorship_id}") {
        result { id status }
        errors { message code }
      }
    }
    """
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
