//! Story 3.11：报名支付 e2e 套件（Fake dev 驱动）。
//! 覆盖免费/收费/押金报名、支付成功/过期/取消/迟到退款、取消报名与我的报名。

use cgc_events::detail::EventDetailService;
use cgc_events::enroll::EnrollmentRequest;
use cgc_events::enrollments::{EnrollmentsApi, FakeEnrollmentsApi};
use cgc_events::list::{EventsApi, FakeEventsApi, ListState, StatusFilter};
use cgc_events::orders::{
    is_terminal_status, qr_code_url, FakeOrderScenario, FakeOrdersApi, OrdersApi,
};
use std::sync::Arc;

fn free_request(event_id: &str, tier: Option<&str>) -> EnrollmentRequest {
    EnrollmentRequest {
        event_id: event_id.to_string(),
        user_id: "u-1".to_string(),
        tier_id: tier.map(str::to_string),
        age_confirmed: false,
    }
}

#[test]
fn free_open_enrollment_confirms() {
    let api = Arc::new(FakeEventsApi::with_seed(8));
    let page = api
        .list_events(None, None, StatusFilter::All, None, 5)
        .expect("step 1: list events");
    assert!(!page.items.is_empty(), "step 1: list should not be empty");
    let event = page
        .items
        .iter()
        .find(|event| !event.pricing_enabled && event.status == "open")
        .expect("step 2: free open event");
    let detail = api
        .get_event(None, &event.id)
        .expect("step 3: event detail");
    assert!(!detail.pricing_enabled, "step 3: should be free");
    let enrollment = api
        .create_enrollment(None, &free_request(&event.id, None))
        .expect("step 4: enroll free open");
    assert_eq!(
        enrollment.status, "confirmed",
        "step 4: open free auto-confirm"
    );
    assert_eq!(
        api.get_my_enrollment(None, &event.id)
            .expect("step 5: my enrollment")
            .map(|enrollment| enrollment.status),
        Some("confirmed".to_string()),
        "step 5: my enrollment persisted"
    );
}

#[test]
fn priced_and_deposit_enrollments_go_payment_pending_and_pay() {
    let api = Arc::new(FakeEventsApi::with_seed(8));
    // 收费场：index=2（pricing_enabled）
    let priced = api
        .get_event(None, "evt-002")
        .expect("step 1: priced detail");
    assert!(priced.pricing_enabled, "step 1: priced target");
    assert!(
        !priced.available_price_tiers.is_empty(),
        "step 1: tier available"
    );
    let enrollment = api
        .create_enrollment(
            None,
            &free_request("evt-002", Some(&priced.available_price_tiers[0].id)),
        )
        .expect("step 2: enroll priced");
    assert_eq!(
        enrollment.status, "payment_pending",
        "step 2: priced pending"
    );

    let orders = FakeOrdersApi::with_scenario(FakeOrderScenario::PaidAfterPolls);
    let order = orders
        .create_order(None, &enrollment.id, "wechat_native", false)
        .expect("step 3: create order");
    assert_eq!(order.status, "pending", "step 3: order pending");
    let credential = order.credential.expect("step 3: credential");
    let url = qr_code_url(&credential).expect("step 3: qr code url");
    assert!(url.starts_with("https://"), "step 3: qr url");
    let first = orders
        .order_status(None, &order.id)
        .expect("step 4: poll 1");
    assert_eq!(first.status, "pending", "step 4: first poll pending");
    let paid = orders
        .order_status(None, &order.id)
        .expect("step 5: poll 2");
    assert_eq!(paid.status, "paid", "step 5: paid after polls");
    assert!(is_terminal_status("paid"), "step 5: terminal");

    // 押金场：index=4（pricing_enabled + deposit）
    let deposit = api
        .get_event(None, "evt-004")
        .expect("step 6: deposit detail");
    assert!(deposit.deposit_enabled, "step 6: deposit enabled");
    assert_eq!(
        deposit.deposit_amount_cents,
        Some(5000),
        "step 6: deposit amount"
    );
    let deposit_enrollment = api
        .create_enrollment(
            None,
            &free_request("evt-004", Some(&deposit.available_price_tiers[0].id)),
        )
        .expect("step 7: enroll deposit");
    assert_eq!(
        deposit_enrollment.status, "payment_pending",
        "step 7: deposit pending"
    );
    let deposit_order = orders
        .create_order(None, &deposit_enrollment.id, "alipay_qr", true)
        .expect("step 8: deposit order");
    assert_eq!(
        deposit_order.amount_cents, 9900,
        "step 8: fake order amount placeholder"
    );
    assert_eq!(
        orders
            .order_status(None, &deposit_order.id)
            .expect("step 9: deposit poll")
            .status,
        "paid",
        "step 9: deposit paid"
    );
}

#[test]
fn terminal_order_states_are_reported() {
    for (scenario, expected) in [
        (FakeOrderScenario::Expired, "expired"),
        (FakeOrderScenario::Cancelled, "cancelled"),
        (FakeOrderScenario::Refunded, "refunded"),
    ] {
        let orders = FakeOrdersApi::with_scenario(scenario);
        let order = orders
            .create_order(None, "enroll-1", "wechat_native", false)
            .expect("step 1: create");
        let status = orders
            .order_status(None, &order.id)
            .expect("step 2: poll")
            .status;
        assert_eq!(status, expected, "step 2: terminal scenario {scenario:?}");
        assert!(is_terminal_status(&status), "step 3: terminal predicate");
    }
}

#[test]
fn cancel_enrollment_and_my_enrollments_list() {
    let api = FakeEventsApi::with_seed(8);
    let enrollment = api
        .create_enrollment(None, &free_request("evt-001", None))
        .expect("step 1: enroll");
    let canceled = api
        .cancel_enrollment(None, &enrollment.id)
        .expect("step 2: cancel");
    assert_eq!(canceled.status, "cancelled", "step 2: cancelled");
    assert_eq!(
        api.get_my_enrollment(None, "evt-001")
            .expect("step 3: read")
            .map(|enrollment| enrollment.status),
        Some("cancelled".to_string()),
        "step 3: persisted cancellation"
    );

    let rows = FakeEnrollmentsApi
        .my_enrollments(None)
        .expect("step 4: my enrollments");
    assert!(
        rows.iter().any(|row| row.status == "confirmed"),
        "step 4: confirmed row"
    );
    assert!(
        rows.iter().any(|row| row.status == "payment_pending"),
        "step 4: pending row"
    );
}

#[test]
fn detail_service_feeds_state_machine() {
    let api = Arc::new(FakeEventsApi::with_seed(8));
    let mut service = EventDetailService::new(api.clone());
    service.begin_load("evt-004");
    let detail = api.get_event(None, "evt-004").expect("step 1: detail");
    service.adopt(detail);
    let state = service.state();
    assert!(!matches!(state, ListState::Loading));
    assert!(
        service.detail().expect("step 2: detail").deposit_enabled,
        "step 2: deposit detail available to UI"
    );
}
