//! 标题栏账户菜单的 headless 回归：Kit `Button` + `dropdown_menu` 的
//! 打开 / Esc 关闭 / 点项执行并关闭。
//!
//! 只在 `CGC_UI_TESTS=1` + `--features gpui-kit/test-support` 下编译。
//! 注意不要 `use super::*`（会让 `#[gpui_kit::test]` 的属性宏递归，rustc SIGBUS）。

use super::RootView;
use crate::i18n::{translate, Key, Language};
use crate::theme::{self, ThemePreference};
use cgc_platform::session::{FakeAuthApi, MemoryStore, SessionService, SignedInSession};
use gpui_kit::test::{TestQueryExt, TestWindowExt};
use gpui_kit::{
    div, px, size, AppContext, Bounds, Context, Entity, IntoElement, Modifiers, ParentElement,
    Render, Styled, TestAppContext, VisualTestContext, Window, WindowBounds, WindowOptions,
};

struct AccountProbe {
    root: Entity<RootView>,
}

impl Render for AccountProbe {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let button = self.root.update(cx, |root, cx| {
            let palette = theme::palette_from_theme(cx);
            let language = root.language;
            root.render_account_menu_button(
                &palette,
                "demo@example.com",
                translate(language, Key::AppAuthSignedInAs),
                translate(language, Key::AppAuthSignOut),
                translate(language, Key::AppAccountMenu),
                cx,
            )
        });
        div()
            .size_full()
            .flex()
            .justify_end()
            .items_start()
            .p(px(8.0))
            .child(button)
    }
}

fn signed_in_root() -> RootView {
    let mut session = SessionService::new(
        Box::new(FakeAuthApi::demo()),
        Box::new(MemoryStore::default()),
    );
    session
        .adopt_signed_in(SignedInSession {
            token: "test-token".to_string(),
            user_id: "00000000-0000-0000-0000-000000000001".to_string(),
            email: Some("demo@example.com".to_string()),
            is_platform_admin: false,
        })
        .expect("fake session should persist in memory store");
    RootView::with_session(
        crate::registration::build_registry().unwrap(),
        Language::En,
        ThemePreference::Light,
        session,
    )
}

#[gpui_kit::test]
fn account_menu_opens_escapes_and_signs_out(cx: &mut TestAppContext) {
    check_account_menu(cx);
}

fn check_account_menu(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    let (handle, probe) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(420.), px(220.)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                let root = cx.new(|_| signed_in_root());
                cx.new(|_| AccountProbe { root })
            },
        )
        .unwrap()
    });

    let sign_out = translate(Language::En, Key::AppAuthSignOut);
    let mut vcx = VisualTestContext::from_window(handle, cx);

    let menu_state = |vcx: &mut VisualTestContext| -> (bool, usize) {
        vcx.update(|window, cx| {
            window.render_frame(cx);
            let visible = window
                .try_find_by_label(sign_out)
                .is_some_and(|element| element.visible());
            (
                visible,
                window.find_all_by_role(gpui_kit::Role::MenuItem).len(),
            )
        })
    };

    let (visible, _) = menu_state(&mut vcx);
    assert!(!visible, "菜单初始应关闭");
    assert!(
        vcx.update(|window, _| window.find("account-toggle").visible()),
        "账户触发器应渲染"
    );

    vcx.update(|window, cx| window.click("account-toggle", cx));
    let (visible, items) = menu_state(&mut vcx);
    assert!(visible, "点击账户触发器后菜单应打开");
    assert!(items >= 2, "菜单应至少包含设置与登出两项，实际 {items}");

    vcx.simulate_keystrokes("escape");
    let (visible, _) = menu_state(&mut vcx);
    assert!(!visible, "Esc 后菜单应关闭");

    vcx.update(|window, cx| window.click("account-toggle", cx));
    let sign_out_center = vcx.update(|window, cx| {
        window.render_frame(cx);
        window.find_by_label(sign_out).bounds().center()
    });
    vcx.simulate_click(sign_out_center, Modifiers::default());
    let (visible, _) = menu_state(&mut vcx);
    assert!(!visible, "点项后菜单应关闭");

    let signed_in = cx.update(|cx| probe.read(cx).root.read(cx).is_signed_in());
    assert!(!signed_in, "点击登出项后应退出登录");
}
