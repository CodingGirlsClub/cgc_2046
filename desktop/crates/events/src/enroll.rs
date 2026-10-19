//! 报名（story 3.3）：myEnrollment 读取、createEnrollment mutation 与错误码模型。

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MyEnrollment {
    pub id: String,
    pub status: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EnrollmentRequest {
    pub event_id: String,
    pub user_id: String,
    pub tier_id: Option<String>,
    pub age_confirmed: bool,
}

impl EnrollmentRequest {
    pub fn to_input(&self) -> serde_json::Value {
        let mut input = serde_json::json!({
            "eventId": self.event_id,
            "userId": self.user_id,
        });
        if let Some(tier_id) = &self.tier_id {
            input["tierId"] = serde_json::json!(tier_id);
        }
        if self.age_confirmed {
            input["ageConfirmed"] = serde_json::json!(true);
        }
        input
    }
}

/// error code → i18n key 后缀单源（前端只查词表，不硬编码文案）。
pub fn enrollment_error_key(code: &str) -> &'static str {
    match code {
        "enrollment_duplicate_active" => "duplicate",
        "enrollment_target_not_open_or_registration_closed" => "not_open",
        "enrollment_capacity_full_or_registration_closed" => "full",
        "enrollment_invite_code_required" => "invite_required",
        "enrollment_tier_id_required" => "tier_required",
        "enrollment_tier_not_available" => "tier_unavailable",
        "enrollment_age_confirmation_required" => "age_required",
        "unauthorized" => "auth",
        _ => "generic",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn input_omits_optional_fields_when_absent() {
        let input = EnrollmentRequest {
            event_id: "e-1".into(),
            user_id: "u-1".into(),
            tier_id: None,
            age_confirmed: false,
        }
        .to_input();
        assert_eq!(input["eventId"], "e-1");
        assert_eq!(input["userId"], "u-1");
        assert!(input.get("tierId").is_none());
        assert!(input.get("ageConfirmed").is_none());
    }

    #[test]
    fn input_carries_tier_and_age() {
        let input = EnrollmentRequest {
            event_id: "e-1".into(),
            user_id: "u-1".into(),
            tier_id: Some("tier-early".into()),
            age_confirmed: true,
        }
        .to_input();
        assert_eq!(input["tierId"], "tier-early");
        assert_eq!(input["ageConfirmed"], true);
    }

    #[test]
    fn error_codes_map_to_stable_keys() {
        assert_eq!(
            enrollment_error_key("enrollment_duplicate_active"),
            "duplicate"
        );
        assert_eq!(
            enrollment_error_key("enrollment_tier_id_required"),
            "tier_required"
        );
        assert_eq!(enrollment_error_key("whatever"), "generic");
    }
}
