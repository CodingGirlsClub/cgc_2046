use super::worker::{Job, Owner, TitleOutcome};
use super::*;
use cgc_agent_core::{project_thread, CancelToken, Entry};
use cgc_agent_provider::{CompletionEvent, Message, Model, Request};
use futures::{FutureExt, StreamExt};

/// 对齐 Zed 的 `SUMMARIZE_THREAD_PROMPT`
/// （`crates/agent_settings/src/prompts/summarize_thread_prompt.txt`）四条约束，
/// 按中文语境改写：简洁 3-7 词、省略标点、直接给标题、包含具体主题、不用第一人称。
const SUMMARIZE_THREAD_PROMPT: &str =
    "为这段对话生成一个简洁的标题（3-7 个词，中文不超过 12 个汉字），省略标点。\n\
直接给出标题，不要任何前缀或引导语（例如不要写“标题：”或“这是一个建议：”）。\n\
如果对话有具体主题，请把主题写进标题。\n\
保持描述性，不要用第一人称。";

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
        // 模型空输出时回退首条用户消息（Zed 不加回退，这里保留产品兜底）。
        let Some(fallback_user) = agent.thread().entries.iter().find_map(|entry| match entry {
            Entry::User { text, .. } => Some(text.clone()),
            _ => None,
        }) else {
            return;
        };
        if fallback_user.trim().is_empty() {
            return;
        }
        // 对齐 Zed 的 `build_thread_title_request`：全量历史 + 摘要提示，
        // 历史投影与 turn 共用 agent_core（含压缩摘要边界与工具调用/结果）。
        let history = project_thread(agent.thread());
        let thread_id = agent.thread().id.clone();
        let generation = self.generation;
        // 用户设置文件每次重新读：改 summary model / temperature 后下一次生成即生效。
        let settings = self
            .production
            .as_ref()
            .map(|_| crate::user_settings::load_default());
        let (provider, model) = self.title_model(settings.as_ref());
        let temperature = settings.as_ref().and_then(|settings| {
            settings.temperature_for_model(model.provider_id.as_str(), model.id.as_str())
        });
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
                let request = title_request(history, temperature, max_output_tokens);
                let outcome = if cancel.is_cancelled() {
                    TitleOutcome::Cancelled
                } else {
                    Self::stream_title(provider, model, request, &cancel, &fallback_user).await
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
        fallback_user: &str,
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
                fallback_user,
                30,
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

    /// 标题生成模型：优先用户设置文件的 `agent.thread_summary_model`，未配置/不可用时
    /// 回退当前对话模型（保证默认仍有标题，对齐 Zed 的 thread summary model 语义）。
    /// 温度由同一文件的 `agent.model_parameters` 决定。
    fn title_model(
        &self,
        settings: Option<&crate::user_settings::UserSettings>,
    ) -> (Arc<dyn Provider>, Model) {
        if let (Some(production), Some(settings)) = (&self.production, settings) {
            if let Some(target) = factory::summary_title_model(production, settings) {
                return target;
            }
        }
        (self.config.provider.clone(), self.config.model.clone())
    }
}

/// 对齐 Zed `build_thread_title_request`：历史消息 + 末尾摘要提示，温度可选。
fn title_request(
    history: Vec<Message>,
    temperature: Option<f32>,
    max_output_tokens: u32,
) -> Request {
    let mut messages = history;
    messages.push(Message::user(SUMMARIZE_THREAD_PROMPT));
    let request = Request::new(messages).with_max_output_tokens(max_output_tokens);
    match temperature {
        Some(temperature) => request.with_temperature(temperature),
        None => request,
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
    // 显式导入：`use super::*` 叠加 glob 链会让 rustc 展开 #[test] 时 SIGBUS。
    use super::{clean_generated_title, title_request, SUMMARIZE_THREAD_PROMPT};
    use cgc_agent_provider::{Message, Role};

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

    #[test]
    fn title_request_keeps_full_history_and_appends_zed_prompt() {
        let history = vec![
            Message::user("第一问"),
            Message::assistant_text("第一答"),
            Message::user("第二问"),
            Message::assistant_text("第二答"),
        ];
        let request = title_request(history, Some(0.2), 64);
        assert_eq!(request.messages.len(), 5);
        assert_eq!(request.messages[0].text(), "第一问");
        assert_eq!(request.messages[3].text(), "第二答");
        let prompt = request.messages.last().expect("prompt appended");
        assert_eq!(prompt.role, Role::User);
        assert_eq!(prompt.text(), SUMMARIZE_THREAD_PROMPT);
        assert_eq!(request.temperature, Some(0.2));
        assert_eq!(request.max_output_tokens, Some(64));
    }

    #[test]
    fn title_request_omits_temperature_when_model_has_none() {
        let request = title_request(vec![Message::user("hi")], None, 32);
        assert_eq!(request.temperature, None);
        assert_eq!(request.max_output_tokens, Some(32));
    }

    #[test]
    fn summarize_prompt_mirrors_zed_rules() {
        assert!(SUMMARIZE_THREAD_PROMPT.contains("3-7 个词"));
        assert!(SUMMARIZE_THREAD_PROMPT.contains("省略标点"));
        assert!(SUMMARIZE_THREAD_PROMPT.contains("不要用第一人称"));
        assert!(SUMMARIZE_THREAD_PROMPT.contains("前缀"));
    }
}
