//! 场次详情（story 3.2）：三态（免费/收费/押金）分类与详情加载状态机。

use std::sync::Arc;

use serde_json::Value;

use crate::list::{EventSummary, EventsApi, EventsError, ListState};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PriceTier {
    pub id: String,
    pub name: String,
    pub amount_cents: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EventDetail {
    pub id: String,
    pub title: String,
    pub description: Option<String>,
    pub status: String,
    pub visibility: String,
    pub enrollment_policy: String,
    pub capacity: Option<i64>,
    pub confirmed_count: Option<i64>,
    pub enrollment_badge: Option<String>,
    pub registration_deadline: Option<String>,
    pub starts_at: Option<String>,
    pub ends_at: Option<String>,
    pub venue: Option<String>,
    pub pricing_enabled: bool,
    pub available_price_tiers: Vec<PriceTier>,
    pub deposit_enabled: bool,
    pub deposit_amount_cents: Option<i64>,
}

/// 三态（R2）：押金优先于收费；收费需要有可售档位，否则按免费展示。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PriceMode {
    Free,
    Paid { min_amount_cents: i64, tiers: usize },
    Deposit { amount_cents: i64 },
}

impl EventDetail {
    pub fn price_mode(&self) -> PriceMode {
        if self.deposit_enabled && self.deposit_amount_cents.unwrap_or(0) > 0 {
            PriceMode::Deposit {
                amount_cents: self.deposit_amount_cents.unwrap_or(0),
            }
        } else if self.pricing_enabled && !self.available_price_tiers.is_empty() {
            PriceMode::Paid {
                min_amount_cents: self
                    .available_price_tiers
                    .iter()
                    .map(|tier| tier.amount_cents)
                    .min()
                    .unwrap_or(0),
                tiers: self.available_price_tiers.len(),
            }
        } else {
            PriceMode::Free
        }
    }

    pub fn from_summary(summary: &EventSummary) -> Self {
        Self {
            id: summary.id.clone(),
            title: summary.title.clone(),
            description: None,
            status: summary.status.clone(),
            visibility: summary.visibility.clone(),
            enrollment_policy: summary.enrollment_policy.clone(),
            capacity: summary.capacity,
            confirmed_count: summary.confirmed_count,
            enrollment_badge: summary.enrollment_badge.clone(),
            registration_deadline: summary.registration_deadline.clone(),
            starts_at: summary.starts_at.clone(),
            ends_at: None,
            venue: summary.venue.clone(),
            pricing_enabled: summary.pricing_enabled,
            available_price_tiers: Vec::new(),
            deposit_enabled: false,
            deposit_amount_cents: None,
        }
    }
}

/// 从后端 venue JsonString 里取城市（无 venue/非法 JSON 返回 None）。
pub fn venue_city(raw: &str) -> Option<String> {
    let value: Value = serde_json::from_str(raw).ok()?;
    value
        .get("city")
        .and_then(Value::as_str)
        .filter(|city| !city.is_empty())
        .map(str::to_string)
}

pub fn parse_price_tiers(raw: &Value) -> Vec<PriceTier> {
    raw.as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    let text = item.as_str()?;
                    let parsed: Value = serde_json::from_str(text).ok()?;
                    Some(PriceTier {
                        id: parsed.get("id")?.as_str()?.to_string(),
                        name: parsed.get("name")?.as_str()?.to_string(),
                        amount_cents: parsed
                            .get("amount_cents")
                            .and_then(Value::as_i64)
                            .unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

pub struct EventDetailService {
    api: Arc<dyn EventsApi>,
    detail: Option<EventDetail>,
    state: ListState,
    event_id: Option<String>,
}

impl EventDetailService {
    pub fn new(api: Arc<dyn EventsApi>) -> Self {
        Self {
            api,
            detail: None,
            state: ListState::Idle,
            event_id: None,
        }
    }

    pub fn api_handle(&self) -> Arc<dyn EventsApi> {
        Arc::clone(&self.api)
    }

    pub fn state(&self) -> &ListState {
        &self.state
    }

    pub fn detail(&self) -> Option<&EventDetail> {
        self.detail.as_ref()
    }

    pub fn event_id(&self) -> Option<&str> {
        self.event_id.as_deref()
    }

    pub fn begin_load(&mut self, event_id: &str) {
        self.event_id = Some(event_id.to_string());
        self.state = ListState::Loading;
    }

    pub fn adopt(&mut self, detail: EventDetail) {
        self.detail = Some(detail);
        self.state = ListState::Ready;
    }

    pub fn fail(&mut self, error: &EventsError) {
        self.state = ListState::Failed(error.diagnostic());
    }

    pub fn retry_ready(&mut self) {
        self.state = ListState::Idle;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::list::FakeEventsApi;

    fn detail_with(
        pricing: bool,
        tiers: Vec<PriceTier>,
        deposit: bool,
        deposit_cents: Option<i64>,
    ) -> EventDetail {
        EventDetail {
            id: "e-1".to_string(),
            title: "课".to_string(),
            description: None,
            status: "open".to_string(),
            visibility: "public".to_string(),
            enrollment_policy: "open".to_string(),
            capacity: Some(10),
            confirmed_count: Some(2),
            enrollment_badge: None,
            registration_deadline: None,
            starts_at: None,
            ends_at: None,
            venue: None,
            pricing_enabled: pricing,
            available_price_tiers: tiers,
            deposit_enabled: deposit,
            deposit_amount_cents: deposit_cents,
        }
    }

    #[test]
    fn free_when_no_pricing_and_no_deposit() {
        assert_eq!(
            detail_with(false, vec![], false, None).price_mode(),
            PriceMode::Free
        );
    }

    #[test]
    fn paid_mode_uses_min_amount_and_tier_count() {
        let tiers = vec![
            PriceTier {
                id: "a".into(),
                name: "早鸟".into(),
                amount_cents: 9900,
            },
            PriceTier {
                id: "b".into(),
                name: "标准".into(),
                amount_cents: 12900,
            },
        ];
        assert_eq!(
            detail_with(true, tiers, false, None).price_mode(),
            PriceMode::Paid {
                min_amount_cents: 9900,
                tiers: 2
            }
        );
    }

    #[test]
    fn deposit_takes_precedence() {
        assert_eq!(
            detail_with(true, vec![], true, Some(5000)).price_mode(),
            PriceMode::Deposit { amount_cents: 5000 }
        );
    }

    #[test]
    fn pricing_enabled_without_tiers_falls_back_to_free() {
        assert_eq!(
            detail_with(true, vec![], false, None).price_mode(),
            PriceMode::Free
        );
    }

    #[test]
    fn price_tier_json_is_parsed_and_bad_entries_dropped() {
        let raw = serde_json::json!([
            r#"{"id":"a","name":"早鸟","amount_cents":9900}"#,
            "not-json",
            r#"{"id":"b"}"#
        ]);
        let tiers = parse_price_tiers(&raw);
        assert_eq!(tiers.len(), 1);
        assert_eq!(tiers[0].name, "早鸟");
    }

    #[test]
    fn fake_api_returns_detail_and_service_tracks_states() {
        let api: Arc<dyn EventsApi> = Arc::new(FakeEventsApi::with_seed(2));
        let mut service = EventDetailService::new(api);
        service.begin_load("evt-000");
        assert_eq!(service.state(), &ListState::Loading);

        let detail = service
            .api_handle()
            .get_event(None, "evt-000")
            .expect("fake detail");
        service.adopt(detail);
        assert_eq!(service.state(), &ListState::Ready);
        assert_eq!(service.detail().map(|d| d.id.as_str()), Some("evt-000"));
    }
}
