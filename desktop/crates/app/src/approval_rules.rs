//! settings 级审批规则（Stage 3.2b）：按工具名 + 参数 JSON 决定 allow/deny/confirm。
//!
//! 存储沿用桌面端 `preferences.json` 的 `toolPermissions`（不改后端、不动账户级）：
//! ```json
//! {
//!   "toolPermissions": {
//!     "default": "ask",
//!     "tools": {
//!       "run_command": { "alwaysAllow": ["^ls"], "alwaysDeny": ["rm -rf"], "alwaysConfirm": ["git push"] }
//!     }
//!   }
//! }
//! ```
//! 优先级：deny > allow > confirm > default(ask)。匹配对象 = 工具名或参数 JSON
//! 序列化字符串（command 等参数子串都能命中）；非法正则忽略并记录 warning，不 panic。
//!
//! 路线 A（Zed 对齐）：settings 级规则**只作用于 native agent**。native 在弹卡前
//! 判定：allow/deny 决定性且请求里有对应 kind 的 option 时自动回传、不弹卡，并在
//! 会话里补一条 Notice；ask/confirm 或无匹配类 option 时回退共享权限卡（不误放行）。
//! external ACP agent 的审批完全由 agent 自身模式与 options 决定，客户端只渲染共享
//! 审批卡并按用户选择回传，**不做策略拦截/自动决定**（[`auto_permission_for_event`]
//! 仅 native 轨使用）。

use std::collections::BTreeMap;

use regex::Regex;
use serde::{Deserialize, Serialize};

use cgc_platform::acp::connection::HostEvent;

use crate::agent_ingest;

/// 未命中任何工具规则时的默认策略（`toolPermissions.default`）。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ToolPermissionDefault {
    /// 弹共享权限卡（默认）。
    #[default]
    Ask,
    /// 一律自动允许。
    Allow,
    /// 一律自动拒绝。
    Deny,
    /// 一律强制询问（即使 default=allow 也弹卡）。
    Confirm,
}

/// 单个工具的规则；每个字段是正则列表，命中任一即生效。
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ToolRuleSet {
    pub always_allow: Vec<String>,
    pub always_deny: Vec<String>,
    pub always_confirm: Vec<String>,
}

/// `preferences.json` 里的 `toolPermissions` 配置（MVP 无设置 GUI，手改文件）。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ToolPermissionSettings {
    #[serde(deserialize_with = "deserialize_tool_permission_default")]
    pub default: ToolPermissionDefault,
    /// 工具名 → 规则；工具名精确匹配（不区分大小写暂不支持，见报告）。
    pub tools: BTreeMap<String, ToolRuleSet>,
}

impl Default for ToolPermissionSettings {
    fn default() -> Self {
        Self {
            default: ToolPermissionDefault::Ask,
            tools: BTreeMap::new(),
        }
    }
}

/// 配置容错：未知/非法 default 值回落 `ask`，而不是让整份 toolPermissions 失效。
fn deserialize_tool_permission_default<'de, D>(
    deserializer: D,
) -> Result<ToolPermissionDefault, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<serde_json::Value>::deserialize(deserializer)?;
    Ok(match value.as_ref().and_then(serde_json::Value::as_str) {
        Some("allow") => ToolPermissionDefault::Allow,
        Some("deny") => ToolPermissionDefault::Deny,
        Some("confirm") => ToolPermissionDefault::Confirm,
        _ => ToolPermissionDefault::Ask,
    })
}

/// 规则判定结果（`Ask`/`Confirm` 都由 UI 弹共享卡；MVP 不区分）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RuleDecision {
    Allow,
    Deny,
    Confirm,
    Ask,
}

#[derive(Debug, Default)]
struct CompiledRuleSet {
    always_allow: Vec<Regex>,
    always_deny: Vec<Regex>,
    always_confirm: Vec<Regex>,
}

/// 编译后的审批规则；`warnings` 记录被忽略的非法正则（同时打到 stderr）。
#[derive(Debug, Default)]
pub struct ApprovalRules {
    default: ToolPermissionDefault,
    tools: BTreeMap<String, CompiledRuleSet>,
    pub warnings: Vec<String>,
}

impl ApprovalRules {
    pub fn from_settings(settings: &ToolPermissionSettings) -> Self {
        let mut rules = Self {
            default: settings.default,
            tools: BTreeMap::new(),
            warnings: Vec::new(),
        };
        for (tool, rule_set) in &settings.tools {
            let compiled = CompiledRuleSet {
                always_allow: compile_patterns(
                    tool,
                    "alwaysAllow",
                    &rule_set.always_allow,
                    &mut rules.warnings,
                ),
                always_deny: compile_patterns(
                    tool,
                    "alwaysDeny",
                    &rule_set.always_deny,
                    &mut rules.warnings,
                ),
                always_confirm: compile_patterns(
                    tool,
                    "alwaysConfirm",
                    &rule_set.always_confirm,
                    &mut rules.warnings,
                ),
            };
            rules.tools.insert(tool.clone(), compiled);
        }
        for warning in &rules.warnings {
            // 配置错误只记录、不 panic；不使用 tracing（app 无日志设施，MVP）。
            eprintln!("[approval_rules] {warning}");
        }
        rules
    }

    /// 从本地 `preferences.json` 读取规则（每次审批请求读一次，手改文件即时生效）。
    pub fn load() -> Self {
        Self::from_settings(&crate::preferences::load().tool_permissions)
    }

    /// 优先级 deny > allow > confirm > default；匹配对象 = 工具名或参数 JSON 文本。
    pub fn decide(&self, tool: Option<&str>, args: Option<&str>) -> RuleDecision {
        if let Some(rule_set) = tool.and_then(|tool| self.tools.get(tool)) {
            if matches_any(&rule_set.always_deny, tool, args) {
                return RuleDecision::Deny;
            }
            if matches_any(&rule_set.always_allow, tool, args) {
                return RuleDecision::Allow;
            }
            if matches_any(&rule_set.always_confirm, tool, args) {
                return RuleDecision::Confirm;
            }
        }
        match self.default {
            ToolPermissionDefault::Ask => RuleDecision::Ask,
            ToolPermissionDefault::Allow => RuleDecision::Allow,
            ToolPermissionDefault::Deny => RuleDecision::Deny,
            ToolPermissionDefault::Confirm => RuleDecision::Confirm,
        }
    }
}

fn matches_any(regexes: &[Regex], tool: Option<&str>, args: Option<&str>) -> bool {
    regexes.iter().any(|regex| {
        tool.is_some_and(|tool| regex.is_match(tool))
            || args.is_some_and(|args| regex.is_match(args))
    })
}

fn compile_patterns(
    tool: &str,
    field: &str,
    patterns: &[String],
    warnings: &mut Vec<String>,
) -> Vec<Regex> {
    patterns
        .iter()
        .filter_map(|pattern| match Regex::new(pattern) {
            Ok(regex) => Some(regex),
            Err(error) => {
                warnings.push(format!(
                    "toolPermissions.tools.{tool}.{field} 忽略非法正则 {pattern:?}: {error}"
                ));
                None
            }
        })
        .collect()
}

/// 规则自动决定的结果：要回传的 option 与会话里要补的 Notice 文案。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AutoPermission {
    pub request_id: String,
    pub option_id: String,
    pub allowed: bool,
    pub notice: String,
}

/// 规则 → 自动决定（**仅 native 轨**）。仅当 allow/deny 且请求里有对应 kind 的
/// option 时返回 `Some`；否则返回 `None` 表示继续弹共享卡（不误放行、不死锁）。
/// external ACP 轨不调用本函数：由 agent 自身的模式/选项决定审批。
pub fn auto_permission_for_event(
    rules: &ApprovalRules,
    event: &HostEvent,
) -> Option<AutoPermission> {
    let HostEvent::PermissionRequested {
        request_id,
        tool_name,
        args,
        options,
        ..
    } = event
    else {
        return None;
    };
    let (allowed, verb) = match rules.decide(tool_name.as_deref(), args.as_deref()) {
        RuleDecision::Allow => (true, "自动允许"),
        RuleDecision::Deny => (false, "自动拒绝"),
        RuleDecision::Confirm | RuleDecision::Ask => return None,
    };
    let shared_options = agent_ingest::permission_options_from_host(options);
    let option_id = agent_ingest::first_permission_option(&shared_options, allowed)
        .map(|option| option.id.clone())?;
    let tool = tool_name
        .as_deref()
        .filter(|tool| !tool.trim().is_empty())
        .unwrap_or("该操作");
    Some(AutoPermission {
        request_id: request_id.clone(),
        option_id,
        allowed,
        notice: format!("已按设置{verb} {tool}"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use cgc_platform::acp::connection::{HostEvent, PermissionOptionView};

    fn settings(json: serde_json::Value) -> ToolPermissionSettings {
        serde_json::from_value(json).expect("settings")
    }

    fn compiled(json: serde_json::Value) -> ApprovalRules {
        ApprovalRules::from_settings(&settings(json))
    }

    fn permission_event(tool: &str, args: &str, options: Vec<PermissionOptionView>) -> HostEvent {
        HostEvent::PermissionRequested {
            request_id: "perm-1".to_string(),
            title: format!("允许运行 {tool}？"),
            tool_call_id: Some("call-1".to_string()),
            tool_name: Some(tool.to_string()),
            args: Some(args.to_string()),
            options,
        }
    }

    fn option(option_id: &str, name: &str, kind: &str) -> PermissionOptionView {
        PermissionOptionView {
            option_id: option_id.to_string(),
            name: name.to_string(),
            kind: kind.to_string(),
        }
    }

    fn native_options() -> Vec<PermissionOptionView> {
        vec![
            option("allow_once", "允许一次", "allow_once"),
            option("allow_session", "本会话允许", "allow_always"),
            option("deny", "拒绝", "reject_once"),
        ]
    }

    #[test]
    fn empty_settings_default_to_ask_with_no_rules() {
        let rules = compiled(serde_json::json!({}));
        assert_eq!(
            rules.decide(Some("run_command"), Some("{\"command\":\"ls\"}")),
            RuleDecision::Ask
        );
        assert!(rules.warnings.is_empty());
        assert!(auto_permission_for_event(
            &rules,
            &permission_event("run_command", "{\"command\":\"ls\"}", native_options()),
        )
        .is_none());
    }

    #[test]
    fn default_policy_applies_without_tool_rules() {
        assert_eq!(
            compiled(serde_json::json!({"default": "allow"})).decide(Some("any_tool"), None),
            RuleDecision::Allow
        );
        assert_eq!(
            compiled(serde_json::json!({"default": "deny"})).decide(None, None),
            RuleDecision::Deny
        );
        assert_eq!(
            compiled(serde_json::json!({"default": "confirm"})).decide(Some("run_command"), None),
            RuleDecision::Confirm
        );
    }

    #[test]
    fn always_allow_matches_tool_name_or_args_json_substring() {
        let rules = compiled(serde_json::json!({
            "tools": {
                "run_command": { "alwaysAllow": ["ls"] }
            }
        }));
        assert_eq!(
            rules.decide(Some("run_command"), Some("{\"command\":\"ls -la\"}")),
            RuleDecision::Allow
        );
        // 参数不命中但工具名命中（正则匹配工具名）。
        let by_name = compiled(serde_json::json!({
            "tools": { "run_command": { "alwaysAllow": ["^run_"] } }
        }));
        assert_eq!(
            by_name.decide(Some("run_command"), Some("{\"command\":\"pwd\"}")),
            RuleDecision::Allow
        );
        assert_eq!(
            rules.decide(Some("run_command"), Some("{\"command\":\"pwd\"}")),
            RuleDecision::Ask
        );
    }

    #[test]
    fn deny_wins_over_allow_confirm_and_default() {
        let rules = compiled(serde_json::json!({
            "default": "allow",
            "tools": {
                "run_command": {
                    "alwaysAllow": ["ls"],
                    "alwaysDeny": ["ls"],
                    "alwaysConfirm": ["ls"]
                }
            }
        }));
        assert_eq!(
            rules.decide(Some("run_command"), Some("{\"command\":\"ls\"}")),
            RuleDecision::Deny,
            "deny 优先级最高"
        );
    }

    #[test]
    fn allow_wins_over_confirm_and_default() {
        let rules = compiled(serde_json::json!({
            "default": "ask",
            "tools": {
                "run_command": {
                    "alwaysAllow": ["ls"],
                    "alwaysConfirm": ["ls"]
                }
            }
        }));
        assert_eq!(
            rules.decide(Some("run_command"), Some("{\"command\":\"ls\"}")),
            RuleDecision::Allow
        );
    }

    #[test]
    fn confirm_beats_default_allow_and_ask_is_default() {
        let rules = compiled(serde_json::json!({
            "default": "allow",
            "tools": { "run_command": { "alwaysConfirm": ["git push"] } }
        }));
        assert_eq!(
            rules.decide(
                Some("run_command"),
                Some("{\"command\":\"git push origin\"}")
            ),
            RuleDecision::Confirm,
            "confirm 高于 default allow（强制问一次）"
        );
        assert_eq!(
            rules.decide(Some("run_command"), Some("{\"command\":\"ls\"}")),
            RuleDecision::Allow,
            "未命中 confirm 时回落 default"
        );
    }

    #[test]
    fn invalid_regex_is_ignored_and_valid_rules_still_work() {
        let rules = compiled(serde_json::json!({
            "tools": {
                "run_command": {
                    "alwaysAllow": ["[", "ls"]
                }
            }
        }));
        assert!(
            !rules.warnings.is_empty(),
            "非法正则必须记录 warning（不 panic）"
        );
        assert_eq!(
            rules.decide(Some("run_command"), Some("{\"command\":\"ls\"}")),
            RuleDecision::Allow,
            "非法正则被忽略后，其余合法规则仍然生效"
        );
    }

    #[test]
    fn unknown_default_value_falls_back_to_ask() {
        let settings = settings(serde_json::json!({"default": "definitely_not_a_policy"}));
        assert_eq!(settings.default, ToolPermissionDefault::Ask);
    }

    #[test]
    fn invalid_regex_does_not_break_settings_parse() {
        // 非法正则不是配置格式错误：tools 仍要解析出来（rules 里再忽略）。
        let settings = settings(serde_json::json!({
            "tools": { "run_command": { "alwaysDeny": ["(*"] } }
        }));
        assert!(settings.tools.contains_key("run_command"));
    }

    #[test]
    fn auto_permission_allow_picks_first_allow_option_and_notice() {
        let rules = compiled(serde_json::json!({
            "tools": { "run_command": { "alwaysAllow": ["ls"] } }
        }));
        let auto = auto_permission_for_event(
            &rules,
            &permission_event("run_command", "{\"command\":\"ls\"}", native_options()),
        )
        .expect("auto allow");
        assert!(auto.allowed);
        assert_eq!(auto.option_id, "allow_once");
        assert_eq!(auto.notice, "已按设置自动允许 run_command");
        assert_eq!(auto.request_id, "perm-1");
    }

    #[test]
    fn auto_permission_deny_picks_first_reject_option_and_notice() {
        let rules = compiled(serde_json::json!({
            "tools": { "run_command": { "alwaysDeny": ["rm -rf"] } }
        }));
        let auto = auto_permission_for_event(
            &rules,
            &permission_event(
                "run_command",
                "{\"command\":\"rm -rf /\"}",
                native_options(),
            ),
        )
        .expect("auto deny");
        assert!(!auto.allowed);
        assert_eq!(auto.option_id, "deny");
        assert_eq!(auto.notice, "已按设置自动拒绝 run_command");
    }

    #[test]
    fn auto_permission_passes_through_acp_custom_options_by_kind() {
        let rules = compiled(serde_json::json!({
            "tools": { "run_command": { "alwaysAllow": ["ls"] } }
        }));
        let acp_options = vec![
            option("i-mean-no", "No", "reject_once"),
            option("yes-please", "Yes", "allow_once"),
        ];
        let auto = auto_permission_for_event(
            &rules,
            &permission_event("run_command", "{\"command\":\"ls\"}", acp_options),
        )
        .expect("auto allow");
        assert_eq!(
            auto.option_id, "yes-please",
            "自动决定按 kind 找第一个 allow 选项（不假设 option_id 命名）"
        );
    }

    #[test]
    fn auto_permission_falls_back_to_card_without_kind_match_or_rule() {
        let allow_rules = compiled(serde_json::json!({
            "tools": { "run_command": { "alwaysAllow": ["ls"] } }
        }));
        // 只有 reject 类选项：allow 规则无法表达 → 必须回退弹卡，不能误放行。
        let only_reject = vec![option("deny", "拒绝", "reject_once")];
        assert!(auto_permission_for_event(
            &allow_rules,
            &permission_event("run_command", "{\"command\":\"ls\"}", only_reject),
        )
        .is_none());

        let deny_rules = compiled(serde_json::json!({
            "tools": { "run_command": { "alwaysDeny": ["rm"] } }
        }));
        let only_allow = vec![option("allow_once", "允许一次", "allow_once")];
        assert!(auto_permission_for_event(
            &deny_rules,
            &permission_event("run_command", "{\"command\":\"rm -rf\"}", only_allow),
        )
        .is_none());

        // 规则不命中 → 弹卡。
        let ask_rules = compiled(serde_json::json!({}));
        assert!(auto_permission_for_event(
            &ask_rules,
            &permission_event("run_command", "{\"command\":\"ls\"}", native_options()),
        )
        .is_none());
    }

    #[test]
    fn auto_permission_unknown_tool_still_handles_default_rules() {
        let rules = compiled(serde_json::json!({"default": "deny"}));
        let auto = auto_permission_for_event(
            &rules,
            &permission_event("run_command", "{}", native_options()),
        )
        .expect("auto deny by default");
        assert_eq!(auto.notice, "已按设置自动拒绝 run_command");
    }
}
