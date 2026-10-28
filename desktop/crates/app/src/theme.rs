//! 设计 token 与主题（story 1.2）。
//!
//! 颜色 / 字体 / 圆角 / 间距映射自 web 的 `web/app/globals.css`（Linear 设计系统，
//! :root 为 Dark，`.light` 为 Light）。桌面端不引 CSS 变量，编译成常量：
//! 每个主题一个 `Palette`，渲染时按「偏好 + 系统外观」解析后用。
//! 系统外观来自 `Window::appearance()`；偏好为 Light/Dark/System，runtime 可切换。

use gpui_kit::component::{ActiveTheme as _, Theme, ThemeMode, ThemeRegistry};
use gpui_kit::*;
use std::path::PathBuf;

use crate::i18n::Key;

/// 主题偏好：跟随系统或固定浅/深。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ThemePreference {
    Light,
    Dark,
    System,
}

impl ThemePreference {
    pub const ALL: [ThemePreference; 3] = [
        ThemePreference::Light,
        ThemePreference::Dark,
        ThemePreference::System,
    ];

    /// Light → Dark → System → Light，供 UI 上的单键切换。
    pub fn cycle(self) -> Self {
        match self {
            ThemePreference::Light => ThemePreference::Dark,
            ThemePreference::Dark => ThemePreference::System,
            ThemePreference::System => ThemePreference::Light,
        }
    }

    /// 切换按钮文案的 i18n key。
    pub fn label_key(self) -> Key {
        match self {
            ThemePreference::Light => Key::AppThemeLight,
            ThemePreference::Dark => Key::AppThemeDark,
            ThemePreference::System => Key::AppThemeSystem,
        }
    }
}

/// 解析 `CGC_THEME` 的值；纯函数，单测不写进程环境变量。
pub fn preference_from_value(value: Option<&str>) -> ThemePreference {
    match value {
        Some("light") => ThemePreference::Light,
        Some("dark") => ThemePreference::Dark,
        Some("system") | None => ThemePreference::System,
        Some(other) => {
            log::warn!(
                target: "theme",
                "CGC_THEME=`{other}` 无法识别，回退 system（可选 light|dark|system）"
            );
            ThemePreference::System
        }
    }
}

/// 启动偏好：`CGC_THEME` 环境变量优先（QA/调试用），否则跟随系统。
pub fn preference_from_env() -> ThemePreference {
    let value = std::env::var("CGC_THEME").ok();
    preference_from_value(value.as_deref())
}

/// 把偏好与系统外观解析为实际渲染模式（System 跟随系统）。
pub fn resolve(preference: ThemePreference, appearance: WindowAppearance) -> ThemeMode {
    match preference {
        ThemePreference::Light => ThemeMode::Light,
        ThemePreference::Dark => ThemeMode::Dark,
        ThemePreference::System => ThemeMode::from(appearance),
    }
}

pub const DEFAULT_THEME_NAME: &str = "Ayu Dark";

/// 官方 themes 目录下的主题包（每个文件可含多套明暗主题）。
pub fn load_builtin_themes(cx: &mut App) {
    let registry = ThemeRegistry::global_mut(cx);
    for raw in [
        include_str!("../../../resources/themes/adventure.json"),
        include_str!("../../../resources/themes/alduin.json"),
        include_str!("../../../resources/themes/asciinema.json"),
        include_str!("../../../resources/themes/aurora.json"),
        include_str!("../../../resources/themes/ayu.json"),
        include_str!("../../../resources/themes/catppuccin.json"),
        include_str!("../../../resources/themes/everforest.json"),
        include_str!("../../../resources/themes/fahrenheit.json"),
        include_str!("../../../resources/themes/flexoki.json"),
        include_str!("../../../resources/themes/gruvbox.json"),
        include_str!("../../../resources/themes/harper.json"),
        include_str!("../../../resources/themes/hybrid.json"),
        include_str!("../../../resources/themes/jellybeans.json"),
        include_str!("../../../resources/themes/kibble.json"),
        include_str!("../../../resources/themes/macos-classic.json"),
        include_str!("../../../resources/themes/mellifluous.json"),
        include_str!("../../../resources/themes/molokai.json"),
        include_str!("../../../resources/themes/solarized.json"),
        include_str!("../../../resources/themes/spaceduck.json"),
        include_str!("../../../resources/themes/tokyonight.json"),
        include_str!("../../../resources/themes/twilight.json"),
    ] {
        let _ = registry.load_themes_from_str(raw);
    }
}

/// 可选主题：去掉 gpui-kit 自带的两套 Default（不是产品主题）。
pub fn available_themes(cx: &App) -> Vec<(String, ThemeMode)> {
    ThemeRegistry::global(cx)
        .sorted_themes()
        .into_iter()
        .filter(|theme| {
            theme.name.as_ref() != "Default Light" && theme.name.as_ref() != "Default Dark"
        })
        .map(|theme| (theme.name.to_string(), theme.mode))
        .collect()
}

pub fn apply_named(name: &str, cx: &mut App) -> bool {
    let Some(config) = ThemeRegistry::global(cx).themes().get(name).cloned() else {
        return false;
    };
    Theme::update(cx, |theme| {
        theme.mode = config.mode;
        theme.apply_config(&config);
        theme.font_family = FONT_SANS.into();
        theme.mono_font_family = FONT_MONO.into();
        theme.radius = px(RADIUS_MEDIUM);
        theme.radius_lg = px(RADIUS_LARGE);
    });
    true
}

pub fn palette_from_theme(cx: &App) -> Palette {
    let theme = cx.theme();
    Palette {
        canvas: theme.background,
        frame: theme.sidebar,
        card: theme.popover,
        view: theme.background,
        divider: theme.border,
        ink: theme.foreground,
        ink_2: theme.foreground.opacity(0.72),
        ink_3: theme.foreground.opacity(0.48),
        accent: theme.primary,
        accent_strong: theme.primary,
        line: theme.border,
        line_strong: theme.border,
        soft: theme.secondary,
        danger: theme.danger,
    }
}

fn theme_file_path() -> PathBuf {
    cgc_platform::paths::AppPaths::from_env().theme_state_file()
}

pub fn load_selected_theme() -> Option<String> {
    std::fs::read_to_string(theme_file_path())
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

pub fn save_selected_theme(name: &str) {
    let path = theme_file_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Err(error) = std::fs::write(&path, name) {
        log::warn!(target: "theme", "保存主题选择失败：{error}");
    }
}

/// 主题相关颜色 token（对应 web 的运行时 CSS 变量）。
#[derive(Clone, Copy, Debug)]
pub struct Palette {
    pub canvas: Hsla,
    pub frame: Hsla,
    pub card: Hsla,
    pub view: Hsla,
    pub divider: Hsla,
    pub ink: Hsla,
    pub ink_2: Hsla,
    pub ink_3: Hsla,
    pub accent: Hsla,
    pub accent_strong: Hsla,
    pub line: Hsla,
    pub line_strong: Hsla,
    pub soft: Hsla,
    pub danger: Hsla,
}

/// 间距刻度：web 的 `globals.css` 没有 spacing token，实际用的是 Tailwind 默认
/// 4px 基准（`p-1`=4、`p-2`=8、`p-3`=12、`p-4`=16、`p-6`=24、`p-8`=32）。
pub const SPACING: [f32; 7] = [4.0, 8.0, 12.0, 16.0, 24.0, 32.0, 48.0];

/// web 的圆角刻度：micro 2 / small 4 / base 5 / medium 6 / large 8。
pub const RADIUS_MICRO: f32 = 2.0;
pub const RADIUS_SMALL: f32 = 4.0;
pub const RADIUS_BASE: f32 = 5.0;
pub const RADIUS_MEDIUM: f32 = 6.0;
pub const RADIUS_LARGE: f32 = 8.0;

/// web 的字体栈（字体文件暂未随包，缺失时由 gpui 回退系统字体）。
pub const FONT_SANS: &str = "Inter";
pub const FONT_MONO: &str = "Geist Mono";

pub fn space(step: usize) -> Pixels {
    px(SPACING[step.min(SPACING.len() - 1)])
}

fn col(hex: u32) -> Hsla {
    rgba((hex << 8) | 0xFF).into()
}

fn alpha(hex: u32, a: f32) -> Hsla {
    let alpha_byte = (a.clamp(0.0, 1.0) * 255.0).round() as u32;
    rgba((hex << 8) | alpha_byte).into()
}

fn dark() -> Palette {
    Palette {
        canvas: col(0x08_09_0a),
        frame: col(0x09_0a_0b),
        card: col(0x0f_10_11),
        view: col(0x12_13_14),
        divider: col(0x23_25_2a),
        ink: col(0xf7_f8_f8),
        ink_2: col(0xd0_d6_e0),
        ink_3: col(0x8a_8f_98),
        accent: col(0xea_55_04),
        accent_strong: col(0xff_a3_75),
        line: alpha(0xff_ff_ff, 0.08),
        line_strong: alpha(0xff_ff_ff, 0.15),
        soft: alpha(0xff_ff_ff, 0.05),
        danger: col(0xeb_57_57),
    }
}

fn light() -> Palette {
    Palette {
        canvas: col(0xf4_f5_f8),
        frame: col(0xfa_fa_fa),
        card: col(0xff_ff_ff),
        view: col(0xf7_f7_f8),
        divider: col(0xe4_e4_e7),
        ink: col(0x22_23_26),
        ink_2: col(0x4b_4d_54),
        ink_3: col(0x8a_8a_8d),
        accent: col(0xea_55_04),
        accent_strong: col(0xc2_4a_02),
        line: alpha(0x00_00_00, 0.08),
        line_strong: alpha(0x00_00_00, 0.15),
        soft: alpha(0x00_00_00, 0.05),
        danger: col(0xeb_57_57),
    }
}

pub fn palette(mode: ThemeMode) -> Palette {
    match mode {
        ThemeMode::Light => light(),
        ThemeMode::Dark => dark(),
    }
}

/// 把模式与 web token 应用到 gpui-kit 的样式层（颜色、字体、圆角），并刷新窗口。
///
/// 组件库（gpui-kit component）后续使用的 Button/Input 等会读这些 `ThemeColor`
/// 字段，因此色板必须写进 kit 主题，不能只留在本文件的 `Palette` 里。
pub fn apply(mode: ThemeMode, cx: &mut App) {
    Theme::change(mode, None, cx);
    let palette = palette(mode);
    Theme::update(cx, |theme| {
        theme.font_family = FONT_SANS.into();
        theme.mono_font_family = FONT_MONO.into();
        theme.radius = px(RADIUS_MEDIUM);
        theme.radius_lg = px(RADIUS_LARGE);
        theme.colors.background = palette.canvas;
        theme.colors.foreground = palette.ink;
        theme.colors.border = palette.line_strong;
        theme.colors.accent = palette.accent;
        theme.colors.accent_foreground = col(0xff_ff_ff);
        theme.colors.primary = palette.accent;
        theme.colors.secondary = palette.card;
        theme.colors.muted = palette.ink_3;
    });
}

#[cfg(test)]
mod tests {
    // 注意：不要改成 `use super::*`——父模块的 `use gpui_kit::*` 会引入 gpui 的
    // `test` 宏并遮蔽 std 的 `#[test]`；本模块只做显式导入。
    use super::{alpha, col, palette, resolve, space, ThemePreference, RADIUS_LARGE, RADIUS_SMALL};
    use crate::i18n::Key;
    use gpui_kit::component::ThemeMode;
    use gpui_kit::px;
    use gpui_kit::WindowAppearance;

    #[test]
    fn light_and_dark_palettes_differ_on_canvas_and_ink() {
        let dark = palette(ThemeMode::Dark);
        let light = palette(ThemeMode::Light);
        assert_ne!(dark.canvas, light.canvas);
        assert_ne!(dark.ink, light.ink);
    }

    #[test]
    fn every_dark_token_matches_web_globals_css() {
        let p = palette(ThemeMode::Dark);
        assert_eq!(p.canvas, col(0x08_09_0a));
        assert_eq!(p.frame, col(0x09_0a_0b));
        assert_eq!(p.card, col(0x0f_10_11));
        assert_eq!(p.view, col(0x12_13_14));
        assert_eq!(p.divider, col(0x23_25_2a));
        assert_eq!(p.ink, col(0xf7_f8_f8));
        assert_eq!(p.ink_2, col(0xd0_d6_e0));
        assert_eq!(p.ink_3, col(0x8a_8f_98));
        assert_eq!(p.accent, col(0xea_55_04));
        assert_eq!(p.accent_strong, col(0xff_a3_75));
        assert_eq!(p.line, alpha(0xff_ff_ff, 0.08));
        assert_eq!(p.line_strong, alpha(0xff_ff_ff, 0.15));
        assert_eq!(p.soft, alpha(0xff_ff_ff, 0.05));
        assert_eq!(p.danger, col(0xeb_57_57));
    }

    #[test]
    fn every_light_token_matches_web_globals_css() {
        let p = palette(ThemeMode::Light);
        assert_eq!(p.canvas, col(0xf4_f5_f8));
        assert_eq!(p.frame, col(0xfa_fa_fa));
        assert_eq!(p.card, col(0xff_ff_ff));
        assert_eq!(p.view, col(0xf7_f7_f8));
        assert_eq!(p.divider, col(0xe4_e4_e7));
        assert_eq!(p.ink, col(0x22_23_26));
        assert_eq!(p.ink_2, col(0x4b_4d_54));
        assert_eq!(p.ink_3, col(0x8a_8a_8d));
        assert_eq!(p.accent, col(0xea_55_04));
        assert_eq!(p.accent_strong, col(0xc2_4a_02));
        assert_eq!(p.line, alpha(0x00_00_00, 0.08));
        assert_eq!(p.line_strong, alpha(0x00_00_00, 0.15));
        assert_eq!(p.soft, alpha(0x00_00_00, 0.05));
        assert_eq!(p.danger, col(0xeb_57_57));
    }

    #[test]
    fn system_preference_follows_appearance() {
        assert_eq!(
            resolve(ThemePreference::System, WindowAppearance::Dark),
            ThemeMode::Dark
        );
        assert_eq!(
            resolve(ThemePreference::System, WindowAppearance::Light),
            ThemeMode::Light
        );
        assert_eq!(
            resolve(ThemePreference::System, WindowAppearance::VibrantDark),
            ThemeMode::Dark
        );
    }

    #[test]
    fn explicit_preference_ignores_appearance() {
        assert_eq!(
            resolve(ThemePreference::Light, WindowAppearance::Dark),
            ThemeMode::Light
        );
        assert_eq!(
            resolve(ThemePreference::Dark, WindowAppearance::Light),
            ThemeMode::Dark
        );
    }

    #[test]
    fn theme_preference_env_override_is_parsed() {
        assert_eq!(
            super::preference_from_value(Some("light")),
            ThemePreference::Light
        );
        assert_eq!(
            super::preference_from_value(Some("dark")),
            ThemePreference::Dark
        );
        assert_eq!(
            super::preference_from_value(Some("system")),
            ThemePreference::System
        );
        assert_eq!(super::preference_from_value(None), ThemePreference::System);
        assert_eq!(
            super::preference_from_value(Some("nonsense")),
            ThemePreference::System
        );
    }

    #[test]
    fn preference_cycles_through_all_modes() {
        let mut preference = ThemePreference::Light;
        for _ in 0..3 {
            preference = preference.cycle();
        }
        assert_eq!(preference, ThemePreference::Light);
    }

    #[test]
    fn theme_labels_are_registered_keys() {
        assert_eq!(ThemePreference::Light.label_key(), Key::AppThemeLight);
        assert_eq!(ThemePreference::Dark.label_key(), Key::AppThemeDark);
        assert_eq!(ThemePreference::System.label_key(), Key::AppThemeSystem);
    }

    #[test]
    fn spacing_and_radius_match_web_tokens() {
        assert_eq!(space(0), px(4.0));
        assert_eq!(space(4), px(24.0));
        assert_eq!(RADIUS_SMALL, 4.0);
        assert_eq!(RADIUS_LARGE, 8.0);
    }
}
