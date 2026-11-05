//! 第一方 native agent 的模型 Provider 层（设计稿 §3.1，P0）。
//!
//! 四件套：`Model`（纯数据）、`Request`、`CompletionEvent`、`TokenUsage`；
//! 行为只放在 [`Provider`] trait 上，UI / Agent loop 不依赖任何具体厂商类型。
//!
//! OpenAI-compatible 与 Anthropic Messages-compatible Provider 共用统一事件契约。

pub mod anthropic_compatible;
pub mod echo;
pub mod error;
pub mod event;
pub mod fake;
pub mod model;
pub mod openai_compatible;
pub mod protocol;
pub mod provider;
pub mod registry;
pub mod request;
pub mod sse;
pub mod unconfigured;
pub mod validate;

pub use anthropic_compatible::{AnthropicCompatibleConfig, AnthropicCompatibleProvider};
pub use echo::EchoProvider;
pub use error::{ProviderError, ProviderErrorCategory};
pub use event::{CompletionEvent, StopReason, TokenUsage, ToolUse};
pub use fake::FakeProvider;
pub use model::{Model, ModelCapabilities, ModelId, ModelLimits, ProviderId};
pub use openai_compatible::{OpenAiCompatibleConfig, OpenAiCompatibleProvider};
pub use protocol::{ProviderProtocol, ThinkingMode};
pub use provider::{CompletionStream, Provider};
pub use registry::ProviderRegistry;
pub use request::{Content, Message, Request, Role, ToolSchema};
pub use unconfigured::UnconfiguredProvider;
pub use validate::validate_credentials;
