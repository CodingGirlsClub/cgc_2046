//! 双栈共用的审批卡（Stage 3.2a）。
//!
//! 输入共享模型里 ACP 形状的 `PermissionRequest { id, tool, args, options }`
//! （或历史 `Entry::Permission`），把 agent 提供的 options 按顺序渲染成按钮；
//! kind 只影响样式（allow 主按钮 / reject 红色），语义由请求方给的 label 与
//! option_id 表达。两轨（native 进程内 ACP / external ACP）共用这一份卡片，
//! 不再各自写按钮与文案。
//!
//! 分层：`permission_card_view` 是纯数据函数（可单测）；`render_permission_card`
//! 只负责把 view 画出来并接 `on_select(option_id)` 回调。

use std::sync::Arc;

use gpui_kit::InteractiveElement as _;
use gpui_kit::StatefulInteractiveElement as _;
use gpui_kit::*;

use crate::conversation::{Entry, PermissionOption, PermissionOptionKind, PermissionRequest};

/// 卡片模型：可以来自进行中的 `PermissionRequest`，也可以来自历史 `Entry::Permission`
/// （复盘时保留 options 与 resolved）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PermissionCardModel {
    pub request_id: String,
    pub title: String,
    pub tool: Option<String>,
    pub args: Option<String>,
    pub options: Vec<PermissionOption>,
    pub resolved: Option<bool>,
}

impl PermissionCardModel {
    /// 进行中的审批请求 → 卡片模型。
    pub fn from_request(request: &PermissionRequest) -> Self {
        Self {
            request_id: request.request_id.clone(),
            title: request.title.clone(),
            tool: request.tool.clone(),
            args: request.args.clone(),
            options: request.options.clone(),
            resolved: None,
        }
    }

    /// 历史 `Entry::Permission` → 卡片模型；非 Permission 行返回 `None`。
    pub fn from_entry(entry: &Entry) -> Option<Self> {
        let Entry::Permission {
            request_id,
            title,
            tool,
            args,
            options,
            resolved,
            ..
        } = entry
        else {
            return None;
        };
        Some(Self {
            request_id: request_id.clone(),
            title: title.clone(),
            tool: tool.clone(),
            args: args.clone(),
            options: options.clone(),
            resolved: *resolved,
        })
    }
}

/// 按钮样式档位（由 option kind 决定，两轨一致）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PermissionButtonTone {
    /// allow_once：主按钮。
    Primary,
    /// allow_always：次按钮。
    Secondary,
    /// reject_*：危险按钮（红字）。
    Danger,
    /// 未知/扩展 kind。
    Neutral,
}

/// 单个审批按钮的纯数据。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PermissionCardButton {
    pub option_id: String,
    pub label: String,
    pub tone: PermissionButtonTone,
}

/// 卡片纯数据视图（不依赖 gpui，可直接断言顺序/文案/样式档位）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PermissionCardView {
    /// 状态标题：需要审批 / 已允许 / 已拒绝。
    pub heading: String,
    /// 请求方标题；native 的「允许运行 X？」与工具名重复时省略。
    pub title: Option<String>,
    pub tool: Option<String>,
    pub description: String,
    pub args: Option<String>,
    pub buttons: Vec<PermissionCardButton>,
    /// 待审批时的说明文案；已解决为 `None`。
    pub footnote: Option<String>,
    pub resolved: Option<bool>,
}

const ARGS_PREVIEW_CHARS: usize = 400;

/// 审批卡核心纯函数：options 顺序 = 按钮顺序，kind 决定按钮样式档位。
pub fn permission_card_view(model: &PermissionCardModel) -> PermissionCardView {
    let heading = match model.resolved {
        None => "需要审批",
        Some(true) => "已允许",
        Some(false) => "已拒绝",
    };
    // native 的标题「允许运行 {tool}？」与工具名 chip 重复，省略一次。
    let redundant_native_title = model
        .tool
        .as_deref()
        .is_some_and(|tool| model.title == format!("允许运行 {tool}？"));
    let title = if model.title.trim().is_empty() || redundant_native_title {
        None
    } else {
        Some(model.title.clone())
    };
    let buttons = if model.resolved.is_some() {
        Vec::new()
    } else {
        model
            .options
            .iter()
            .map(|option| PermissionCardButton {
                option_id: option.id.clone(),
                label: if option.label.trim().is_empty() {
                    option.id.clone()
                } else {
                    option.label.clone()
                },
                tone: button_tone(option.kind),
            })
            .collect()
    };
    PermissionCardView {
        heading: heading.to_string(),
        title,
        tool: model.tool.clone().filter(|tool| !tool.trim().is_empty()),
        description: description_for(model.tool.as_deref()).to_string(),
        args: args_preview(model.args.as_deref()),
        buttons,
        footnote: model
            .resolved
            .is_none()
            .then(|| "选项由请求方提供，选择会原样回传给 agent。".to_string()),
        resolved: model.resolved,
    }
}

fn button_tone(kind: PermissionOptionKind) -> PermissionButtonTone {
    match kind {
        PermissionOptionKind::AllowOnce => PermissionButtonTone::Primary,
        PermissionOptionKind::AllowAlways => PermissionButtonTone::Secondary,
        PermissionOptionKind::RejectOnce | PermissionOptionKind::RejectAlways => {
            PermissionButtonTone::Danger
        }
        PermissionOptionKind::Other => PermissionButtonTone::Neutral,
    }
}

fn description_for(tool: Option<&str>) -> &'static str {
    match tool {
        Some("run_command") => "将在工作区内执行 shell 命令（危险命令已被策略拦截）",
        Some("write_file") | Some("edit_file") => "将修改工作区文件，可在完成后用 Keep/Reject 处理",
        Some("read_file") | Some("list_directory") => "将读取工作区内容",
        _ => "该操作需要你的确认",
    }
}

fn args_preview(args: Option<&str>) -> Option<String> {
    let args = args?;
    if args.trim().is_empty() || args.trim() == "null" {
        return None;
    }
    Some(args.chars().take(ARGS_PREVIEW_CHARS).collect())
}

/// 卡片样式：各栈从自己的主题 palette 构造（`agent_ui` 不依赖 app 主题）。
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PermissionCardStyle {
    pub ink: Hsla,
    pub ink_2: Hsla,
    pub ink_3: Hsla,
    pub card_bg: Hsla,
    pub view_bg: Hsla,
    pub soft_bg: Hsla,
    pub border: Hsla,
    pub accent: Hsla,
    pub accent_text: Hsla,
    pub danger: Hsla,
    pub radius: f32,
    pub padding: f32,
    pub gap: f32,
}

/// 选择回调：参数是被点击按钮的 `option_id`。
pub type PermissionSelectCallback = Arc<dyn Fn(&str, &mut App) + 'static>;

/// 渲染输入：模型 + 样式 + 可选键盘提示 + 选择回调。
pub struct PermissionCardSpec {
    pub id: SharedString,
    pub model: PermissionCardModel,
    /// 键盘等价路径提示（ACP 面板用；native 不传）。
    pub hint: Option<String>,
    pub style: PermissionCardStyle,
    /// 已解决的卡片不需要回调。
    pub on_select: Option<PermissionSelectCallback>,
}

/// 渲染审批卡；两轨共用（native 面板 / ACP 会话面板）。
pub fn render_permission_card(spec: PermissionCardSpec) -> AnyElement {
    let PermissionCardSpec {
        id,
        model,
        hint,
        style,
        on_select,
    } = spec;
    let view = permission_card_view(&model);
    let mut card = div()
        .id(id.clone())
        .flex()
        .flex_col()
        .gap(px(style.gap))
        .p(px(style.padding))
        .rounded(px(style.radius))
        .border_1()
        .border_color(style.border)
        .bg(style.card_bg)
        .text_size(px(12.0))
        .text_color(style.ink);
    let mut heading = div()
        .flex()
        .flex_row()
        .items_center()
        .gap(px(style.gap))
        .child(
            div()
                .text_size(px(12.0))
                .text_color(style.ink)
                .child(view.heading.clone()),
        );
    if let Some(tool) = &view.tool {
        heading = heading.child(
            div()
                .px(px(style.gap))
                .py(px(2.0))
                .rounded(px(style.radius))
                .bg(style.soft_bg)
                .text_size(px(10.0))
                .text_color(style.accent)
                .child(tool.clone()),
        );
    }
    card = card.child(heading);
    if let Some(title) = &view.title {
        card = card.child(
            div()
                .text_size(px(11.0))
                .text_color(style.ink_2)
                .child(title.clone()),
        );
    }
    card = card.child(
        div()
            .text_size(px(11.0))
            .text_color(style.ink_3)
            .child(view.description.clone()),
    );
    if let Some(args) = &view.args {
        card = card.child(
            div()
                .p(px(style.gap))
                .rounded(px(style.radius))
                .bg(style.view_bg)
                .text_size(px(11.0))
                .text_color(style.ink_2)
                .child(args.clone()),
        );
    }
    if !view.buttons.is_empty() {
        let mut row = div()
            .flex()
            .flex_row()
            .flex_wrap()
            .items_center()
            .gap(px(style.gap));
        for button in &view.buttons {
            let Some(on_select) = on_select.as_ref() else {
                continue;
            };
            row = row.child(render_button(&id, button, style, Arc::clone(on_select)));
        }
        card = card.child(row);
    }
    if let Some(footnote) = &view.footnote {
        card = card.child(
            div()
                .text_size(px(10.0))
                .text_color(style.ink_3)
                .child(footnote.clone()),
        );
    }
    if let Some(hint) = hint {
        card = card.child(
            div()
                .text_size(px(10.0))
                .text_color(style.ink_3)
                .child(hint),
        );
    }
    card.into_any_element()
}

fn render_button(
    card_id: &SharedString,
    button: &PermissionCardButton,
    style: PermissionCardStyle,
    on_select: PermissionSelectCallback,
) -> AnyElement {
    let (bg, text_color, hover_bg) = match button.tone {
        PermissionButtonTone::Primary => (style.accent, style.accent_text, style.accent),
        PermissionButtonTone::Secondary => (style.soft_bg, style.ink, style.border),
        PermissionButtonTone::Danger => (style.soft_bg, style.danger, style.soft_bg),
        PermissionButtonTone::Neutral => (style.soft_bg, style.ink_2, style.border),
    };
    let option_id = button.option_id.clone();
    div()
        .id(SharedString::from(format!(
            "{card_id}-{}",
            button.option_id
        )))
        .role(Role::Button)
        .aria_label(button.label.clone())
        .px(px(style.gap))
        .py(px(style.gap / 2.0))
        .rounded(px(style.radius))
        .bg(bg)
        .text_color(text_color)
        .text_size(px(12.0))
        .hover(move |hovered| hovered.bg(hover_bg))
        .child(button.label.clone())
        .on_click(move |_, _, cx| on_select(&option_id, cx))
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::{permission_card_view, PermissionButtonTone, PermissionCardModel};
    use crate::conversation::{Entry, PermissionOption, PermissionOptionKind, PermissionRequest};

    fn option(id: &str, label: &str, kind: PermissionOptionKind) -> PermissionOption {
        PermissionOption {
            id: id.to_string(),
            label: label.to_string(),
            kind,
        }
    }

    fn native_options() -> Vec<PermissionOption> {
        vec![
            option("allow_once", "允许一次", PermissionOptionKind::AllowOnce),
            option(
                "allow_session",
                "本会话允许",
                PermissionOptionKind::AllowAlways,
            ),
            option(
                "allow_pattern:ls",
                "本会话允许 ls 前缀",
                PermissionOptionKind::AllowAlways,
            ),
            option("deny", "拒绝", PermissionOptionKind::RejectOnce),
        ]
    }

    fn native_request() -> PermissionRequest {
        PermissionRequest {
            request_id: "perm-1".to_string(),
            title: "允许运行 run_command？".to_string(),
            tool: Some("run_command".to_string()),
            tool_call_id: Some("call-1".to_string()),
            args: Some("{\"command\":\"ls\"}".to_string()),
            options: native_options(),
        }
    }

    /// native 4 档：按钮顺序/文案/kind 样式，标题去重（不与工具名重复）。
    #[test]
    fn native_four_options_render_in_order_with_kind_tones() {
        let model = PermissionCardModel::from_request(&native_request());
        let view = permission_card_view(&model);
        assert_eq!(view.heading, "需要审批");
        assert_eq!(view.tool.as_deref(), Some("run_command"));
        assert_eq!(
            view.description, "将在工作区内执行 shell 命令（危险命令已被策略拦截）",
            "按工具名给说明"
        );
        assert_eq!(view.args.as_deref(), Some("{\"command\":\"ls\"}"));
        assert_eq!(
            view.buttons
                .iter()
                .map(|button| button.option_id.as_str())
                .collect::<Vec<_>>(),
            vec!["allow_once", "allow_session", "allow_pattern:ls", "deny"],
            "选项顺序必须与请求方一致"
        );
        assert_eq!(
            view.buttons
                .iter()
                .map(|button| button.label.as_str())
                .collect::<Vec<_>>(),
            vec!["允许一次", "本会话允许", "本会话允许 ls 前缀", "拒绝"]
        );
        assert_eq!(
            view.buttons
                .iter()
                .map(|button| button.tone)
                .collect::<Vec<_>>(),
            vec![
                PermissionButtonTone::Primary,
                PermissionButtonTone::Secondary,
                PermissionButtonTone::Secondary,
                PermissionButtonTone::Danger,
            ],
            "kind 决定样式：allow_once 主按钮、allow_always 次按钮、reject 红色"
        );
        assert!(
            view.title.is_none(),
            "native 标题「允许运行 run_command？」与工具名重复，不再重复展示"
        );
        assert_eq!(view.resolved, None);
    }

    #[test]
    fn resolved_request_hides_buttons_and_marks_status() {
        let mut model = PermissionCardModel::from_request(&native_request());
        model.resolved = Some(true);
        let view = permission_card_view(&model);
        assert_eq!(view.heading, "已允许");
        assert!(view.buttons.is_empty(), "已解决后不再渲染按钮");
        assert!(view.footnote.is_none());

        model.resolved = Some(false);
        let view = permission_card_view(&model);
        assert_eq!(view.heading, "已拒绝");
        assert!(view.buttons.is_empty());
    }

    /// external ACP：option id/label 原样透传，未知 kind 走 neutral 样式；
    /// 无 tool 时用通用说明，title 照常展示。
    #[test]
    fn acp_options_pass_through_with_generic_description() {
        let request = PermissionRequest {
            request_id: "acp-1".to_string(),
            title: "Allow tool access?".to_string(),
            tool: None,
            tool_call_id: None,
            args: None,
            options: vec![
                option("yes", "Yes, once", PermissionOptionKind::AllowOnce),
                option("ext", "Custom", PermissionOptionKind::Other),
                option("no", "No", PermissionOptionKind::RejectAlways),
            ],
        };
        let view = permission_card_view(&PermissionCardModel::from_request(&request));
        assert_eq!(view.tool, None);
        assert_eq!(view.title.as_deref(), Some("Allow tool access?"));
        assert_eq!(view.description, "该操作需要你的确认");
        assert_eq!(view.args, None);
        assert_eq!(
            view.buttons
                .iter()
                .map(|button| (button.option_id.as_str(), button.tone))
                .collect::<Vec<_>>(),
            vec![
                ("yes", PermissionButtonTone::Primary),
                ("ext", PermissionButtonTone::Neutral),
                ("no", PermissionButtonTone::Danger),
            ]
        );
        assert!(view.footnote.is_some());
    }

    #[test]
    fn empty_options_yield_no_buttons() {
        let request = PermissionRequest {
            request_id: "perm-x".to_string(),
            title: "需要审批".to_string(),
            tool: Some("run_command".to_string()),
            tool_call_id: None,
            args: None,
            options: Vec::new(),
        };
        let view = permission_card_view(&PermissionCardModel::from_request(&request));
        assert!(view.buttons.is_empty());
        assert_eq!(view.heading, "需要审批");
    }

    #[test]
    fn long_args_are_truncated_and_null_args_hidden() {
        let mut request = native_request();
        request.args = Some("x".repeat(1_000));
        let view = permission_card_view(&PermissionCardModel::from_request(&request));
        let args = view.args.expect("args");
        assert_eq!(args.chars().count(), 400, "args 展示截断到 400 字");

        request.args = Some("null".to_string());
        let view = permission_card_view(&PermissionCardModel::from_request(&request));
        assert_eq!(view.args, None, "null 入参不展示");
    }

    /// 历史 Entry → 卡片模型：resolved 与 options 必须能复盘。
    #[test]
    fn history_entry_models_back_into_card() {
        let entry = Entry::Permission {
            request_id: "perm-1".to_string(),
            title: "允许运行 run_command？".to_string(),
            tool: Some("run_command".to_string()),
            tool_call_id: Some("call-1".to_string()),
            args: Some("{}".to_string()),
            options: native_options(),
            resolved: Some(true),
        };
        let model = PermissionCardModel::from_entry(&entry).expect("permission entry");
        assert_eq!(model.options.len(), 4, "历史行保留 options（复盘用）");
        let view = permission_card_view(&model);
        assert_eq!(view.heading, "已允许");
        assert!(
            view.buttons.is_empty(),
            "已解决卡片只展示状态，不再渲染按钮"
        );
        assert!(PermissionCardModel::from_entry(&Entry::Notice {
            level: crate::conversation::NoticeLevel::Info,
            text: "x".to_string(),
        })
        .is_none());
    }
}
