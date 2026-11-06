//! Footer 图标按钮的 headless 回归：Kit `Button` 是否渲染出可访问名称，
//! 以及点击后是否翻转真实状态（主题菜单、语言）。
//!
//! 只在 `CGC_UI_TESTS=1` + `--features gpui-kit/test-support` 下编译，
//! 见 `desktop/README.md` 的「授权回归验证」。
//!
//! 注意：这里**不要** `use super::*`。root_view 本身 glob 导入 `gpui_kit::*`，
//! 再 glob 进本模块会让 `#[gpui_kit::test]` 的属性宏解析陷入递归，rustc
//! 直接 SIGBUS（实测）。只导入需要的名字。

use super::RootView;
use crate::i18n::{translate, Key, Language};
use crate::theme::{self, ThemePreference};
use cgc_platform::session::{FakeAuthApi, MemoryStore, SessionService};
use gpui_kit::assets::IconName as AssetIcon;
use gpui_kit::test::{TestQueryExt, TestWindowExt};
use gpui_kit::{
    div, px, size, AppContext, Bounds, Context, Entity, IntoElement, Modifiers, ParentElement,
    Render, Role, Styled, TestAppContext, VisualTestContext, Window, WindowBounds, WindowOptions,
};

struct FooterProbe {
    root: Entity<RootView>,
}

impl Render for FooterProbe {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let footer = self.root.update(cx, |root, cx| {
            let palette = theme::palette_from_theme(cx);
            let language = root.language;
            root.render_footer(
                language,
                true,
                AssetIcon::Languages,
                "中文",
                "Language",
                &palette,
                cx,
            )
        });
        div()
            .w_full()
            .h_full()
            .flex()
            .flex_col()
            .justify_end()
            .child(footer)
    }
}

#[gpui_kit::test]
fn footer_buttons_keep_accessible_names_and_toggle_state(cx: &mut TestAppContext) {
    check_footer(cx);
}

fn check_footer(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    let (handle, probe) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(520.), px(160.)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                let root = cx.new(|_| {
                    RootView::with_session(
                        crate::registration::build_registry().unwrap(),
                        Language::En,
                        ThemePreference::Light,
                        SessionService::new(
                            Box::new(FakeAuthApi::demo()),
                            Box::new(MemoryStore::default()),
                        ),
                    )
                });
                cx.new(|_| FooterProbe { root })
            },
        )
        .unwrap()
    });

    let labels = [
        "Agent".to_string(),
        "历史对话".to_string(),
        translate(Language::En, Key::WorkspaceSiteTreeTitle).to_string(),
        translate(Language::En, Key::WorkspaceOutlineTitle).to_string(),
        "主题".to_string(),
        "中文".to_string(),
    ];

    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        for label in &labels {
            let element = window.find_by_label(label);
            assert!(element.visible(), "footer button `{label}` 应渲染");
            assert_eq!(
                element.role(),
                Some(Role::Button),
                "footer button `{label}` 应暴露 Button role"
            );
        }
    })
    .unwrap();

    // 主题按钮现在是 Kit 下拉：点开后出现主题项，Esc 关闭；语言按钮翻转 root.language。
    cx.update(crate::theme::load_builtin_themes);
    let mut vcx = VisualTestContext::from_window(handle, cx);

    let theme_center = cx
        .update_window(handle, |_, window, cx| {
            window.render_frame(cx);
            window.find_by_label("主题").bounds().center()
        })
        .unwrap();
    vcx.simulate_click(theme_center, Modifiers::default());
    vcx.update(|window, cx| {
        window.render_frame(cx);
        assert!(
            window
                .try_find_by_label("Ayu Light")
                .is_some_and(|element| element.visible()),
            "点击主题按钮后应出现主题项"
        );
    });

    vcx.simulate_keystrokes("escape");
    vcx.update(|window, cx| {
        window.render_frame(cx);
        assert!(
            window
                .try_find_by_label("Ayu Light")
                .is_none_or(|element| !element.visible()),
            "Esc 后主题菜单应关闭"
        );
    });

    let language_center = cx
        .update_window(handle, |_, window, cx| {
            window.render_frame(cx);
            window.find_by_label("中文").bounds().center()
        })
        .unwrap();
    vcx.simulate_click(language_center, Modifiers::default());
    vcx.update(|window, cx| window.render_frame(cx));
    let language = cx.update(|cx| probe.read(cx).root.read(cx).language);
    assert_eq!(language, Language::Zh, "点击语言按钮后应切到中文");
}
