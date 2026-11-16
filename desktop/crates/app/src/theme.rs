//! 设计 token 与主题（story 1.2）。
//!
//! 颜色 / 字体 / 圆角 / 间距映射自 web 的 `web/app/globals.css`（Linear 设计系统，
//! :root 为 Dark，`.light` 为 Light）。桌面端不引 CSS 变量，编译成常量：
//! 每个主题一个 `Palette`，渲染时按「偏好 + 系统外观」解析后用。
//! 系统外观来自 `Window::appearance()`；偏好为 Light/Dark/System，runtime 可切换。

use gpui_kit::base::input::CursorBlink;
use gpui_kit::component::{ActiveTheme as _, Theme, ThemeMode, ThemeRegistry};
use gpui_kit::*;
use std::path::PathBuf;
use std::time::Duration;

use crate::i18n::Key;
use crate::preferences::CursorBlinkPreference;

mod builtin;

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

pub const DEFAULT_THEME_NAME: &str = "Ayu Light";

pub fn load_builtin_themes(cx: &mut App) {
    let registry = ThemeRegistry::global_mut(cx);
    for (name, raw) in builtin::BUILTIN_THEME_FILES {
        if let Err(error) = registry.load_themes_from_str(raw) {
            log::warn!(target: "theme", "内置主题 `{name}` 加载失败：{error:#}");
        }
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
    let cursor_blink = cursor_blink_policy(crate::preferences::load().cursor_blink);
    Theme::update(cx, |theme| {
        theme.mode = config.mode;
        theme.apply_config(&config);
        theme.font_family = FONT_SANS.into();
        theme.mono_font_family = FONT_MONO.into();
        theme.radius = px(RADIUS_MEDIUM);
        theme.radius_lg = px(RADIUS_LARGE);
        theme.cursor_blink = cursor_blink;
    });
    true
}

/// 光标闪烁偏好 → Kit [`CursorBlink`]；闪烁沿用 Kit 的 500ms，常亮不启动计时器。
pub fn cursor_blink_policy(preference: CursorBlinkPreference) -> CursorBlink {
    match preference {
        CursorBlinkPreference::Blinking => CursorBlink::blinking(Duration::from_millis(500)),
        CursorBlinkPreference::Steady => CursorBlink::steady(),
    }
}

/// 设置项变更时立即应用；Kit 保证 `cursor_blink` 跨主题与明暗切换保留。
pub fn apply_cursor_blink(preference: CursorBlinkPreference, cx: &mut App) {
    Theme::update(cx, |theme| {
        theme.cursor_blink = cursor_blink_policy(preference);
    });
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
        warning: theme.warning,
    }
}

fn theme_file_path() -> PathBuf {
    cgc_platform::paths::AppPaths::from_env().theme_state_file()
}

/// 打包的终端配色表：主题名 → 前景/背景/光标 + ANSI 0–15。
///
/// 与主题 JSON 分开存放，因为 gpui-kit 的 `ThemeConfig` 不认识
/// `terminal.*` 字段；这份表由本应用直接读取。
const TERMINAL_PALETTES: &str = include_str!("../../../resources/themes/terminal-palettes.json");

#[derive(serde::Deserialize)]
struct TerminalPaletteFile {
    #[serde(default)]
    themes: std::collections::HashMap<String, TerminalPaletteEntry>,
}

#[derive(serde::Deserialize)]
struct TerminalPaletteEntry {
    foreground: String,
    background: String,
    cursor: String,
    ansi: Vec<String>,
}

fn terminal_palettes() -> &'static TerminalPaletteFile {
    static FILES: std::sync::LazyLock<TerminalPaletteFile> =
        std::sync::LazyLock::new(|| match serde_json::from_str(TERMINAL_PALETTES) {
            Ok(file) => file,
            Err(error) => {
                log::warn!(target: "theme", "终端配色表解析失败：{error}");
                TerminalPaletteFile {
                    themes: Default::default(),
                }
            }
        });
    &FILES
}

impl TerminalPaletteEntry {
    fn resolve(&self) -> Option<cgc_terminal::TerminalTheme> {
        if self.ansi.len() != 16 {
            return None;
        }
        let mut ansi = [cgc_terminal::FrameColor { r: 0, g: 0, b: 0 }; 16];
        for (slot, value) in ansi.iter_mut().zip(&self.ansi) {
            *slot = cgc_terminal::parse_hex(value)?;
        }
        Some(cgc_terminal::TerminalTheme {
            foreground: cgc_terminal::parse_hex(&self.foreground)?,
            background: cgc_terminal::parse_hex(&self.background)?,
            cursor: cgc_terminal::parse_hex(&self.cursor)?,
            ansi,
        })
    }
}

/// 主题名对应的终端配色；表里缺失时从当前 Kit 主题的三色推导。
pub fn terminal_theme(name: &str, cx: &App) -> cgc_terminal::TerminalTheme {
    if let Some(theme) = terminal_palettes()
        .themes
        .get(name)
        .and_then(TerminalPaletteEntry::resolve)
    {
        return theme;
    }
    fallback_terminal_theme(cx)
}

/// 终端绘制样式：字体固定，颜色跟随当前主题。
pub fn terminal_style(cx: &App) -> cgc_terminal_view::TerminalStyle {
    let palette = palette_from_theme(cx);
    let mut style = cgc_terminal_view::TerminalStyle::new(crate::fonts::terminal_font(), px(13.0));
    style.background = palette.canvas;
    style.foreground = palette.ink;
    style.cursor = palette.accent;
    style.selection = Hsla {
        h: palette.accent.h,
        s: palette.accent.s,
        l: palette.accent.l,
        a: 0.3,
    };
    style.match_highlight = Hsla {
        a: 0.32,
        ..palette.warning
    };
    style
}

/// 没有打包配色时的兜底：用主题的前景/背景与语义色拼出 16 色。
fn fallback_terminal_theme(cx: &App) -> cgc_terminal::TerminalTheme {
    let theme = cx.theme();
    let light = theme.mode == ThemeMode::Light;
    let black = if light {
        theme.foreground
    } else {
        theme.background
    };
    let white = if light {
        theme.background
    } else {
        theme.foreground
    };
    let normal = [
        black,
        theme.danger,
        theme.success,
        theme.warning,
        theme.info,
        theme.primary,
        theme.secondary,
        white,
    ];
    let mut ansi = [cgc_terminal::FrameColor { r: 0, g: 0, b: 0 }; 16];
    for (index, color) in normal.iter().enumerate() {
        ansi[index] = hsla_rgb(*color);
        ansi[index + 8] = hsla_rgb(lighten(*color, 0.12));
    }
    cgc_terminal::TerminalTheme {
        foreground: hsla_rgb(theme.foreground),
        background: hsla_rgb(theme.background),
        cursor: hsla_rgb(theme.primary),
        ansi,
    }
}

fn hsla_rgb(color: Hsla) -> cgc_terminal::FrameColor {
    let rgba: Rgba = color.into();
    cgc_terminal::FrameColor {
        r: (rgba.r * 255.0).round() as u8,
        g: (rgba.g * 255.0).round() as u8,
        b: (rgba.b * 255.0).round() as u8,
    }
}

fn lighten(color: Hsla, amount: f32) -> Hsla {
    Hsla {
        l: (color.l + amount).min(1.0),
        ..color
    }
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
    pub warning: Hsla,
}

impl Palette {
    pub(crate) fn composer_style(self) -> cgc_agent_ui::composer::ComposerStyle {
        cgc_agent_ui::composer::ComposerStyle {
            view: self.view,
            line: self.line,
            accent: self.accent,
            danger: self.danger,
            canvas: self.canvas,
            radius: RADIUS_MEDIUM,
        }
    }
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

/// web 的字体栈：Inter 随包注册（`resources/fonts/InterVariable.ttf`），
/// family 名取 variable 文件的 `Inter Variable`，见 `fonts::SANS_FAMILY`。
pub const FONT_SANS: &str = crate::fonts::SANS_FAMILY;
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
        warning: col(0xc9_94_01),
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
        warning: col(0xc9_94_01),
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
    let cursor_blink = cursor_blink_policy(crate::preferences::load().cursor_blink);
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
        theme.cursor_blink = cursor_blink;
    });
}

#[cfg(test)]
mod tests {
    // 注意：不要改成 `use super::*`——父模块的 `use gpui_kit::*` 会引入 gpui 的
    // `test` 宏并遮蔽 std 的 `#[test]`；本模块只做显式导入。
    use super::{
        alpha, col, cursor_blink_policy, palette, resolve, space, ThemePreference, RADIUS_LARGE,
        RADIUS_SMALL,
    };
    use crate::i18n::Key;
    use crate::preferences::CursorBlinkPreference;
    use gpui_kit::component::ThemeMode;
    use gpui_kit::px;
    use gpui_kit::WindowAppearance;
    use std::time::Duration;

    #[test]
    fn cursor_blink_policy_matches_preference() {
        let blinking = cursor_blink_policy(CursorBlinkPreference::Blinking);
        assert_eq!(blinking.interval(), Some(Duration::from_millis(500)));
        assert!(!blinking.is_steady());

        let steady = cursor_blink_policy(CursorBlinkPreference::Steady);
        assert!(steady.is_steady());
        assert_eq!(steady.interval(), None);
    }

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

    /// 内置主题必须有解析守卫：`load_builtin_themes` 只把错误降为日志，
    /// Kit 升版改了 `ThemeConfig` schema 时，主题会静默从设置里消失。
    #[test]
    fn builtin_theme_files_parse_with_current_kit() {
        for (file, raw) in super::builtin::BUILTIN_THEME_FILES {
            let set: gpui_kit::component::ThemeSet =
                serde_json::from_str(raw).unwrap_or_else(|error| {
                    panic!("内置主题 {file}.json 无法被当前 Kit 解析：{error}")
                });
            assert!(!set.themes.is_empty(), "内置主题 {file}.json 没有主题条目");
        }
    }

    /// 打包的终端配色必须覆盖每个内置主题变体，且每项都能解析。
    #[test]
    fn bundled_terminal_palettes_cover_every_theme() {
        let mut names = Vec::new();
        for (_, raw) in super::builtin::BUILTIN_THEME_FILES {
            let set: gpui_kit::component::ThemeSet = serde_json::from_str(raw).expect("主题可解析");
            for theme in set.themes {
                names.push(theme.name.to_string());
            }
        }
        assert!(!names.is_empty());

        let palettes = super::terminal_palettes();
        for name in names {
            let entry = palettes
                .themes
                .get(&name)
                .unwrap_or_else(|| panic!("`{name}` 缺少终端配色"));
            assert!(entry.resolve().is_some(), "`{name}` 的终端配色不完整");
        }
    }

    /// 默认主题直接采用 Zed 上游的终端色值，不能被推导规则改写。
    #[test]
    fn default_theme_uses_upstream_terminal_palette() {
        let theme = super::terminal_palettes()
            .themes
            .get("Ayu Light")
            .expect("Ayu Light 有终端配色")
            .resolve()
            .expect("配色完整");
        let hex = |value: &str| cgc_terminal::parse_hex(value).expect("有效 hex");
        assert_eq!(theme.foreground, hex("#5c6166"));
        assert_eq!(theme.background, hex("#fcfcfc"));
        assert_eq!(theme.ansi[1], hex("#ef7271"));
        assert_eq!(theme.ansi[8], hex("#3b9ee5"));
        assert_eq!(theme.ansi[15], hex("#ffffff"));
    }

    /// 端到端：打包配色注入终端后，ANSI 输出的 cell 直接渲染成主题色。
    #[test]
    fn terminal_renders_bundled_palette_colors() {
        let colors = super::terminal_palettes()
            .themes
            .get("Catppuccin Mocha")
            .expect("{{PERSON_butccfh5}}")
            .resolve()
            .expect("配色完整");

        let mut core = cgc_terminal::TerminalCore::new(cgc_terminal::GridSize { cols: 8, rows: 2 })
            .expect("终端可创建");
        core.set_theme(&colors).expect("配色可注入");
        core.feed(b"\x1b[31mR\x1b[32mG\x1b[0m");
        core.update_frame().expect("帧可刷新");

        let cells = &core.frame().rows()[0].cells;
        assert_eq!(cells[0].fg, Some(colors.ansi[1]), "ANSI 红");
        assert_eq!(cells[1].fg, Some(colors.ansi[2]), "ANSI 绿");
        assert_eq!(core.frame().colors().background, colors.background);
    }

    /// 已有输出的终端换主题：cell 颜色跟着新主题走，行内容不变。
    #[test]
    fn switching_theme_recolors_live_terminal() {
        let palettes = super::terminal_palettes();
        let light = palettes.themes["Ayu Light"]
            .resolve()
            .expect("Ayu Light 配色");
        let dark = palettes.themes["Ayu Dark"]
            .resolve()
            .expect("Ayu Dark 配色");

        let mut core = cgc_terminal::TerminalCore::new(cgc_terminal::GridSize { cols: 6, rows: 2 })
            .expect("终端可创建");
        core.set_theme(&light).expect("浅色配色可注入");
        core.feed(b"\x1b[31mR\x1b[0mtext");
        core.update_frame().expect("帧可刷新");
        let before = core.frame().rows()[0].cells[0].fg;
        assert_eq!(before, Some(light.ansi[1]));

        core.set_theme(&dark).expect("深色配色可注入");
        core.update_frame().expect("换色后重绘");

        let row = &core.frame().rows()[0];
        assert_eq!(row.cells[0].fg, Some(dark.ansi[1]), "已有 cell 换用新色板");
        assert_eq!(row.cells[1].text, "t", "文本内容不受影响");
        assert_eq!(core.frame().colors().background, dark.background);
    }
}
