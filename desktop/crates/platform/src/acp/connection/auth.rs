use super::*;
use std::sync::mpsc::SyncSender;

#[derive(Clone, Debug)]
pub(super) struct RequestFailure {
    pub(super) phase: &'static str,
    pub(super) message: String,
    pub(super) code: Option<i32>,
    pub(super) data: Option<serde_json::Value>,
}

impl RequestFailure {
    pub(super) fn from_error(phase: &'static str, error: agent_client_protocol::Error) -> Self {
        Self {
            phase,
            message: format!("{error}"),
            code: Some(i32::from(error.code)),
            data: error.data,
        }
    }

    pub(super) fn timeout(phase: &'static str) -> Self {
        Self {
            phase,
            message: "timeout".to_string(),
            code: None,
            data: None,
        }
    }

    pub(super) fn is_auth_required(&self) -> bool {
        self.code == Some(-32000)
    }

    pub(super) fn auth_event(&self) -> Option<HostEvent> {
        if !self.is_auth_required() {
            return None;
        }
        Some(HostEvent::AuthRequired {
            message: self.message.clone(),
            auth_methods: auth_method_views(self.data.as_ref()),
        })
    }

    pub(super) fn into_message(self) -> String {
        format!("{}: {}", self.phase, self.message)
    }
}

impl std::fmt::Display for RequestFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{}: {}", self.phase, self.message)
    }
}

impl From<RequestFailure> for String {
    fn from(failure: RequestFailure) -> Self {
        failure.into_message()
    }
}

pub(super) fn send_auth_required(failure: &RequestFailure, events: &SyncSender<HostEvent>) -> bool {
    let Some(event) = failure.auth_event() else {
        return false;
    };
    send_event(events, event);
    true
}

fn auth_method_views(data: Option<&serde_json::Value>) -> Vec<AuthMethodView> {
    let Some(methods) = data
        .and_then(|data| data.get("authMethods"))
        .and_then(serde_json::Value::as_array)
    else {
        return Vec::new();
    };
    methods
        .iter()
        .filter_map(|method| {
            let id = method.get("id")?.as_str()?.to_string();
            let name = method
                .get("name")
                .and_then(serde_json::Value::as_str)
                .unwrap_or(&id)
                .to_string();
            let description = method
                .get("description")
                .and_then(serde_json::Value::as_str)
                .map(str::to_string);
            let kind = method
                .get("type")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("agent")
                .to_string();
            Some(AuthMethodView {
                id,
                name,
                description,
                kind,
            })
        })
        .collect()
}
