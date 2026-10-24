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

/// 用户消息里的图片附件（base64，随 thread 持久化）。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImageAttachment {
    #[serde(default)]
    pub name: String,
    pub mime_type: String,
    pub data: String,
}

/// 线程条目。工具调用挂在 Assistant 条目上，与工具结果分开存放。
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum Entry {
    User {
        text: String,
        #[serde(default)]
        images: Vec<ImageAttachment>,
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
    Compaction {
        summary: String,
        replaced_entries: usize,
        at: i64,
    },
}

impl Entry {
    pub fn text(&self) -> Option<&str> {
        match self {
            Self::User { text, .. } | Self::Assistant { text, .. } => Some(text),
            Self::ToolResult { .. } | Self::Compaction { .. } => None,
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
            images: Vec::new(),
            at: now_secs(),
        });
        self.updated_at = now_secs();
    }

    /// 把图片挂到最近一条用户消息上（用于持久化与请求构建）。
    pub fn attach_images_to_last_user(&mut self, images: Vec<ImageAttachment>) {
        if images.is_empty() {
            return;
        }
        if let Some(Entry::User { images: slot, .. }) = self
            .entries
            .iter_mut()
            .rev()
            .find(|entry| matches!(entry, Entry::User { .. }))
        {
            slot.extend(images);
            self.updated_at = now_secs();
        }
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

    pub fn push_compaction(&mut self, summary: impl Into<String>, replaced_entries: usize) {
        self.entries.push(Entry::Compaction {
            summary: summary.into(),
            replaced_entries,
            at: now_secs(),
        });
        self.updated_at = now_secs();
    }

    /// 按预算把历史切成（较早、保留）两段；较早段用于摘要压缩。
    pub fn partition_history(&self, budget_tokens: usize) -> (Vec<Entry>, usize) {
        if budget_tokens == 0 {
            return (Vec::new(), 0);
        }
        let mut older = Vec::new();
        let mut used = 0usize;
        let mut kept = 0usize;
        for entry in self.entries.iter().rev() {
            let estimate = estimate_entry_tokens(entry);
            if kept > 0 && used + estimate > budget_tokens {
                older.push(entry.clone());
                continue;
            }
            used += estimate;
            kept += 1;
        }
        older.reverse();
        (older, kept)
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
                Entry::User { text, images, .. } => {
                    let mut message = Message::user(text.clone());
                    message
                        .content
                        .extend(images.iter().map(|image| Content::Image {
                            mime_type: image.mime_type.clone(),
                            data: image.data.clone(),
                        }));
                    messages.push(message);
                }
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
                Entry::Compaction { summary, .. } => {
                    messages.push(Message::system(format!("历史摘要：{summary}")))
                }
            }
        }
        messages
    }

    /// 按 token 预算保留最近消息；发生截断时在最前面加一条压缩提示。
    pub fn messages_with_budget(&self, budget_tokens: usize) -> (Vec<Message>, usize) {
        let messages = self.messages();
        if budget_tokens == 0 {
            return (messages, 0);
        }
        let mut kept: Vec<Message> = Vec::new();
        let mut used = 0usize;
        let mut omitted = 0usize;
        for message in messages.iter().rev() {
            let estimate = estimate_message_tokens(message);
            if !kept.is_empty() && used + estimate > budget_tokens {
                omitted += 1;
                continue;
            }
            used += estimate;
            kept.push(message.clone());
        }
        kept.reverse();
        if omitted > 0 {
            kept.insert(
                0,
                Message::system(format!("上下文已压缩：省略了 {omitted} 条更早的消息")),
            );
        }
        (kept, omitted)
    }
}

fn estimate_entry_tokens(entry: &Entry) -> usize {
    match entry {
        Entry::User { text, .. } => text.chars().count() / 4 + 4,
        Entry::Assistant {
            text, tool_calls, ..
        } => {
            text.chars().count() / 4
                + tool_calls
                    .iter()
                    .map(|tool_use| tool_use.args.to_string().chars().count() / 4 + 8)
                    .sum::<usize>()
                + 4
        }
        Entry::ToolResult { content, .. } => content.chars().count() / 4 + 4,
        Entry::Compaction { summary, .. } => summary.chars().count() / 4 + 4,
    }
}

fn estimate_message_tokens(message: &Message) -> usize {
    let chars: usize = message
        .content
        .iter()
        .map(|content| match content {
            Content::Text(text) => text.chars().count(),
            // 图片 token 由 provider 计费口径决定，本地不估算。
            Content::Image { .. } => 0,
            Content::ToolUse(tool_use) => {
                tool_use.args.to_string().chars().count() + tool_use.name.len()
            }
            Content::ToolResult { content, .. } => content.chars().count(),
        })
        .sum();
    chars / 4 + 4
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

#[cfg(test)]
mod budget_tests {
    use super::*;
    use cgc_agent_provider::ProviderId;

    fn selected() -> SelectedModel {
        SelectedModel::new(ProviderId::new("fake"), ModelId::new("m1"))
    }

    fn thread_with_turns(turns: usize) -> Thread {
        let mut thread = Thread::new("t1", selected());
        for index in 0..turns {
            thread.push_user(format!("question {index} {}", "x".repeat(200)));
            thread.push_assistant(
                format!("answer {index} {}", "y".repeat(200)),
                Vec::new(),
                None,
            );
        }
        thread
    }

    #[test]
    fn small_budget_keeps_recent_messages_and_adds_notice() {
        let thread = thread_with_turns(12);
        let all = thread.messages();
        let (kept, omitted) = thread.messages_with_budget(200);
        assert!(omitted > 0);
        assert!(kept.len() < all.len());
        assert_eq!(kept[0].role, cgc_agent_provider::Role::System);
        assert!(kept[0].text().contains("上下文已压缩"));
        assert!(kept.last().unwrap().text().contains("answer 11"));
    }

    #[test]
    fn large_budget_keeps_everything() {
        let thread = thread_with_turns(3);
        let all = thread.messages();
        let (kept, omitted) = thread.messages_with_budget(100_000);
        assert_eq!(omitted, 0);
        assert_eq!(kept.len(), all.len());
    }
}

#[cfg(test)]
mod image_tests {
    use super::*;

    #[test]
    fn user_images_are_persisted_and_mapped_to_content() {
        let mut thread = Thread::new(
            "t",
            SelectedModel::new(ProviderId::new("p"), ModelId::new("m")),
        );
        thread.push_user("看图");
        thread.attach_images_to_last_user(vec![ImageAttachment {
            name: "a.png".to_string(),
            mime_type: "image/png".to_string(),
            data: "AAAA".to_string(),
        }]);
        let json = serde_json::to_string(thread.entries.first().unwrap()).expect("serialize");
        assert!(json.contains("image/png"));
        let messages = thread.messages();
        assert!(messages[0]
            .content
            .iter()
            .any(|content| matches!(content, Content::Image { .. })));
    }
}
