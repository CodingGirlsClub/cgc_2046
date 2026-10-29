//! 第一方 native agent 的模型 Provider 层（设计稿 §3.1，P0）。
//!
//! 四件套：`Model`（纯数据）、`Request`、`CompletionEvent`、`TokenUsage`；
//! 行为只放在 [`Provider`] trait 上，UI / Agent loop 不依赖任何具体厂商类型。
//!
//! 当前提供：FakeProvider（测试与事件回放）与 OpenAI-compatible Provider
//! （覆盖国产 provider、自定义 endpoint、CGC 网关）。Anthropic / Google /
//! Ollama 等专用适配器在 P1 按需加入。

pub mod echo;
pub mod error;
pub mod event;
pub mod fake;
pub mod model;
pub mod openai_compatible;
pub mod provider;
pub mod registry;
pub mod request;
pub mod sse;
pub mod unconfigured;
pub mod validate;

pub use echo::EchoProvider;
pub use error::{ProviderError, ProviderErrorCategory};
pub use event::{CompletionEvent, StopReason, TokenUsage, ToolUse};
pub use fake::FakeProvider;
pub use model::{Model, ModelCapabilities, ModelId, ModelLimits, ProviderId};
pub use openai_compatible::{OpenAiCompatibleConfig, OpenAiCompatibleProvider};
pub use provider::{CompletionStream, Provider};
pub use registry::ProviderRegistry;
pub use request::{Content, Message, Request, Role, ToolSchema};
pub use unconfigured::UnconfiguredProvider;
pub use validate::validate_credentials;
