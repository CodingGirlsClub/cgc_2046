use super::worker::{Job, Owner, TitleOutcome};
use super::*;
use cgc_agent_core::{CancelToken, Entry};
use cgc_agent_provider::{CompletionEvent, Message, Request};
use futures::{FutureExt, StreamExt};

impl Owner {
    /// 后台生成 thread title（对齐 Zed：turn 完成后 title 为空时自动触发，
    /// 生成期间不占用 owner，也不阻塞下一轮 turn）。
    pub(super) fn start_title(&mut self, force: bool) {
        if self.active.is_some() {
            // turn 期间 agent 在 turn job 手里，等收尾时补生成。
            self.pending_title = Some(force);
            return;
        }
        if self.title_running {
            if !force {
                return;
            }
            // 手动 regenerate 覆盖正在跑的生成；UI 在生成中会隐藏入口，这里兜底。
            self.cancel_title();
        }
        if force {
            if let Some(agent) = self.agent.as_mut() {
                agent.set_thread_title(None);
                agent.set_thread_title_override(None);
            }
        }
        let Some(agent) = self.agent.as_ref() else {
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
        let Some(user) = agent.thread().entries.iter().find_map(|entry| match entry {
            Entry::User { text, .. } => Some(crate::native_context::truncate_text(text, 1_200)),
            _ => None,
        }) else {
            return;
        };
        if user.is_empty() {
            return;
        }
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
        let (provider, model) = self.title_model();
        self.title_generation_error = None;
        self.pending_generated_title = None;
        self.title_serial = self.title_serial.wrapping_add(1);
        let serial = self.title_serial;
        self.title_running = true;
        self.title_cancel = CancelToken::new();
        let cancel = self.title_cancel.clone();
        let max_output_tokens = 64.min(model.limits.max_output_tokens);
        self.jobs.push(
            async move {
                let request = Request::new(vec![
                    Message::system(
                        "用不超过 12 个汉字概括对话主题，只输出标题，不要引号、句号或解释。",
                    ),
                    Message::user(format!("用户：{user}\n助手：{assistant}")),
                ])
                .with_max_output_tokens(max_output_tokens);
                let outcome = if cancel.is_cancelled() {
                    TitleOutcome::Cancelled
                } else {
                    Self::stream_title(provider, model, request, &cancel, &user).await
                };
                Job::Title {
                    generation,
                    thread_id,
                    serial,
                    outcome,
                }
            }
            .boxed(),
        );
        self.publish(RuntimeChange::Activity);
    }

    /// 生成标题的流式收口：错误/取消保留给调用方区分，空输出回退首条用户消息。
    async fn stream_title(
        provider: Arc<dyn Provider>,
        model: Model,
        request: Request,
        cancel: &CancelToken,
        user: &str,
    ) -> TitleOutcome {
        let mut generated = String::new();
        let mut stream = match provider.stream(&model, request).await {
            Ok(stream) => stream,
            Err(error) => return TitleOutcome::Failed(error.to_string()),
        };
        while let Some(event) = stream.next().await {
            if cancel.is_cancelled() {
                return TitleOutcome::Cancelled;
            }
            match event {
                Ok(CompletionEvent::Text(text)) => generated.push_str(&text),
                Ok(CompletionEvent::Stop(_)) => break,
                Err(error) => return TitleOutcome::Failed(error.to_string()),
                _ => {}
            }
        }
        let title = clean_generated_title(&generated);
        let title = if title.is_empty() {
            crate::native_context::clean_thread_title(&crate::native_context::truncate_text(
                user, 30,
            ))
        } else {
            title
        };
        if title.is_empty() {
            TitleOutcome::Failed("模型未返回可用标题".into())
        } else {
            TitleOutcome::Generated(title)
        }
    }

    /// 标题生成模型：优先 prefs 里的独立 summary model，未配置/不可用时
    /// 回退当前对话模型（保证默认仍有标题，对齐 Zed 的 thread summary model 语义）。
    fn title_model(&self) -> (Arc<dyn Provider>, Model) {
        if let Some(production) = &self.production {
            if let Some(target) = factory::summary_title_model(production) {
                return target;
            }
        }
        (self.config.provider.clone(), self.config.model.clone())
    }
}

/// 对齐 Zed 的 `stream_thread_title`：只取首行，模型多写的解释不进入标题。
fn clean_generated_title(raw: &str) -> String {
    let first_line = raw
        .lines()
        .find(|line| !line.trim().is_empty())
        .unwrap_or("");
    crate::native_context::clean_thread_title(first_line)
}

#[cfg(test)]
mod tests {
    use super::clean_generated_title;

    #[test]
    fn title_takes_first_non_empty_line_and_strips_wrapping_quotes() {
        assert_eq!(clean_generated_title("第一行\n第二行"), "第一行");
        assert_eq!(clean_generated_title("\n\n「标题」\n解释"), "标题");
        assert_eq!(
            clean_generated_title("\"带引号的标题。\"\n说明"),
            "带引号的标题"
        );
    }

    #[test]
    fn empty_output_cleans_to_empty_string() {
        assert_eq!(clean_generated_title(""), "");
        assert_eq!(clean_generated_title("  \n\n  "), "");
    }
}
