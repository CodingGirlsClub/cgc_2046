use super::worker::{Job, Owner};
use super::*;
use cgc_agent_core::{CancelToken, Entry};
use cgc_agent_provider::{CompletionEvent, Message, Request};
use futures::{FutureExt, StreamExt};

impl Owner {
    pub(super) fn start_title(&mut self, force: bool) {
        if self.active.is_some() || self.title_running {
            self.pending_title = Some(force);
            return;
        }
        let Some(agent) = self.agent.as_mut() else {
            return;
        };
        if !force
            && agent
                .thread()
                .title
                .as_ref()
                .is_some_and(|title| !title.trim().is_empty())
        {
            return;
        }
        if force {
            agent.set_thread_title(None);
            agent.set_thread_title_override(None);
        }
        let user = agent.thread().entries.iter().find_map(|entry| match entry {
            Entry::User { text, .. } => Some(crate::native_context::truncate_text(text, 1_200)),
            _ => None,
        });
        let Some(user) = user.filter(|text| !text.is_empty()) else {
            return;
        };
        let assistant = agent
            .thread()
            .entries
            .iter()
            .rev()
            .find_map(|entry| match entry {
                Entry::Assistant { text, .. } if !text.is_empty() => {
                    Some(crate::native_context::truncate_text(text, 1_600))
                }
                _ => None,
            })
            .unwrap_or_default();
        let thread_id = agent.thread().id.clone();
        let generation = self.generation;
        self.title_serial = self.title_serial.wrapping_add(1);
        let serial = self.title_serial;
        self.title_running = true;
        self.title_cancel = CancelToken::new();
        let cancel = self.title_cancel.clone();
        let provider = self.config.provider.clone();
        let model = self.config.model.clone();
        self.jobs.push(
            async move {
                let request = Request::new(vec![
                    Message::system(
                        "用不超过 12 个汉字概括对话主题，只输出标题，不要引号、句号或解释。",
                    ),
                    Message::user(format!("用户：{user}\n助手：{assistant}")),
                ])
                .with_max_output_tokens(64.min(model.limits.max_output_tokens));
                let mut generated = String::new();
                if !cancel.is_cancelled() {
                    if let Ok(mut stream) = provider.stream(&model, request).await {
                        while let Some(event) = stream.next().await {
                            if cancel.is_cancelled() {
                                generated.clear();
                                break;
                            }
                            match event {
                                Ok(CompletionEvent::Text(text)) => generated.push_str(&text),
                                Ok(CompletionEvent::Stop(_)) => break,
                                Err(_) => {
                                    generated.clear();
                                    break;
                                }
                                _ => {}
                            }
                        }
                    }
                }
                let title = crate::native_context::clean_thread_title(&generated);
                let title = if title.is_empty() {
                    crate::native_context::clean_thread_title(
                        &crate::native_context::truncate_text(&user, 30),
                    )
                } else {
                    title
                };
                Job::Title {
                    generation,
                    thread_id,
                    serial,
                    title,
                }
            }
            .boxed(),
        );
        self.publish(RuntimeChange::Activity);
    }
}
