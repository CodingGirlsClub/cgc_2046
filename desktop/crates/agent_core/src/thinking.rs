use std::{
    collections::hash_map::DefaultHasher,
    hash::{Hash, Hasher},
    io::{self, Write},
};

use cgc_agent_provider::ToolSchema;
use serde::{Deserialize, Serialize};

use crate::{
    context::{valid_summary, RequestPlan},
    Entry, Thread,
};

/// A persisted boundary for reasoning whose signed request prefix is still unchanged.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ThinkingContext {
    pub(crate) range_start: usize,
    summary: Option<usize>,
    pub(crate) thinking_from: usize,
    entry_count: usize,
    prefix: u64,
}

pub(crate) fn prepare(thread: &mut Thread, system: Option<&str>, tools: &[ToolSchema]) {
    let Some(context) = &thread.thinking_context else {
        return;
    };
    let valid = context.range_start <= context.entry_count
        && context.entry_count <= thread.entries.len()
        && context.summary == valid_summary(thread)
        && context.prefix
            == prefix(
                thread,
                system,
                tools,
                context.range_start,
                context.entry_count,
                context.summary,
            );
    if !valid {
        thread.thinking_context.as_mut().unwrap().thinking_from = thread.entries.len();
    }
}

pub(crate) fn capture(
    thread: &mut Thread,
    system: Option<&str>,
    tools: &[ToolSchema],
    plan: &RequestPlan,
) {
    let thinking_from = thread
        .thinking_context
        .as_ref()
        .filter(|context| {
            context.range_start == plan.range.start && context.summary == plan.summary
        })
        .map_or(thread.entries.len(), |context| context.thinking_from);
    thread.thinking_context = Some(ThinkingContext {
        range_start: plan.range.start,
        summary: plan.summary,
        thinking_from,
        entry_count: thread.entries.len(),
        prefix: prefix(
            thread,
            system,
            tools,
            plan.range.start,
            thread.entries.len(),
            plan.summary,
        ),
    });
}

pub(crate) fn active_tool_range(thread: &Thread) -> Option<usize> {
    let context = thread.thinking_context.as_ref()?;
    let mut latest_has_tools = None;
    let mut has_thinking = false;
    for (index, entry) in thread.entries.iter().enumerate().rev() {
        match entry {
            Entry::User { .. } => break,
            Entry::Assistant {
                tool_calls,
                replay_content,
                ..
            } => {
                latest_has_tools.get_or_insert(!tool_calls.is_empty());
                has_thinking |= index >= context.thinking_from
                    && replay_content
                        .iter()
                        .any(cgc_agent_provider::Content::is_thinking);
            }
            _ => {}
        }
    }
    (latest_has_tools == Some(true) && has_thinking).then_some(context.range_start)
}

fn prefix(
    thread: &Thread,
    system: Option<&str>,
    tools: &[ToolSchema],
    start: usize,
    end: usize,
    summary: Option<usize>,
) -> u64 {
    let mut sink = HashSink(DefaultHasher::new());
    // This is a local invalidation fingerprint, not authentication. A hash algorithm
    // change conservatively invalidates old reasoning after an application upgrade.
    serde_json::to_writer(
        &mut sink,
        &(
            system,
            summary.map(|index| &thread.entries[index]),
            &thread.entries[start..end],
        ),
    )
    .expect("thread entries serialize into an infallible hash sink");
    tools.len().hash(&mut sink.0);
    for tool in tools {
        serde_json::to_writer(
            &mut sink,
            &(&tool.name, &tool.description, &tool.input_schema),
        )
        .expect("tool schemas serialize into an infallible hash sink");
    }
    sink.0.finish()
}

struct HashSink(DefaultHasher);
impl Write for HashSink {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0.write(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
