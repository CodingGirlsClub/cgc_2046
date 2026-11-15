use serde::{Deserialize, Serialize};

/// Wire protocol selected when adding a custom Provider.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderProtocol {
    #[default]
    OpenAiCompatible,
    OpenAiResponses,
    AnthropicCompatible,
}

/// 未知协议（例如更高版本写入的值）回退到 OpenAI 兼容，避免整份 prefs 反序列化失败。
impl<'de> Deserialize<'de> for ProviderProtocol {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = <String as Deserialize>::deserialize(deserializer)?;
        Ok(value.parse().unwrap_or_default())
    }
}

impl std::str::FromStr for ProviderProtocol {
    type Err = &'static str;
    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "openai_compatible" => Ok(Self::OpenAiCompatible),
            "open_ai_responses" | "openai_responses" | "responses" => Ok(Self::OpenAiResponses),
            "anthropic_compatible" => Ok(Self::AnthropicCompatible),
            _ => {
                Err("protocol must be openai_compatible, open_ai_responses or anthropic_compatible")
            }
        }
    }
}

impl ProviderProtocol {
    pub fn name(self) -> &'static str {
        match self {
            Self::OpenAiCompatible => "OpenAI Compatible",
            Self::OpenAiResponses => "OpenAI Responses",
            Self::AnthropicCompatible => "Anthropic Compatible",
        }
    }

    pub fn default_url(self) -> &'static str {
        match self {
            Self::OpenAiCompatible | Self::OpenAiResponses => "https://api.openai.com/v1",
            Self::AnthropicCompatible => "https://api.anthropic.com",
        }
    }
}

/// Anthropic-compatible models declare their mode; model names never imply capabilities.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ThinkingMode {
    #[default]
    Disabled,
    Budget {
        budget_tokens: u32,
    },
    Adaptive,
}

#[cfg(test)]
mod tests {
    use super::ProviderProtocol;

    #[test]
    fn protocol_roundtrips_and_tolerates_unknown_values() {
        let responses: ProviderProtocol =
            serde_json::from_str("\"open_ai_responses\"").expect("responses");
        assert_eq!(responses, ProviderProtocol::OpenAiResponses);
        assert_eq!(
            serde_json::to_string(&ProviderProtocol::OpenAiResponses).expect("serialize"),
            "\"open_ai_responses\""
        );

        // 更高版本写入的未知协议不能拖垮整份 prefs。
        let unknown: ProviderProtocol =
            serde_json::from_str("\"gemini_compatible\"").expect("unknown falls back");
        assert_eq!(unknown, ProviderProtocol::OpenAiCompatible);
    }
}
