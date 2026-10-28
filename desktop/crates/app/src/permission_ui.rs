//! 审批卡的 app 侧胶水：把主题 palette 映射成共享 `agent_ui::permission_card`
//! 的样式，并给出两轨一致的元素 id。渲染与文案都在共享模块里，这里只做适配。

use cgc_agent_ui::permission_card::PermissionCardStyle;

use crate::theme::{self, RADIUS_MEDIUM};

/// 两轨共用的审批卡样式（native 面板与 ACP 会话面板视觉一致）。
pub fn card_style(palette: &theme::Palette) -> PermissionCardStyle {
    PermissionCardStyle {
        ink: palette.ink,
        ink_2: palette.ink_2,
        ink_3: palette.ink_3,
        card_bg: palette.card,
        view_bg: palette.view,
        soft_bg: palette.soft,
        border: palette.line,
        accent: palette.accent,
        accent_text: palette.canvas,
        danger: palette.danger,
        radius: RADIUS_MEDIUM,
        // 与旧审批卡一致的 8px 内边距 / 4px 元素间距（spacing token 1/2）。
        padding: theme::SPACING[1],
        gap: theme::SPACING[0],
    }
}
