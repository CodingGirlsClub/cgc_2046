//! 会话与标题（B4b 结构拆分第四片：从视图模块移出，行为不变）。
//!
//! 子模块可直接访问父模块私有字段。

use super::*;

impl NativeAgentView {
    pub fn is_empty_thread(&self) -> bool {
        self.agent
            .as_ref()
            .map(|agent| agent.thread().entries.is_empty())
            .unwrap_or(true)
    }

    pub fn current_thread_id(&self) -> Option<String> {
        self.agent.as_ref().map(|agent| agent.thread().id.clone())
    }

    pub fn display_title(&self) -> String {
        self.agent
            .as_ref()
            .and_then(|agent| agent.thread().display_title())
            .unwrap_or_else(|| "新对话".to_string())
    }

    pub fn set_title_override(&mut self, title: Option<String>, cx: &mut Context<Self>) {
        self.host.set_title_override(title.clone());
        if let Some(agent) = &mut self.agent {
            agent.set_thread_title_override(title);
        }
        if let Some(agent) = self.agent.as_ref() {
            let _ = self.session_store.save_thread(agent.thread());
        }
        cx.notify();
    }

    pub fn regenerate_title(&mut self, cx: &mut Context<Self>) {
        self.host.set_title_override(None);
        if let Some(agent) = &mut self.agent {
            agent.set_thread_title(None);
            agent.set_thread_title_override(None);
        }
        self.generate_thread_title(cx);
    }

    /// 用当前模型生成会话标题（异步、失败回退首条用户消息）。
    pub(super) fn generate_thread_title(&mut self, cx: &mut Context<Self>) {
        let Some(agent) = &self.agent else {
            return;
        };
        let mut user_text = String::new();
        let mut assistant_text = String::new();
        for entry in &agent.thread().entries {
            match entry {
                cgc_agent_core::Entry::User { text, .. } if user_text.is_empty() => {
                    user_text = text.clone();
                }
                cgc_agent_core::Entry::Assistant { text, .. } if !text.is_empty() => {
                    assistant_text = text.clone();
                }
                _ => {}
            }
        }
        if user_text.is_empty() {
            return;
        }
        let provider = self.provider.clone();
        let model = self.model.clone();
        cx.notify();
        cx.spawn(async move |this, cx| {
            let request = ProviderRequest::new(vec![
                ProviderMessage::system(
                    "你是会话标题生成器。用不超过 12 个汉字概括对话主题，只输出标题本身，不要引号、句号或解释。",
                ),
                ProviderMessage::user(format!(
                    "用户: {}

助手: {}",
                    truncate_text(&user_text, 1200),
                    truncate_text(&assistant_text, 1600)
                )),
            ]);
            let mut generated = String::new();
            let mut failed = false;
            match provider.stream(&model, request).await {
                Ok(mut stream) => {
                    while let Some(event) = stream.next().await {
                        match event {
                            Ok(CompletionEvent::Text(text)) => generated.push_str(&text),
                            Ok(_) => {}
                            Err(error) => {
                                failed = true;
                                generated = error.to_string();
                                break;
                            }
                        }
                    }
                }
                Err(error) => {
                    failed = true;
                    generated = error.to_string();
                }
            }
            let fallback = clean_thread_title(&truncate_text(&user_text, 30));
            let title = clean_thread_title(&generated);
            let _ = this.update(cx, |this, cx| {
                if failed || title.is_empty() {
                    if !fallback.is_empty() {
                        if let Some(agent) = &mut this.agent {
                            agent.set_thread_title(Some(fallback.clone()));
                        }
                        if let (Some(agent), Some(store)) =
                            (this.agent.as_ref(), this.session_store.session_mut())
                        {
                            let _ = store.save_thread(agent.thread());
                        }
                    }
                } else {
                    if let Some(agent) = &mut this.agent {
                        agent.set_thread_title(Some(title.clone()));
                    }
                    if let (Some(agent), Some(store)) =
                        (this.agent.as_ref(), this.session_store.session_mut())
                    {
                        let _ = store.save_thread(agent.thread());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(super) fn maybe_generate_thread_title(&mut self, cx: &mut Context<Self>) {
        let has_title = self
            .agent
            .as_ref()
            .and_then(|agent| agent.thread().title.clone())
            .map(|title| !title.trim().is_empty())
            .unwrap_or(false);
        if has_title {
            return;
        }
        self.generate_thread_title(cx);
    }

    /// 当前 model 的 context window（用于共享模型的 usage 百分比）。
    pub(super) fn model_context_size(&self) -> u64 {
        self.providers
            .iter()
            .find(|provider| provider.id == self.model.provider_id.as_str())
            .map(|provider| provider.model_config(self.model.id.as_str()).context_window as u64)
            .unwrap_or(0)
    }

    /// 从统一线程列表恢复指定 native 线程。
    pub fn open_thread(&mut self, thread_id: &str, cx: &mut Context<Self>) {
        let Some(store) = self.session_store.session() else {
            return;
        };
        let Ok(Some(thread)) = store.load_thread(thread_id) else {
            return;
        };
        let mut state = NativeThreadState::new();
        let restored_images = apply_thread_entries(&mut state, &thread.entries);
        state.usage_total = thread.usage_total;
        state.thread.thread_id = thread.id.clone();
        state.set_context_size(self.model_context_size());
        state.thread.usage = Usage {
            used: thread.usage_total.total(),
            size: self.model_context_size(),
            cost: None,
        };
        self.state = state;
        self.sent_images = restored_images;
        let prompt = build_workspace_system_prompt(self.context.workspace());
        self.agent = Some(Agent::new(thread, Some(prompt)));
        self.editing_user = None;
        self.user_edit_input = None;
        self.reload_thread_checkpoints();
        self.status = "已恢复线程".to_string();
        self.busy = false;
        self.checkpoint_changes.clear();
        self.show_checkpoint_panel = false;
        self.scroll_messages_to_bottom(cx);
        cx.notify();
    }
}
