//! 学习 Agent 调用协议（ADR-0029）：内容声明与调用分离。
//!
//! `AgentActionSpec` 是教研人员声明的 CTA；`AgentCall` 是学员点击或选中后由
//! 客户端生成的一次调用。MVP 通过 prompt 中的 `<agent_call>` 数据块把它交给
//! native agent，不扩展 runtime 协议。

use cgc_courses::content::{AgentActionSpec, AgentIntent};
use serde::ser::{Serialize, SerializeStruct, Serializer};

/// 学习动作的投递模式；默认 FillOnly。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum DeliveryMode {
    #[default]
    FillOnly,
    AutoSend,
}

impl DeliveryMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::FillOnly => "fill_only",
            Self::AutoSend => "auto_send",
        }
    }

    pub fn from_value(value: Option<&str>) -> Self {
        match value {
            Some("auto_send") => Self::AutoSend,
            _ => Self::FillOnly,
        }
    }
}

/// 纯投递决策：UI 只执行它，不再各自判断 fill/auto、answer 与草稿保留。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DeliveryDecision {
    Compose {
        prompt: String,
        call: AgentCall,
    },
    Send {
        prompt: String,
        call: AgentCall,
        keep_draft: bool,
    },
}

/// pending action 的目标是否仍指向当前页面。ADR-0029 §7「切换目标即清除」：
/// 目标的 course/issue 与当前 page 身份分离（切 tab、换 issue、离开课程页）
/// 即过期。同页 rerender（正文加载完成等）不改变 course/issue 身份，不清。
pub(crate) fn pending_action_targets_current_page(
    pending: &PendingAgentCall,
    page: Option<&crate::page_context::PageContext>,
) -> bool {
    let Some(page) = page else {
        return false;
    };
    let (course_id, issue_id) = match &pending.call.target {
        LearningTarget::Objective {
            course_id,
            issue_id,
            ..
        }
        | LearningTarget::Issue {
            course_id,
            issue_id,
            ..
        }
        | LearningTarget::Material {
            course_id,
            issue_id,
            ..
        } => (course_id, issue_id),
    };
    let Some(course) = &page.course else {
        return false;
    };
    if &course.id != course_id {
        return false;
    }
    match &course.unit {
        // issue 卡页：unit 即 issue id。
        Some(unit) => &unit.id == issue_id,
        // 课程总览/detail 页没有 issue：issue 级 pending 已不在目标页。
        None => false,
    }
}

/// 调用来源：作者声明的 CTA，或阅读材料时的文本选区。
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentCallSource {
    Action,
    Selection,
}

/// 调用指向的课程对象；用 tagged enum 避免无效的 ID 组合。
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum LearningTarget {
    Issue {
        course_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        revision: Option<i64>,
        issue_id: String,
    },
    Objective {
        course_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        revision: Option<i64>,
        issue_id: String,
        objective_id: String,
    },
    Material {
        course_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        revision: Option<i64>,
        issue_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        objective_id: Option<String>,
        material_id: String,
    },
}

/// 一次学习 Agent 调用。`kind` 由 `Serialize` 固定写入 `agent_call`，避免字段
/// 组合或调用方手写 JSON 时漏掉协议标识。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentCall {
    pub version: u8,
    pub intent: AgentIntent,
    pub target: LearningTarget,
    pub source: AgentCallSource,
    pub action_id: Option<String>,
    pub selection: Option<String>,
}

/// Composer 中待发送的 action；独立于 MessageDraft，发送成功或手动移除即清除。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PendingAgentCall {
    pub call: AgentCall,
    pub label: String,
    pub prompt: String,
}

impl PendingAgentCall {
    pub fn new(call: AgentCall, label: impl Into<String>, prompt: impl Into<String>) -> Self {
        Self {
            call,
            label: label.into(),
            prompt: prompt.into(),
        }
    }
}

impl AgentCall {
    pub fn new(intent: AgentIntent, target: LearningTarget, source: AgentCallSource) -> Self {
        Self {
            version: 1,
            intent,
            target,
            source,
            action_id: None,
            selection: None,
        }
    }

    /// 从作者声明的 CTA 生成调用；`action_id` 保留用于追踪回 CTA。
    pub fn from_action(action: &AgentActionSpec, target: LearningTarget) -> Self {
        Self {
            version: 1,
            intent: action.intent,
            target,
            source: AgentCallSource::Action,
            action_id: Some(action.id.clone()),
            selection: None,
        }
    }

    /// 从材料选区生成调用；material target 必须自带 material_id。
    pub fn from_selection(
        intent: AgentIntent,
        target: LearningTarget,
        selection: impl Into<String>,
    ) -> Self {
        Self {
            version: 1,
            intent,
            target,
            source: AgentCallSource::Selection,
            action_id: None,
            selection: Some(selection.into()),
        }
    }

    /// 生成交给 native agent 的数据块；不包含工具名或工具参数。
    pub fn prompt_block(&self) -> String {
        format!("<agent_call>\n{}\n</agent_call>", self.to_json())
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(self)
            .expect("AgentCall serialization cannot fail for finite fields")
    }
}

impl Serialize for AgentCall {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let mut state = serializer.serialize_struct("AgentCall", 7)?;
        state.serialize_field("kind", "agent_call")?;
        state.serialize_field("version", &self.version)?;
        state.serialize_field("intent", self.intent.as_str())?;
        state.serialize_field("target", &self.target)?;
        state.serialize_field("source", &self.source)?;
        if let Some(action_id) = &self.action_id {
            state.serialize_field("action_id", action_id)?;
        }
        if let Some(selection) = &self.selection {
            state.serialize_field("selection", selection)?;
        }
        state.end()
    }
}

/// 把 action 数据块放在用户 prompt 前面；页面上下文仍由既有 page context
/// 前缀负责，二者不互相覆盖。
pub fn prompt_with_agent_call(prompt: &str, call: &AgentCall) -> String {
    let mut result = call.prompt_block();
    if !prompt.trim().is_empty() {
        result.push_str("\n\n");
        result.push_str(prompt);
    }
    result
}

/// 纯决策：answer 永远 compose；AutoSend 的其它 intent 发送独立消息并保留草稿。
pub fn decide_delivery(
    mode: DeliveryMode,
    call: AgentCall,
    prompt: impl Into<String>,
) -> DeliveryDecision {
    let prompt = prompt.into();
    if mode == DeliveryMode::FillOnly || call.intent == AgentIntent::Answer {
        DeliveryDecision::Compose { prompt, call }
    } else {
        DeliveryDecision::Send {
            prompt,
            call,
            keep_draft: true,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn action(intent: AgentIntent, id: &str) -> AgentActionSpec {
        AgentActionSpec {
            id: id.into(),
            label: "动作".into(),
            intent,
            primary: false,
        }
    }

    fn objective_target() -> LearningTarget {
        LearningTarget::Objective {
            course_id: "crs-001".into(),
            revision: Some(3),
            issue_id: "issue-1".into(),
            objective_id: "obj-1".into(),
        }
    }

    fn material_target() -> LearningTarget {
        LearningTarget::Material {
            course_id: "crs-001".into(),
            revision: Some(3),
            issue_id: "issue-1".into(),
            objective_id: None,
            material_id: "mat-md".into(),
        }
    }

    #[test]
    fn serializes_agent_call_with_target_and_protocol_kind() {
        let call = AgentCall::from_action(&action(AgentIntent::Run, "a-run"), objective_target());
        let value = serde_json::to_value(&call).expect("json");

        assert_eq!(value["kind"], "agent_call");
        assert_eq!(value["version"], 1);
        assert_eq!(value["intent"], "run");
        assert_eq!(value["source"], "action");
        assert_eq!(value["action_id"], "a-run");
        assert_eq!(value["target"]["kind"], "objective");
        assert_eq!(value["target"]["course_id"], "crs-001");
        assert_eq!(value["target"]["revision"], 3);
        assert_eq!(value["target"]["objective_id"], "obj-1");
    }

    #[test]
    fn serializes_selection_call_without_action_or_absent_ids() {
        let call = AgentCall::from_selection(
            AgentIntent::Explain,
            material_target(),
            "选中的 Markdown 原文",
        );
        let value = serde_json::to_value(&call).expect("json");

        assert_eq!(value["source"], "selection");
        assert_eq!(value["selection"], "选中的 Markdown 原文");
        assert!(value.get("action_id").is_none());
        assert_eq!(value["target"]["kind"], "material");
        assert_eq!(value["target"]["material_id"], "mat-md");
        assert!(value["target"].get("objective_id").is_none());
    }

    #[test]
    fn prompt_block_is_placed_before_the_user_prompt() {
        let call = AgentCall::from_action(&action(AgentIntent::Hint, "a-hint"), objective_target());
        let prompt = prompt_with_agent_call("请给我一个提示", &call);

        assert!(prompt.starts_with("<agent_call>\n"));
        assert!(prompt.contains("\"kind\": \"agent_call\""));
        assert!(prompt.ends_with("</agent_call>\n\n请给我一个提示"));
    }

    #[test]
    fn delivery_mode_round_trips_wire_values() {
        assert_eq!(DeliveryMode::FillOnly.as_str(), "fill_only");
        assert_eq!(DeliveryMode::AutoSend.as_str(), "auto_send");
        assert_eq!(
            DeliveryMode::from_value(Some("auto_send")),
            DeliveryMode::AutoSend
        );
        assert_eq!(
            DeliveryMode::from_value(Some("unknown")),
            DeliveryMode::FillOnly
        );
        assert_eq!(DeliveryMode::from_value(None), DeliveryMode::FillOnly);
    }

    #[test]
    fn fill_only_and_answer_always_compose() {
        let fill = decide_delivery(
            DeliveryMode::FillOnly,
            AgentCall::from_action(&action(AgentIntent::Run, "a-run"), objective_target()),
            "run",
        );
        assert!(matches!(fill, DeliveryDecision::Compose { .. }));

        let answer = decide_delivery(
            DeliveryMode::AutoSend,
            AgentCall::from_action(&action(AgentIntent::Answer, "a-answer"), objective_target()),
            "answer",
        );
        assert!(matches!(answer, DeliveryDecision::Compose { .. }));
    }

    #[test]
    fn auto_send_dispatches_other_intents_and_keeps_the_draft() {
        let decision = decide_delivery(
            DeliveryMode::AutoSend,
            AgentCall::from_action(&action(AgentIntent::Hint, "a-hint"), objective_target()),
            "hint",
        );

        match decision {
            DeliveryDecision::Send { keep_draft, .. } => assert!(keep_draft),
            DeliveryDecision::Compose { .. } => panic!("hint must auto-send"),
        }
    }
}
