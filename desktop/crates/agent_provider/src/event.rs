use serde::{Deserialize, Serialize};

/// 一次请求的 token 用量。四个分项与 OpenAI / Anthropic 的 usage 对齐。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TokenUsage {
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_creation: u64,
}

impl TokenUsage {
    pub fn total(&self) -> u64 {
        self.input + self.output + self.cache_read + self.cache_creation
    }

    pub fn add(&mut self, other: TokenUsage) {
        self.input += other.input;
        self.output += other.output;
        self.cache_read += other.cache_read;
        self.cache_creation += other.cache_creation;
    }
}

/// 模型结束本轮的原因。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum StopReason {
    EndTurn,
    MaxTokens,
    ToolUse,
    ContentFilter,
    Other(String),
}

/// 模型发起的一次工具调用。`args` 已解析为 JSON。
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ToolUse {
    pub id: String,
    pub name: String,
    pub args: serde_json::Value,
}

/// Provider 流式输出的统一事件。
#[derive(Clone, Debug, PartialEq)]
pub enum CompletionEvent {
    /// 第一条消息开始；携带 provider 侧消息 id（用于日志与去重）。
    StartMessage {
        message_id: String,
    },
    Text(String),
    Thinking {
        text: String,
        signature: Option<String>,
    },
    ToolUse(ToolUse),
    Usage(TokenUsage),
    Stop(StopReason),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usage_accumulates() {
        let mut total = TokenUsage::default();
        total.add(TokenUsage {
            input: 10,
            output: 2,
            cache_read: 3,
            cache_creation: 1,
        });
        total.add(TokenUsage {
            input: 5,
            output: 1,
            cache_read: 0,
            cache_creation: 0,
        });
        assert_eq!(total.total(), 22);
    }
}
