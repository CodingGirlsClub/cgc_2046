//! App 级图标资产 + 语义尺寸。
//!
//! 渲染仍交给 gpui-kit 的 `Icon` / `IconSize`；这里只放两样东西：
//! 1. 跨界面复用的图标尺寸（顶栏 badge / Agent Panel / 历史行）；
//! 2. 内置 PNG 资产的加载器（App mark、品牌 badge、托盘）。

use std::sync::{Arc, OnceLock};

use gpui_kit::{Image, ImageFormat};

/// 顶栏品牌 badge 尺寸。32px 是竖版 lockup（火苗 + CODING GIRLS CLUB）
/// 仍可辨认的最小尺寸。
pub(crate) const BRAND_BADGE_SIZE: f32 = 32.0;

/// Agent 面板 header 的 agent 图标尺寸，对齐 Zed `IconSize::Medium`（16px）。
pub(crate) const AGENT_HEADER_ICON_SIZE: f32 = 16.0;

/// 历史行 / agent 选择器的图标尺寸，对齐 Zed `IconSize::Small`（14px）。
pub(crate) const AGENT_ROW_ICON_SIZE: f32 = 14.0;

/// 系统托盘 PNG（macOS 菜单栏暂未改模板图，仍用彩色 mark）。
pub const TRAY_ICON_PNG: &[u8] = include_bytes!("../icons/32x32.png");

/// native agent / 托盘使用的小尺寸 mark（18px 以下可读）。
pub(crate) fn app_icon() -> Arc<Image> {
    static ICON: OnceLock<Arc<Image>> = OnceLock::new();
    ICON.get_or_init(|| {
        Arc::new(Image::from_bytes(
            ImageFormat::Png,
            include_bytes!("../icons/128x128.png").to_vec(),
        ))
    })
    .clone()
}

/// 顶栏品牌 badge（32px 显示；圆角已烘进 PNG）。
pub(crate) fn brand_badge() -> Arc<Image> {
    static ICON: OnceLock<Arc<Image>> = OnceLock::new();
    ICON.get_or_init(|| {
        Arc::new(Image::from_bytes(
            ImageFormat::Png,
            include_bytes!("../icons/brand/cgc-badge-128.png").to_vec(),
        ))
    })
    .clone()
}

#[cfg(test)]
mod tests {
    /// header badge 资产守卫：必须是 128px PNG（32px 显示时 4x，覆盖 2x/3x）。
    #[test]
    fn brand_badge_asset_is_128px_png() {
        let bytes = include_bytes!("../icons/brand/cgc-badge-128.png");
        assert_eq!(&bytes[..8], b"\x89PNG\r\n\x1a\n", "badge 必须是 PNG");
        let width = u32::from_be_bytes(bytes[16..20].try_into().expect("png width"));
        let height = u32::from_be_bytes(bytes[20..24].try_into().expect("png height"));
        assert_eq!((width, height), (128, 128), "badge master 必须是 128×128");
    }
}
