use std::fmt;

use serde::{Deserialize, Serialize};

/// Provider 标识（例如 `deepseek`、`cgc-gateway`）。
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct ProviderId(String);

impl ProviderId {
    pub fn new(id: impl Into<String>) -> Self {
        Self(id.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for ProviderId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// 模型在 provider 内部的标识。
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct ModelId(String);

impl ModelId {
    pub fn new(id: impl Into<String>) -> Self {
        Self(id.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for ModelId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// 模型能力。UI 用它决定是否展示思考、工具、图片入口。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ModelCapabilities {
    pub tools: bool,
    pub images: bool,
    pub thinking: bool,
}

impl Default for ModelCapabilities {
    fn default() -> Self {
        Self {
            tools: true,
            images: false,
            thinking: false,
        }
    }
}

/// 模型限制。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ModelLimits {
    pub context_window: u32,
    pub max_output_tokens: u32,
}

impl ModelLimits {
    pub fn new(context_window: u32, max_output_tokens: u32) -> Self {
        Self {
            context_window,
            max_output_tokens,
        }
    }
}

/// 一个 provider 提供的模型。纯数据，不含任何网络行为。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Model {
    pub id: ModelId,
    pub name: String,
    pub provider_id: ProviderId,
    pub provider_name: String,
    pub capabilities: ModelCapabilities,
    pub limits: ModelLimits,
    pub telemetry_id: String,
}

impl Model {
    /// 构造模型；能力默认 `tools = true`、`images = false`、`thinking = false`。
    pub fn new(
        provider_id: ProviderId,
        provider_name: impl Into<String>,
        id: impl Into<String>,
        name: impl Into<String>,
        limits: ModelLimits,
    ) -> Self {
        let id = ModelId::new(id);
        let telemetry_id = format!("{provider_id}/{id}");
        Self {
            id,
            name: name.into(),
            provider_id,
            provider_name: provider_name.into(),
            capabilities: ModelCapabilities::default(),
            limits,
            telemetry_id,
        }
    }

    pub fn with_capabilities(mut self, capabilities: ModelCapabilities) -> Self {
        self.capabilities = capabilities;
        self
    }

    pub fn with_thinking(mut self, thinking: bool) -> Self {
        self.capabilities.thinking = thinking;
        self
    }

    pub fn with_tools(mut self, tools: bool) -> Self {
        self.capabilities.tools = tools;
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn telemetry_id_uses_provider_and_model() {
        let model = Model::new(
            ProviderId::new("deepseek"),
            "DeepSeek",
            "deepseek-chat",
            "DeepSeek Chat",
            ModelLimits::new(64_000, 8_000),
        );
        assert_eq!(model.telemetry_id, "deepseek/deepseek-chat");
    }

    #[test]
    fn capabilities_default_tools_on() {
        let (tools, images, thinking) = (
            ModelCapabilities::default().tools,
            ModelCapabilities::default().images,
            ModelCapabilities::default().thinking,
        );
        assert!(tools);
        assert!(!images);
        assert!(!thinking);
    }
}
