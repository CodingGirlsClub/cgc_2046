//! 设计 token 与主题（story 1.2）。
//!
//! 颜色 / 字体 / 圆角 / 间距映射自 web 的 `web/app/globals.css`（Linear 设计系统，
//! :root 为 Dark，`.light` 为 Light）。桌面端不引 CSS 变量，编译成常量：
//! 每个主题一个 `Palette`，渲染时按「偏好 + 系统外观」解析后用。
//! 系统外观来自 `Window::appearance()`；偏好为 Light/Dark/System，runtime 可切换。

use gpui_kit::component::{Theme, ThemeMode};
use gpui_kit::*;

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
    pub fn label_key(self) -> &'static str {
        match self {
            ThemePreference::Light => "app.theme.light",
            ThemePreference::Dark => "app.theme.dark",
            ThemePreference::System => "app.theme.system",
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
            eprintln!("CGC_THEME=`{other}` 无法识别，回退 system（可选 light|dark|system）");
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
}

/// web 的间距刻度（4px 基准）。
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
    }
}

pub fn palette(mode: ThemeMode) -> Palette {
    match mode {
        ThemeMode::Light => light(),
        ThemeMode::Dark => dark(),
    }
}

/// 把模式应用到 gpui-kit 的样式层（字体、圆角），并刷新窗口。
pub fn apply(mode: ThemeMode, cx: &mut App) {
    Theme::change(mode, None, cx);
    Theme::update(cx, |theme| {
        theme.font_family = FONT_SANS.into();
        theme.mono_font_family = FONT_MONO.into();
        theme.radius = px(RADIUS_MEDIUM);
        theme.radius_lg = px(RADIUS_LARGE);
    });
}

#[cfg(test)]
mod tests {
    use super::{col, palette, resolve, space, ThemePreference, RADIUS_LARGE, RADIUS_SMALL};
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
    fn brand_accent_matches_web_token_in_both_themes() {
        // web: --accent: #ea5504（两主题一致）
        assert_eq!(palette(ThemeMode::Dark).accent, col(0xea_55_04));
        assert_eq!(palette(ThemeMode::Light).accent, col(0xea_55_04));
    }

    #[test]
    fn canvas_matches_web_tokens() {
        // web dark: --canvas #08090a；light: --canvas #f4f5f8
        assert_eq!(palette(ThemeMode::Dark).canvas, col(0x08_09_0a));
        assert_eq!(palette(ThemeMode::Light).canvas, col(0xf4_f5_f8));
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
    fn spacing_and_radius_match_web_tokens() {
        assert_eq!(space(0), px(4.0));
        assert_eq!(space(4), px(24.0));
        assert_eq!(RADIUS_SMALL, 4.0);
        assert_eq!(RADIUS_LARGE, 8.0);
    }
}
