use cgc_agent_provider::{Message, Model, ModelId, ProviderId, TokenUsage};
use serde::{Deserialize, Serialize};

/// 当前会话选中的模型。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SelectedModel {
    pub provider_id: ProviderId,
    pub model_id: ModelId,
}

impl SelectedModel {
    pub fn new(provider_id: ProviderId, model_id: ModelId) -> Self {
        Self {
            provider_id,
            model_id,
        }
    }

    pub fn matches(&self, model: &Model) -> bool {
        self.provider_id == model.provider_id && self.model_id == model.id
    }
}

/// 线程条目。工具相关条目为 P1a 的后续切片预留。
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum Entry {
    User {
        text: String,
        at: i64,
    },
    Assistant {
        text: String,
        usage: Option<TokenUsage>,
        at: i64,
    },
    ToolCall {
        id: String,
        name: String,
        args: serde_json::Value,
        at: i64,
    },
    ToolResult {
        tool_use_id: String,
        content: String,
        is_error: bool,
        at: i64,
    },
}

impl Entry {
    pub fn text(&self) -> Option<&str> {
        match self {
            Self::User { text, .. } | Self::Assistant { text, .. } => Some(text),
            _ => None,
        }
    }
}

/// 一条会话线程。P1a 先内存态，P1b 再加 SQLite 持久化。
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Thread {
    pub id: String,
    pub title: Option<String>,
    pub model: SelectedModel,
    pub entries: Vec<Entry>,
    pub usage_total: TokenUsage,
    pub created_at: i64,
    pub updated_at: i64,
}

impl Thread {
    pub fn new(id: impl Into<String>, model: SelectedModel) -> Self {
        let now = now_secs();
        Self {
            id: id.into(),
            title: None,
            model,
            entries: Vec::new(),
            usage_total: TokenUsage::default(),
            created_at: now,
            updated_at: now,
        }
    }

    pub fn push_user(&mut self, text: impl Into<String>) {
        self.entries.push(Entry::User {
            text: text.into(),
            at: now_secs(),
        });
        self.updated_at = now_secs();
    }

    pub fn push_assistant(&mut self, text: impl Into<String>, usage: Option<TokenUsage>) {
        self.entries.push(Entry::Assistant {
            text: text.into(),
            usage,
            at: now_secs(),
        });
        self.updated_at = now_secs();
    }

    /// 供 provider 使用的消息列表（工具结果在后续切片补）。
    pub fn messages(&self) -> Vec<Message> {
        self.entries
            .iter()
            .filter_map(|entry| match entry {
                Entry::User { text, .. } => Some(Message::user(text.clone())),
                Entry::Assistant { text, .. } => Some(Message::assistant_text(text.clone())),
                Entry::ToolCall { .. } | Entry::ToolResult { .. } => None,
            })
            .collect()
    }
}

pub(crate) fn now_secs() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn selected() -> SelectedModel {
        SelectedModel::new(ProviderId::new("fake"), ModelId::new("m1"))
    }

    #[test]
    fn thread_messages_map_user_and_assistant() {
        let mut thread = Thread::new("t1", selected());
        thread.push_user("hi");
        thread.push_assistant("hello", None);
        let messages = thread.messages();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0].text(), "hi");
        assert_eq!(messages[1].text(), "hello");
    }

    #[test]
    fn selected_model_matches_provider_and_model() {
        let model = Model::new(
            ProviderId::new("fake"),
            "Fake",
            "m1",
            "m1",
            cgc_agent_provider::ModelLimits::new(8_000, 1_000),
        );
        assert!(selected().matches(&model));
        let other = Model::new(
            ProviderId::new("fake"),
            "Fake",
            "m2",
            "m2",
            cgc_agent_provider::ModelLimits::new(8_000, 1_000),
        );
        assert!(!selected().matches(&other));
    }
}
