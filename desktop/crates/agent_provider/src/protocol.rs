use serde::{Deserialize, Serialize};

/// Wire protocol selected when adding a custom Provider.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderProtocol {
    #[default]
    OpenAiCompatible,
    AnthropicCompatible,
}

impl std::str::FromStr for ProviderProtocol {
    type Err = &'static str;
    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "openai_compatible" => Ok(Self::OpenAiCompatible),
            "anthropic_compatible" => Ok(Self::AnthropicCompatible),
            _ => Err("protocol must be openai_compatible or anthropic_compatible"),
        }
    }
}

impl ProviderProtocol {
    pub fn name(self) -> &'static str {
        match self {
            Self::OpenAiCompatible => "OpenAI Compatible",
            Self::AnthropicCompatible => "Anthropic Compatible",
        }
    }

    pub fn default_url(self) -> &'static str {
        match self {
            Self::OpenAiCompatible => "https://api.openai.com/v1",
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
