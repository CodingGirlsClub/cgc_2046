use super::*;
use agent_client_protocol::schema::v1::{
    AvailableCommand, ContentBlock, PermissionOption, PermissionOptionKind, SessionConfigKind,
    SessionConfigOption, SessionConfigOptionCategory, SessionConfigSelectOptions, SessionUpdate,
    ToolCall, ToolCallContent, ToolCallLocation, ToolCallStatus,
};
use agent_client_protocol::schema::MaybeUndefined;

fn debug_label(value: impl std::fmt::Debug) -> String {
    format!("{value:?}").to_lowercase()
}

pub(super) fn tool_status_label(status: ToolCallStatus) -> String {
    match status {
        ToolCallStatus::Pending => "pending",
        ToolCallStatus::InProgress => "in_progress",
        ToolCallStatus::Completed => "completed",
        ToolCallStatus::Failed => "failed",
        _ => "unknown",
    }
    .to_string()
}

pub(super) fn tool_output_text(
    raw_output: Option<&serde_json::Value>,
    content: &[ToolCallContent],
) -> Option<String> {
    let mut parts = Vec::new();
    if let Some(raw_output) = raw_output {
        parts.push(json_text(raw_output));
    }
    for item in content {
        match item {
            ToolCallContent::Content(content) => {
                if let ContentBlock::Text(text) = &content.content {
                    parts.push(text.text.clone());
                }
            }
            ToolCallContent::Diff(diff) => {
                let mut text = format!("diff: {}", diff.path.display());
                if let Some(old_text) = &diff.old_text {
                    text.push_str("\n--- old\n");
                    text.push_str(old_text);
                }
                text.push_str("\n+++ new\n");
                text.push_str(&diff.new_text);
                parts.push(text);
            }
            ToolCallContent::Terminal(terminal) => {
                parts.push(format!("terminal: {}", terminal.terminal_id.0));
            }
            _ => {}
        }
    }
    (!parts.is_empty()).then(|| parts.join("\n"))
}

pub(super) fn tool_locations(locations: &[ToolCallLocation]) -> Vec<String> {
    locations
        .iter()
        .map(|location| match location.line {
            Some(line) => format!("{}:{line}", location.path.display()),
            None => location.path.display().to_string(),
        })
        .collect()
}

pub(super) fn tool_call_view(call: ToolCall) -> ToolCallView {
    ToolCallView {
        tool_call_id: call.tool_call_id.0.to_string(),
        title: call.title,
        name: call.name,
        kind: format!("{:?}", call.kind),
        status: tool_status_label(call.status),
        args: call.raw_input.as_ref().map(json_text),
        output: tool_output_text(call.raw_output.as_ref(), &call.content),
        locations: tool_locations(&call.locations),
    }
}

/// 把 ACP `session/update` 映射成 UI 事件；未识别/不再关心的变体返回 `None`。
pub(super) fn host_event_from_update(update: SessionUpdate) -> Option<HostEvent> {
    match update {
        SessionUpdate::AgentMessageChunk(chunk) => match chunk.content {
            ContentBlock::Text(text) => Some(HostEvent::Delta(text.text)),
            _ => None,
        },
        SessionUpdate::AgentThoughtChunk(chunk) => match chunk.content {
            ContentBlock::Text(text) => Some(HostEvent::ThoughtDelta(text.text)),
            _ => None,
        },
        SessionUpdate::UserMessageChunk(chunk) => match chunk.content {
            ContentBlock::Text(text) => Some(HostEvent::UserMessage(text.text)),
            _ => None,
        },
        SessionUpdate::AvailableCommandsUpdate(update) => Some(HostEvent::AvailableCommands {
            commands: command_views(update.available_commands),
        }),
        SessionUpdate::ToolCall(call) => Some(HostEvent::ToolCall {
            call: tool_call_view(call),
        }),
        SessionUpdate::ToolCallUpdate(update) => Some(HostEvent::ToolCallUpdated {
            tool_call_id: update.tool_call_id.0.to_string(),
            title: update.fields.title,
            status: update.fields.status.map(tool_status_label),
            output: tool_output_text(
                update.fields.raw_output.as_ref(),
                update.fields.content.as_deref().unwrap_or(&[]),
            ),
            args: update.fields.raw_input.as_ref().map(json_text),
            locations: update.fields.locations.as_deref().map(tool_locations),
        }),
        SessionUpdate::Plan(plan) => Some(HostEvent::PlanUpdated {
            steps: plan
                .entries
                .into_iter()
                .map(|entry| PlanStepView {
                    content: entry.content,
                    priority: debug_label(entry.priority),
                    status: debug_label(entry.status),
                })
                .collect(),
        }),
        SessionUpdate::UsageUpdate(usage) => Some(HostEvent::UsageUpdated {
            used: usage.used,
            size: usage.size,
            cost: usage.cost.map(|cost| {
                let precision = if cost.amount != 0.0 && cost.amount < 0.01 {
                    4
                } else {
                    2
                };
                format!("{:.precision$} {}", cost.amount, cost.currency)
            }),
        }),
        SessionUpdate::ConfigOptionUpdate(update) => Some(HostEvent::ConfigOptions {
            options: config_option_views(&update.config_options),
        }),
        SessionUpdate::CurrentModeUpdate(update) => Some(HostEvent::ModeUpdated {
            mode_id: update.current_mode_id.0.to_string(),
        }),
        SessionUpdate::SessionInfoUpdate(update) => Some(HostEvent::TitleUpdated {
            title: match update.title {
                MaybeUndefined::Value(title) => Some(title),
                _ => None,
            },
        }),
        SessionUpdate::CompactionUpdate(update) => Some(HostEvent::CompactionUpdated {
            status: debug_label(update.status),
            summary: match update.summary {
                MaybeUndefined::Value(blocks) => {
                    let text = blocks
                        .iter()
                        .filter_map(|block| match block {
                            ContentBlock::Text(text) => Some(text.text.clone()),
                            _ => None,
                        })
                        .collect::<Vec<_>>()
                        .join("\n");
                    (!text.is_empty()).then_some(text)
                }
                _ => match update.error {
                    MaybeUndefined::Value(error) => Some(error),
                    _ => None,
                },
            },
        }),
        _ => None,
    }
}

pub(super) fn command_views(commands: Vec<AvailableCommand>) -> Vec<CommandView> {
    commands
        .into_iter()
        .map(|command| CommandView {
            name: command.name,
            description: command.description,
            requires_argument: command.input.is_some(),
        })
        .collect()
}

pub(super) fn permission_option_kind_label(kind: PermissionOptionKind) -> &'static str {
    match kind {
        PermissionOptionKind::AllowOnce => "allow_once",
        PermissionOptionKind::AllowAlways => "allow_always",
        PermissionOptionKind::RejectOnce => "reject_once",
        PermissionOptionKind::RejectAlways => "reject_always",
        _ => "other",
    }
}

pub(super) fn permission_option_views(options: &[PermissionOption]) -> Vec<PermissionOptionView> {
    options
        .iter()
        .map(|option| PermissionOptionView {
            option_id: option.option_id.0.to_string(),
            name: option.name.clone(),
            kind: permission_option_kind_label(option.kind).to_string(),
        })
        .collect()
}

pub(super) fn config_category(
    category: &Option<SessionConfigOptionCategory>,
) -> ConfigOptionCategory {
    match category {
        Some(SessionConfigOptionCategory::Mode) => ConfigOptionCategory::Mode,
        Some(SessionConfigOptionCategory::Model) => ConfigOptionCategory::Model,
        Some(SessionConfigOptionCategory::ModelConfig) => ConfigOptionCategory::ModelConfig,
        Some(SessionConfigOptionCategory::ThoughtLevel) => ConfigOptionCategory::ThoughtLevel,
        _ => ConfigOptionCategory::Other,
    }
}

pub(super) fn config_option_views(options: &[SessionConfigOption]) -> Vec<ConfigOptionView> {
    options
        .iter()
        .filter_map(|option| match &option.kind {
            SessionConfigKind::Select(select) => {
                let values = match &select.options {
                    SessionConfigSelectOptions::Ungrouped(options) => options
                        .iter()
                        .map(|value| (value.value.0.to_string(), value.name.clone()))
                        .collect(),
                    SessionConfigSelectOptions::Grouped(groups) => groups
                        .iter()
                        .flat_map(|group| {
                            group
                                .options
                                .iter()
                                .map(|value| (value.value.0.to_string(), value.name.clone()))
                        })
                        .collect(),
                    _ => Vec::new(),
                };
                Some(ConfigOptionView {
                    id: option.id.0.to_string(),
                    name: option.name.clone(),
                    category: config_category(&option.category),
                    current: select.current_value.0.to_string(),
                    values,
                })
            }
            SessionConfigKind::Boolean(value) => Some(ConfigOptionView {
                id: option.id.0.to_string(),
                name: option.name.clone(),
                category: config_category(&option.category),
                current: value.current_value.to_string(),
                values: vec![
                    ("true".to_string(), "开".to_string()),
                    ("false".to_string(), "关".to_string()),
                ],
            }),
            _ => None,
        })
        .collect()
}
