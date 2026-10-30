//! Agent 品牌图标（历史侧栏行 / Agent Panel 头部 / Agent 选择列表共用）。
//!
//! Agent Panel 头部用 [`agent_header_icon_element`]：native 用 32px 竖版品牌
//! badge，外部 agent 用同尺寸品牌 mark，保证切换 agent 时图标槽位一致；历史行 /
//! 选择器仍用 [`agent_icon_element`] 的 mark-only（14px，完整 wordmark 不可读）。
//!
//! native（CGC Agent）用应用自身图标；已知外部 agent 用其品牌 mark（SVG 直接
//! `include_bytes!`，经 `Icon::data` 内联渲染，离线可用）：
//! - codex.svg  ← https://cdn.agentclientprotocol.com/registry/v1/latest/codex-acp.svg
//! - claude.svg ← https://cdn.agentclientprotocol.com/registry/v1/latest/claude-acp.svg
//! - opencode.svg ← .../opencode.svg
//! - omp.svg    ← https://omp.sh 首页内联 logo（pi-mark 路径，转单色 currentColor）
//!
//! 未知 agent 回退 Bot 图标（Lucide）。品牌 mark 只用于标识对应 agent。

use super::*;

/// Agent 图标种类（纯函数可单测；渲染时映射成 SVG/图片）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::root_view) enum AgentIconKind {
    Native,
    Codex,
    Claude,
    Omp,
    Opencode,
    FallbackBot,
}

const CODEX_SVG: &[u8] = include_bytes!("../../icons/agents/codex.svg");
const CLAUDE_SVG: &[u8] = include_bytes!("../../icons/agents/claude.svg");
const OMP_SVG: &[u8] = include_bytes!("../../icons/agents/omp.svg");
const OPENCODE_SVG: &[u8] = include_bytes!("../../icons/agents/opencode.svg");

/// agent id / 历史行 agent 标签 → 图标种类（大小写/连字符归一化）。
pub(in crate::root_view) fn agent_icon_kind(agent_id: &str) -> AgentIconKind {
    let normalized = agent_id
        .trim()
        .to_ascii_lowercase()
        .replace(['-', ' '], "_");
    match normalized.as_str() {
        "native" | "cgc" | "cgc_agent" => AgentIconKind::Native,
        "codex" | "codex_acp" => AgentIconKind::Codex,
        "claude" | "claude_code" | "claude_acp" => AgentIconKind::Claude,
        "omp" | "omp_acp" => AgentIconKind::Omp,
        "opencode" | "opencode_v2" => AgentIconKind::Opencode,
        other if other.contains("codex") => AgentIconKind::Codex,
        other if other.contains("claude") => AgentIconKind::Claude,
        other if other.contains("opencode") => AgentIconKind::Opencode,
        _ => AgentIconKind::FallbackBot,
    }
}

/// 渲染 agent 图标（size 为 icon 尺寸；native 用应用 logo 图片，其余为品牌 SVG）。
pub(in crate::root_view) fn agent_icon_element(
    agent_id: &str,
    size: f32,
    color: gpui::Hsla,
) -> AnyElement {
    match agent_icon_kind(agent_id) {
        AgentIconKind::Native => img(app_icon())
            .w(px(size))
            .h(px(size))
            .flex_none()
            .into_any_element(),
        AgentIconKind::Codex => svg_icon(CODEX_SVG, size, color),
        AgentIconKind::Claude => svg_icon(CLAUDE_SVG, size, color),
        AgentIconKind::Omp => svg_icon(OMP_SVG, size, color),
        AgentIconKind::Opencode => svg_icon(OPENCODE_SVG, size, color),
        AgentIconKind::FallbackBot => Icon::default()
            .path(AssetIcon::Bot.path())
            .text_color(color)
            .small()
            .into_any_element(),
    }
}

/// Agent Panel 头部图标：native 用竖版品牌 badge，外部 agent 用同尺寸品牌 mark。
/// 尺寸由调用方统一传入，避免 native / ACP 切换时图标大小跳动。
pub(in crate::root_view) fn agent_header_icon_element(
    agent_id: &str,
    size: f32,
    color: gpui::Hsla,
) -> AnyElement {
    match agent_icon_kind(agent_id) {
        AgentIconKind::Native => img(brand_badge())
            .w(px(size))
            .h(px(size))
            .flex_none()
            .into_any_element(),
        _ => agent_icon_element(agent_id, size, color),
    }
}

fn svg_icon(data: &'static [u8], size: f32, color: gpui::Hsla) -> AnyElement {
    // 直接用 gpui 的 Svg 元素 + 显式尺寸，避免 Icon::data 在部分图标上尺寸/
    // tint 异常导致空白。
    gpui_kit::svg()
        .data(data)
        .w(px(size))
        .h(px(size))
        .flex_none()
        .text_color(color)
        .into_any_element()
}

#[cfg(test)]
mod agent_icon_tests {
    use crate::root_view::agent_icons::{agent_icon_kind, AgentIconKind};

    /// icon 资产守卫：`Icon::data` 对复杂 SVG 渲染不稳（灰块/空白），只允许
    /// 单 path + currentColor 的极简形态。
    #[test]
    fn agent_icon_assets_are_simple_single_path() {
        for (name, svg) in [
            ("codex", super::CODEX_SVG),
            ("claude", super::CLAUDE_SVG),
            ("omp", super::OMP_SVG),
            ("opencode", super::OPENCODE_SVG),
        ] {
            let text = std::str::from_utf8(svg).expect("utf8 svg");
            assert_eq!(
                text.matches("<path").count(),
                1,
                "{name}.svg 必须只有单个 <path>"
            );
            for forbidden in ["fill-rule", "clip-path", "transform=", "url("] {
                assert!(
                    !text.contains(forbidden),
                    "{name}.svg 不能包含 {forbidden}（Icon::data 渲染不稳）"
                );
            }
            assert!(text.contains("currentColor"), "{name}.svg 需 currentColor");
        }
    }

    /// header badge 资产守卫：必须是 128px PNG（32px 显示时 4x，覆盖 2x/3x）。
    #[test]
    fn brand_badge_asset_is_128px_png() {
        let bytes = include_bytes!("../../icons/brand/cgc-badge-128.png");
        assert_eq!(&bytes[..8], b"\x89PNG\r\n\x1a\n", "badge 必须是 PNG");
        let width = u32::from_be_bytes(bytes[16..20].try_into().expect("png width"));
        let height = u32::from_be_bytes(bytes[20..24].try_into().expect("png height"));
        assert_eq!((width, height), (128, 128), "badge master 必须是 128×128");
    }

    #[test]
    fn agent_icons_map_ids_and_aliases() {
        assert_eq!(agent_icon_kind("native"), AgentIconKind::Native);
        assert_eq!(agent_icon_kind("codex"), AgentIconKind::Codex);
        assert_eq!(agent_icon_kind("codex-acp"), AgentIconKind::Codex);
        assert_eq!(agent_icon_kind("claude_code"), AgentIconKind::Claude);
        assert_eq!(agent_icon_kind("Claude"), AgentIconKind::Claude);
        assert_eq!(agent_icon_kind("omp"), AgentIconKind::Omp);
        assert_eq!(agent_icon_kind("opencode"), AgentIconKind::Opencode);
        assert_eq!(agent_icon_kind("mystery-agent"), AgentIconKind::FallbackBot);
        // 包含关系兜底：新版本 id（codex-acp-v2 / claude-code-2）仍能映射。
        assert_eq!(agent_icon_kind("codex_acp_v2"), AgentIconKind::Codex);
        assert_eq!(
            agent_icon_kind("claude-code-nightly"),
            AgentIconKind::Claude
        );
    }

    /// `Icon::data` 把 SVG 当单色图标渲染（填充被主题色替换）：资产必须只用
    /// currentColor 单色路径，不能带 gradient / 背景 rect / 外部 url 引用，
    /// 否则会渲染成灰色方块（OMP favicon 曾如此）。
    #[test]
    fn agent_icon_assets_are_monochrome_current_color_svgs() {
        for (name, svg) in [
            ("codex", super::CODEX_SVG),
            ("claude", super::CLAUDE_SVG),
            ("omp", super::OMP_SVG),
            ("opencode", super::OPENCODE_SVG),
        ] {
            let text = std::str::from_utf8(svg).expect("utf8 svg");
            assert!(
                !text.contains("url("),
                "{name}.svg 不能引用 gradient/url（Icon::data 单色渲染）"
            );
            assert!(
                !text.to_ascii_lowercase().contains("<rect"),
                "{name}.svg 不能带背景 rect（会渲染成实心方块）"
            );
            assert!(
                text.contains("currentColor"),
                "{name}.svg 必须用 currentColor 跟随主题"
            );
        }
    }
}
