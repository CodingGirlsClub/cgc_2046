//! Model projection is a contiguous suffix of complete user turns, never a bag of messages.
//! Token counts here are estimates; provider usage and unknown image costs remain distinct.

use std::{io, ops::Range};

use cgc_agent_provider::{Content, Message, Model, Request, Role, ToolSchema};

use crate::{AgentError, Entry, Thread};

const PROTOCOL_RESERVE: usize = 32;

#[cfg(test)]
mod tests;

pub(crate) struct RequestPlan {
    pub range: Range<usize>,
    pub covered_until: usize,
    pub summary: Option<usize>,
    pub summary_limit: usize,
    pub estimated_tokens: usize,
    pub image_cost_unknown: bool,
    pub preserve_prefix: bool,
}

impl RequestPlan {
    pub fn select(
        thread: &Thread,
        model: &Model,
        system: Option<&str>,
        tools: &[ToolSchema],
    ) -> Result<Self, AgentError> {
        let capacity = input_capacity(model);
        let fixed = system.map_or(0, text_tokens) + tools.iter().map(schema_tokens).sum::<usize>();
        let summary = valid_summary(thread);
        let covered_until = summary.map_or(0, |index| coverage(&thread.entries[index]));
        let summary_cost = summary.map_or(0, |index| match &thread.entries[index] {
            Entry::Compaction { summary, .. } => text_tokens(summary) + 12,
            _ => 0,
        });
        let thinking_from = thread
            .thinking_context
            .as_ref()
            .map_or(0, |context| context.thinking_from);
        let image_cost_unknown = thread.entries[covered_until..].iter().any(has_image);
        // Actual usage is a lower bound for the previous request, not a replacement for
        // newly injected context. Scale history only when observed usage exceeds our estimate.
        let observed = thread
            .entries
            .iter()
            .enumerate()
            .rev()
            .find_map(|(index, entry)| {
                if let Entry::Assistant {
                    usage: Some(usage), ..
                } = entry
                {
                    // Input already includes cached tokens; cache fields are billing diagnostics.
                    Some((index, usage.input.saturating_add(usage.output) as usize))
                } else {
                    None
                }
            });
        let correction = observed
            .filter(|(index, _)| {
                *index >= summary.unwrap_or(covered_until)
                    && (*index >= thinking_from
                        || !thread.entries[covered_until..=*index].iter().any(|entry| {
                            matches!(entry, Entry::Assistant { replay_content, .. }
                                if replay_content.iter().any(Content::is_thinking))
                        }))
            })
            .map(|(index, usage)| {
                let old = entries_tokens(thread, covered_until..index + 1);
                (
                    index,
                    usage.saturating_sub(fixed + summary_cost + old),
                    old.max(1),
                )
            });
        let cost_for = |range: Range<usize>| {
            let raw = entries_tokens(thread, range.clone());
            let extra = correction.map_or(0, |(index, extra, old)| {
                if range.start > index {
                    return 0;
                }
                entries_tokens(thread, range.start..range.end.min(index + 1))
                    .saturating_mul(extra)
                    .div_ceil(old)
            });
            raw.saturating_add(extra)
        };
        let frozen_start = crate::thinking::active_tool_range(thread);
        let mut start = frozen_start.unwrap_or(covered_until);
        let mut kept_cost = cost_for(start..thread.entries.len());
        let total = fixed + summary_cost + kept_cost;
        if total > capacity {
            // A tool continuation must keep the exact prefix that produced its signatures.
            if frozen_start.is_some() {
                return Err(AgentError::ContextTooLarge {
                    estimated_tokens: total
                        + PROTOCOL_RESERVE
                        + model.limits.max_output_tokens as usize,
                    context_window: model.limits.context_window,
                    image_cost_unknown,
                });
            }
            let mut starts =
                turn_starts(&thread.entries, covered_until..thread.entries.len()).rev();
            start = starts.next().unwrap_or(covered_until);
            kept_cost = cost_for(start..thread.entries.len());
            if fixed + summary_cost + kept_cost > capacity {
                return Err(AgentError::ContextTooLarge {
                    estimated_tokens: fixed
                        + summary_cost
                        + kept_cost
                        + PROTOCOL_RESERVE
                        + model.limits.max_output_tokens as usize,
                    context_window: model.limits.context_window,
                    image_cost_unknown,
                });
            }
            let reserve = (capacity / 4)
                .min(model.limits.max_output_tokens as usize)
                .max(summary_cost)
                .min(capacity - fixed - kept_cost);
            for previous in starts {
                let cost = cost_for(previous..start);
                if fixed + kept_cost + cost + reserve > capacity {
                    break;
                }
                kept_cost += cost;
                start = previous;
            }
        }
        Ok(Self {
            range: start..thread.entries.len(),
            covered_until,
            summary,
            summary_limit: capacity
                .saturating_sub(fixed + kept_cost + 12)
                .min(model.limits.max_output_tokens as usize),
            estimated_tokens: fixed
                + summary_cost
                + kept_cost
                + PROTOCOL_RESERVE
                + model.limits.max_output_tokens as usize,
            image_cost_unknown: thread.entries[start..].iter().any(has_image),
            preserve_prefix: frozen_start.is_some(),
        })
    }

    pub fn omitted(&self) -> usize {
        self.range.start - self.covered_until
    }

    pub fn messages(&self, thread: &Thread, system: Option<&str>) -> Vec<Message> {
        let mut messages = Vec::new();
        if let Some(system) = system {
            messages.push(Message::system(system));
        }
        if let Some(index) = self.summary {
            if let Entry::Compaction { summary, .. } = &thread.entries[index] {
                messages.push(Message::system(format!("历史摘要：{summary}")));
            }
        }
        let thinking_from = thread.thinking_context.as_ref().map_or(0, |context| {
            context.thinking_from.saturating_sub(self.range.start)
        });
        messages.extend(project_entries_after(
            &thread.entries[self.range.clone()],
            thinking_from,
        ));
        messages
    }
}

/// All request branches, including bounded summaries, set model options here.
pub(crate) fn assemble(
    messages: Vec<Message>,
    tools: Vec<ToolSchema>,
    model: &Model,
    reasoning_effort: Option<String>,
    temperature: Option<f32>,
    output_limit: Option<usize>,
) -> Request {
    let request = Request::new(messages)
        .with_tools(tools)
        .with_reasoning_effort(reasoning_effort)
        .with_max_output_tokens(
            output_limit.map_or(model.limits.max_output_tokens, |limit| limit as u32),
        );
    match temperature {
        Some(temperature) => request.with_temperature(temperature),
        None => request,
    }
}

pub fn input_capacity(model: &Model) -> usize {
    (model.limits.context_window as usize)
        .saturating_sub(model.limits.max_output_tokens as usize + PROTOCOL_RESERVE)
}

pub(crate) fn valid_summary(thread: &Thread) -> Option<usize> {
    thread
        .entries
        .iter()
        .enumerate()
        .rev()
        .find_map(|(index, entry)| {
            if let Entry::Compaction {
                covered_until: Some(end),
                summary,
                ..
            } = entry
            {
                let boundary =
                    *end == index || matches!(thread.entries.get(*end), Some(Entry::User { .. }));
                if *end > 0 && *end <= index && boundary && !summary.trim().is_empty() {
                    return Some(index);
                }
            }
            None
        })
}

fn coverage(entry: &Entry) -> usize {
    match entry {
        Entry::Compaction {
            covered_until: Some(end),
            ..
        } => *end,
        _ => 0,
    }
}

/// 把整个 thread 投影成 provider 消息（含压缩摘要边界，保留工具调用/结果与图片）。
/// 标题生成等「旁路请求」与 turn 共用同一份历史投影，避免两套裁剪语义。
pub fn project_thread(thread: &Thread) -> Vec<Message> {
    let summary = valid_summary(thread);
    let start = summary.map_or(0, |index| coverage(&thread.entries[index]));
    let mut messages = Vec::new();
    if let Some(index) = summary {
        if let Entry::Compaction { summary, .. } = &thread.entries[index] {
            messages.push(Message::system(format!("历史摘要：{summary}")));
        }
    }
    messages.extend(project_entries(&thread.entries[start..]));
    messages
}

pub(crate) fn turn_starts(
    entries: &[Entry],
    range: Range<usize>,
) -> impl DoubleEndedIterator<Item = usize> + '_ {
    range.filter(move |&index| matches!(entries[index], Entry::User { .. }))
}

/// Incomplete legacy tool batches are omitted as a whole. Results are emitted only
/// alongside their complete assistant batch, so malformed/restored history is legal.
pub(crate) fn project_entries(entries: &[Entry]) -> Vec<Message> {
    project_entries_after(entries, 0)
}

fn project_entries_after(entries: &[Entry], thinking_from: usize) -> Vec<Message> {
    let mut messages = Vec::new();
    for (index, entry) in entries.iter().enumerate() {
        match entry {
            Entry::User { text, images, .. } => {
                let mut message = Message::user(text);
                message
                    .content
                    .extend(images.iter().map(|image| Content::Image {
                        mime_type: image.mime_type.clone(),
                        data: image.data.clone(),
                    }));
                messages.push(message);
            }
            Entry::Assistant {
                text,
                tool_calls,
                replay_content,
                ..
            } if tool_calls.is_empty() => {
                if !replay_content.is_empty() {
                    let content: Vec<_> = replay_content
                        .iter()
                        .filter(|block| index >= thinking_from || !block.is_thinking())
                        .cloned()
                        .collect();
                    if !content.is_empty() {
                        messages.push(Message::new(Role::Assistant, content));
                    }
                } else if !text.is_empty() {
                    messages.push(Message::assistant_text(text));
                }
            }
            Entry::Assistant {
                text,
                tool_calls,
                replay_content,
                ..
            } => {
                let tail = &entries[index + 1..];
                let end = tail
                    .iter()
                    .position(|entry| matches!(entry, Entry::User { .. } | Entry::Assistant { .. }))
                    .unwrap_or(tail.len());
                let results = &tail[..end];
                let result_count = results
                    .iter()
                    .filter(|entry| matches!(entry, Entry::ToolResult { .. }))
                    .count();
                if result_count != tool_calls.len() || tool_calls.iter().enumerate().any(|(offset, call)| {
                    tool_calls[..offset].iter().any(|previous| previous.id == call.id)
                        || results.iter().filter(|entry| matches!(entry, Entry::ToolResult { tool_use_id, .. } if tool_use_id == &call.id)).count() != 1
                }) {
                    continue;
                }
                let content = if replay_content.is_empty() {
                    let mut content = Vec::with_capacity(tool_calls.len() + 1);
                    if !text.is_empty() {
                        content.push(Content::Text(text.clone()));
                    }
                    content.extend(tool_calls.iter().cloned().map(Content::ToolUse));
                    content
                } else {
                    replay_content
                        .iter()
                        .filter(|block| index >= thinking_from || !block.is_thinking())
                        .cloned()
                        .collect()
                };
                messages.push(Message::new(Role::Assistant, content));
                messages.extend(results.iter().filter_map(|entry| match entry {
                    Entry::ToolResult {
                        tool_use_id,
                        content,
                        is_error,
                        ..
                    } => Some(Message::tool_result(tool_use_id, content, *is_error)),
                    _ => None,
                }));
            }
            Entry::Thinking { .. } | Entry::ToolResult { .. } | Entry::Compaction { .. } => {}
        }
    }
    messages
}

// ASCII is deliberately estimated more conservatively than chars/4; UTF-8 text
// uses byte pairs, not an English-only character ratio. Images remain unknown.
pub(crate) fn text_tokens(text: &str) -> usize {
    let ascii = text.bytes().filter(u8::is_ascii).count();
    ascii.div_ceil(3) + (text.len() - ascii).div_ceil(2) + 8
}

struct JsonSize(usize);
impl io::Write for JsonSize {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0 += bytes.len();
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
fn json_tokens(value: &serde_json::Value) -> usize {
    let mut size = JsonSize(0);
    serde_json::to_writer(&mut size, value).expect("JSON values serialize to a counting sink");
    size.0.div_ceil(2)
}
fn schema_tokens(schema: &ToolSchema) -> usize {
    text_tokens(&schema.name) + text_tokens(&schema.description) + json_tokens(&schema.input_schema)
}
fn has_image(entry: &Entry) -> bool {
    matches!(entry, Entry::User { images, .. } if !images.is_empty())
}
fn entries_tokens(thread: &Thread, range: Range<usize>) -> usize {
    let thinking_from = thread
        .thinking_context
        .as_ref()
        .map_or(thread.entries.len(), |context| context.thinking_from);
    let start = range.start;
    thread.entries[range]
        .iter()
        .enumerate()
        .map(|(index, entry)| entry_tokens(entry, start + index >= thinking_from))
        .sum()
}
fn entry_tokens(entry: &Entry, include_thinking: bool) -> usize {
    match entry {
        Entry::User { text, images, .. } => text_tokens(text) + images.len() * 24,
        Entry::Assistant {
            text,
            tool_calls,
            replay_content,
            ..
        } => {
            text_tokens(text)
                + tool_calls
                    .iter()
                    .map(|call| text_tokens(&call.name) + json_tokens(&call.args))
                    .sum::<usize>()
                + if include_thinking {
                    replay_content
                        .iter()
                        .map(|content| match content {
                            Content::Thinking { text, .. } => text_tokens(text),
                            Content::RedactedThinking { data } => text_tokens(data),
                            _ => 0,
                        })
                        .sum::<usize>()
                } else {
                    0
                }
        }
        Entry::ToolResult { content, .. } => text_tokens(content),
        Entry::Thinking { .. } | Entry::Compaction { .. } => 0,
    }
}
