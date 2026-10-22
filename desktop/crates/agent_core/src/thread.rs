use cgc_agent_provider::{Content, Message, Model, ModelId, ProviderId, TokenUsage, ToolUse};
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

/// 线程条目。工具调用挂在 Assistant 条目上，与工具结果分开存放。
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum Entry {
    User {
        text: String,
        at: i64,
    },
    Assistant {
        text: String,
        tool_calls: Vec<ToolUse>,
        usage: Option<TokenUsage>,
        at: i64,
    },
    ToolResult {
        tool_use_id: String,
        tool_name: String,
        content: String,
        is_error: bool,
        at: i64,
    },
}

impl Entry {
    pub fn text(&self) -> Option<&str> {
        match self {
            Self::User { text, .. } | Self::Assistant { text, .. } => Some(text),
            Self::ToolResult { .. } => None,
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

    pub fn push_assistant(
        &mut self,
        text: impl Into<String>,
        tool_calls: Vec<ToolUse>,
        usage: Option<TokenUsage>,
    ) {
        self.entries.push(Entry::Assistant {
            text: text.into(),
            tool_calls,
            usage,
            at: now_secs(),
        });
        self.updated_at = now_secs();
    }

    pub fn push_tool_result(
        &mut self,
        tool_use_id: impl Into<String>,
        tool_name: impl Into<String>,
        content: impl Into<String>,
        is_error: bool,
    ) {
        self.entries.push(Entry::ToolResult {
            tool_use_id: tool_use_id.into(),
            tool_name: tool_name.into(),
            content: content.into(),
            is_error,
            at: now_secs(),
        });
        self.updated_at = now_secs();
    }

    /// 供 provider 使用的消息列表（含工具调用与工具结果）。
    pub fn messages(&self) -> Vec<Message> {
        let mut messages = Vec::new();
        for entry in &self.entries {
            match entry {
                Entry::User { text, .. } => messages.push(Message::user(text.clone())),
                Entry::Assistant {
                    text, tool_calls, ..
                } => {
                    let mut content = Vec::new();
                    if !text.is_empty() {
                        content.push(Content::Text(text.clone()));
                    }
                    content.extend(
                        tool_calls
                            .iter()
                            .map(|tool_use| Content::ToolUse(tool_use.clone())),
                    );
                    if !content.is_empty() {
                        messages.push(Message::new(cgc_agent_provider::Role::Assistant, content));
                    }
                }
                Entry::ToolResult {
                    tool_use_id,
                    content,
                    is_error,
                    ..
                } => messages.push(Message::tool_result(
                    tool_use_id.clone(),
                    content.clone(),
                    *is_error,
                )),
            }
        }
        messages
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
    use cgc_agent_provider::{ProviderId, TokenUsage};

    fn selected() -> SelectedModel {
        SelectedModel::new(ProviderId::new("fake"), ModelId::new("m1"))
    }

    #[test]
    fn thread_messages_map_user_and_assistant() {
        let mut thread = Thread::new("t1", selected());
        thread.push_user("hi");
        thread.push_assistant("hello", Vec::new(), None);
        let messages = thread.messages();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0].text(), "hi");
        assert_eq!(messages[1].text(), "hello");
    }

    #[test]
    fn messages_include_tool_calls_and_results() {
        let mut thread = Thread::new("t1", selected());
        thread.push_user("read");
        thread.push_assistant(
            "",
            vec![ToolUse {
                id: "call_1".into(),
                name: "read_file".into(),
                args: serde_json::json!({"path": "a.txt"}),
            }],
            Some(TokenUsage::default()),
        );
        thread.push_tool_result("call_1", "read_file", "content", false);
        let messages = thread.messages();
        assert_eq!(messages.len(), 3);
        assert!(
            matches!(&messages[1].content[0], Content::ToolUse(tool_use) if tool_use.name == "read_file")
        );
        assert!(
            matches!(&messages[2].content[0], Content::ToolResult { content, .. } if content == "content")
        );
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
