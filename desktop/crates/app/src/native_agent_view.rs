//! Native agent 的最小 GPUI 界面（P0 T3 剩余部分）。
//!
//! 通过环境变量 `CGC_NATIVE_AGENT_DEMO=1` 打开独立窗口，不影响现有 ACP 对话路径。
//! 没有配置 provider 时用离线 EchoProvider，可直接演示流式对话与工具审批链路。

use std::sync::Arc;

use cgc_agent_core::{Agent, CancelToken, SelectedModel, Thread};
use cgc_agent_provider::{
    EchoProvider, Model, ModelLimits, OpenAiCompatibleConfig, OpenAiCompatibleProvider, Provider,
    ProviderId,
};
use cgc_agent_store::{AgentPrefs, PrefsStore, SessionStore};
use cgc_agent_tools::{SandboxPolicy, ToolContext, ToolRegistry};
use gpui_kit::component::input::{InputEvent, Textarea, TextareaState};
use gpui_kit::*;

use crate::theme::{self, space, RADIUS_MEDIUM};

#[derive(Clone)]
struct ChatLine {
    role: &'static str,
    text: String,
}

pub struct NativeAgentView {
    agent: Option<Agent>,
    provider: Arc<dyn Provider>,
    model: Model,
    registry: Arc<ToolRegistry>,
    context: ToolContext,
    input: Entity<TextareaState>,
    cancel: CancelToken,
    messages: Vec<ChatLine>,
    status: String,
    busy: bool,
    session_store: Option<SessionStore>,
    _input_subscription: Option<Subscription>,
}

impl NativeAgentView {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let paths = cgc_platform::paths::AppPaths::from_env();
        let prefs_store = PrefsStore::new(paths.agent_prefs_file());
        let prefs = prefs_store.load();
        let env_model = std::env::var("CGC_AGENT_MODEL")
            .ok()
            .filter(|model| !model.is_empty());
        let model_id = env_model
            .clone()
            .or_else(|| {
                prefs
                    .selected_model
                    .as_ref()
                    .map(|selected| selected.model_id.as_str().to_string())
            })
            .unwrap_or_else(|| "echo".to_string());
        let provider_name = std::env::var("CGC_AGENT_PROVIDER_NAME")
            .unwrap_or_else(|_| "OpenAI Compatible".to_string());
        let model = Model::new(
            ProviderId::new("custom"),
            provider_name,
            model_id.clone(),
            model_id,
            ModelLimits::new(64_000, 8_000),
        );
        if env_model.is_some() {
            let _ = prefs_store.save(&AgentPrefs {
                selected_model: Some(SelectedModel::new(
                    model.provider_id.clone(),
                    model.id.clone(),
                )),
            });
        }
        let provider: Arc<dyn Provider> = match (
            std::env::var("CGC_AGENT_BASE_URL"),
            std::env::var("CGC_AGENT_API_KEY"),
        ) {
            (Ok(base_url), Ok(api_key)) if !base_url.is_empty() && !api_key.is_empty() => {
                Arc::new(OpenAiCompatibleProvider::new(OpenAiCompatibleConfig::new(
                    base_url,
                    api_key,
                    vec![model.clone()],
                )))
            }
            _ => Arc::new(EchoProvider::new(model.clone())),
        };
        let selected = SelectedModel::new(model.provider_id.clone(), model.id.clone());
        let session_store =
            SessionStore::open(paths.data_root.join("agent").join("threads.db")).ok();
        let restored_thread = session_store.as_ref().and_then(|store| {
            let latest = store.list_threads(1).ok()?.into_iter().next()?;
            let thread = store.load_thread(&latest.id).ok().flatten()?;
            (thread.model == selected).then_some(thread)
        });
        let (thread, restored_messages) = match restored_thread {
            Some(thread) => {
                let messages = thread
                    .entries
                    .iter()
                    .filter_map(|entry| match entry {
                        cgc_agent_core::Entry::User { text, .. } => Some(ChatLine {
                            role: "user",
                            text: text.clone(),
                        }),
                        cgc_agent_core::Entry::Assistant { text, .. } if !text.is_empty() => {
                            Some(ChatLine {
                                role: "agent",
                                text: text.clone(),
                            })
                        }
                        cgc_agent_core::Entry::ToolResult {
                            tool_name,
                            is_error,
                            ..
                        } => Some(ChatLine {
                            role: "tool",
                            text: format!(
                                "{tool_name} · {}",
                                if *is_error { "失败" } else { "完成" }
                            ),
                        }),
                        _ => None,
                    })
                    .collect::<Vec<_>>();
                (thread, messages)
            }
            None => (Thread::new("native-demo", selected), Vec::new()),
        };
        let restored = !restored_messages.is_empty();
        let agent = Agent::new(thread, None);
        let cancel = agent.cancel_token();
        let workspace = std::env::var("CGC_AGENT_WORKSPACE")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|_| std::env::temp_dir().join("cgc-native-agent-demo"));
        let _ = std::fs::create_dir_all(&workspace);
        let input = cx.new(|cx| {
            TextareaState::new(window, cx).placeholder("问 native agent 一个问题，回车发送…")
        });
        let input_subscription = Some(cx.subscribe_in(
            &input,
            window,
            |this, state, event: &InputEvent, window, cx| {
                if let InputEvent::PressEnter { shift, .. } = event {
                    if !shift {
                        this.send(cx);
                        state.update(cx, |state, cx| state.set_value("", window, cx));
                        cx.notify();
                    }
                }
            },
        ));
        Self {
            agent: Some(agent),
            provider,
            model,
            registry: Arc::new(ToolRegistry::with_builtin_tools()),
            context: ToolContext::new(&workspace).with_sandbox(SandboxPolicy::new(&workspace)),
            input,
            cancel,
            messages: if restored {
                restored_messages
            } else {
                vec![ChatLine {
                    role: "system",
                    text: "Native agent demo：离线模式直接回显；配置环境变量后接真实模型。"
                        .to_string(),
                }]
            },
            status: if restored {
                "已恢复上次会话".to_string()
            } else {
                "就绪".to_string()
            },
            busy: false,
            session_store,
            _input_subscription: input_subscription,
        }
    }

    fn send(&mut self, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let text = self.input.read(cx).value().to_string();
        let text = text.trim().to_string();
        if text.is_empty() {
            return;
        }
        let Some(mut agent) = self.agent.take() else {
            return;
        };
        self.messages.push(ChatLine {
            role: "user",
            text: text.clone(),
        });
        self.busy = true;
        self.status = "思考中…".to_string();
        self.cancel.reset();
        let provider = self.provider.clone();
        let model = self.model.clone();
        let registry = self.registry.clone();
        let context = self.context.clone();
        let task = cx.background_executor().spawn(async move {
            let result = agent
                .prompt_with_tools(
                    provider.as_ref(),
                    &model,
                    text,
                    registry.as_ref(),
                    &context,
                    &cgc_agent_core::AutoApprover,
                )
                .await;
            (agent, result)
        });
        cx.spawn(async move |this, cx| {
            let (agent, result) = task.await;
            let _ = this.update(cx, |this, cx| {
                this.agent = Some(agent);
                this.busy = false;
                match result {
                    Ok(outcome) => {
                        let total = this
                            .agent
                            .as_ref()
                            .map(|agent| agent.thread().usage_total.total())
                            .unwrap_or(0);
                        this.status = format!(
                            "完成 · 本轮 {} tokens · 本会话 {} tokens",
                            outcome.usage.input + outcome.usage.output,
                            total
                        );
                        if !outcome.text.is_empty() {
                            this.messages.push(ChatLine {
                                role: "agent",
                                text: outcome.text,
                            });
                        }
                        for tool_result in &outcome.tool_results {
                            this.messages.push(ChatLine {
                                role: "tool",
                                text: format!(
                                    "{} · {}",
                                    tool_result.tool_name,
                                    if tool_result.is_error {
                                        "失败"
                                    } else {
                                        "完成"
                                    }
                                ),
                            });
                        }
                        if let (Some(store), Some(agent)) = (&mut this.session_store, &this.agent) {
                            let _ = store.save_thread(agent.thread());
                        }
                    }
                    Err(error) => {
                        this.status = format!("错误：{error}");
                        this.messages.push(ChatLine {
                            role: "error",
                            text: error.to_string(),
                        });
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn stop(&mut self, cx: &mut Context<Self>) {
        self.cancel.cancel();
        self.status = "已请求停止".to_string();
        cx.notify();
    }
}

impl Render for NativeAgentView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let palette = theme::palette_from_theme(cx);
        let busy = self.busy;
        let model_label = format!("{}/{}", self.model.provider_id, self.model.id);
        let status = self.status.clone();
        let messages = self.messages.clone();
        let input = self.input.clone();
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(palette.canvas)
            .text_color(palette.ink)
            .font_family(theme::FONT_SANS)
            .text_size(px(13.0))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(2.0))
                    .px(space(3))
                    .py(space(2))
                    .border_b_1()
                    .border_color(palette.line)
                    .child(
                        div()
                            .text_size(px(15.0))
                            .child("Native Agent Demo（P0 T3）"),
                    )
                    .child(
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child(format!("model: {model_label} · {status}")),
                    ),
            )
            .child(
                div()
                    .id("native-agent-messages")
                    .flex_1()
                    .flex()
                    .flex_col()
                    .gap(space(2))
                    .p(space(3))
                    .overflow_y_scroll()
                    .children(messages.into_iter().map(|line| {
                        let color = match line.role {
                            "user" => palette.accent,
                            "error" => palette.danger,
                            "tool" => palette.ink_3,
                            "system" => palette.ink_3,
                            _ => palette.ink,
                        };
                        div()
                            .flex()
                            .flex_col()
                            .gap(px(2.0))
                            .child(div().text_size(px(11.0)).text_color(color).child(line.role))
                            .child(div().text_size(px(13.0)).child(line.text))
                    })),
            )
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(space(2))
                    .p(space(2))
                    .border_t_1()
                    .border_color(palette.line)
                    .child(
                        div()
                            .flex_1()
                            .rounded(px(RADIUS_MEDIUM))
                            .border_1()
                            .border_color(palette.line)
                            .bg(palette.view)
                            .px(space(1))
                            .py(px(4.0))
                            .child(
                                Textarea::new(&input)
                                    .appearance(false)
                                    .bordered(false)
                                    .h(px(36.0))
                                    .w_full(),
                            ),
                    )
                    .child(
                        div()
                            .id(if busy {
                                "native-agent-stop"
                            } else {
                                "native-agent-send"
                            })
                            .role(Role::Button)
                            .aria_label(if busy { "停止" } else { "发送" })
                            .px(space(3))
                            .py(space(1))
                            .rounded(px(RADIUS_MEDIUM))
                            .bg(if busy { palette.danger } else { palette.accent })
                            .text_color(palette.canvas)
                            .child(if busy { "停止" } else { "发送" })
                            .on_click(cx.listener(move |this, _, _window, cx| {
                                if busy {
                                    this.stop(cx);
                                } else {
                                    this.send(cx);
                                }
                            })),
                    ),
            )
    }
}
