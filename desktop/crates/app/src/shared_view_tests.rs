//! P4 共享层（消息操作栏 / 发送按钮）的 headless 回归。
//!
//! 只在 `CGC_UI_TESTS=1` + `--features gpui-kit/test-support` 下编译。

use cgc_agent_ui::composer::{render_send_button, SendButtonSpec};
use cgc_agent_ui::message_actions::{
    render_action_bar, ActionBarSpec, ActionCallbacks, ActionGlyph, ActionGlyphs, ActionStyle,
};
use gpui_kit::assets::IconName;
use gpui_kit::component::Icon;
use gpui_kit::test::{TestQueryExt, TestWindowExt};
use gpui_kit::{
    div, px, size, AppContext, Bounds, Context, IntoElement, ParentElement, Render, Role, Styled,
    TestAppContext, VisualTestContext, Window, WindowBounds, WindowOptions,
};
use std::cell::Cell;
use std::rc::Rc;

struct SharedProbe {
    sends: Rc<Cell<usize>>,
}

impl Render for SharedProbe {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let palette = crate::theme::palette_from_theme(cx);
        let style = ActionStyle {
            icon_color: palette.ink_3,
            hover_bg: palette.soft,
            button_size: 22.0,
            radius: 6.0,
            gap: 4.0,
        };
        let bar = render_action_bar(
            ActionBarSpec {
                row_id: "test-row".into(),
                copy_id: "test-copy".into(),
                user_id: "test-user".into(),
                top_id: "test-top".into(),
                glyphs: ActionGlyphs {
                    copy: ActionGlyph::Named(IconName::Copy),
                    user: ActionGlyph::Named(IconName::ArrowUp),
                    top: ActionGlyph::Named(IconName::ArrowUp),
                },
                style,
                callbacks: ActionCallbacks {
                    on_copy: Some(Box::new(|_| {})),
                    on_scroll_user: Some(Box::new(|_| {})),
                    on_scroll_top: Some(Box::new(|_| {})),
                },
            },
            cx,
        );
        let sends = self.sends.clone();
        let send = render_send_button(
            SendButtonSpec {
                id: "test-send".into(),
                aria: "Send".into(),
                tooltip: "Send".into(),
                glyph: Icon::new(IconName::ArrowUp),
                bg: palette.accent,
                fg: palette.canvas,
                radius: 4.0,
                ml_auto: false,
                on_click: Box::new(move |_, _| sends.set(sends.get() + 1)),
            },
            cx,
        );
        div().flex().items_center().child(bar).child(send)
    }
}

#[gpui_kit::test]
fn shared_action_bar_and_send_button_are_kit_buttons(cx: &mut TestAppContext) {
    check_shared(cx);
}

fn check_shared(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    let sends = Rc::new(Cell::new(0));
    let sends_for_probe = sends.clone();
    let (handle, _probe) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(320.), px(120.)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                cx.new(|_| SharedProbe {
                    sends: sends_for_probe,
                })
            },
        )
        .unwrap()
    });

    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        for label in [
            "Copy This Agent Response",
            "Scroll to User Message",
            "Scroll to Top",
        ] {
            let button = window.find_by_label(label);
            assert!(button.visible(), "操作栏按钮 `{label}` 应渲染");
            assert_eq!(button.role(), Some(Role::Button));
        }
        let send = window.find_by_label("Send");
        assert!(send.visible(), "发送按钮应渲染");
        assert_eq!(send.role(), Some(Role::Button));
    })
    .unwrap();

    let mut vcx = VisualTestContext::from_window(handle, cx);
    vcx.update(|window, cx| window.click("test-send", cx));
    assert_eq!(sends.get(), 1, "点击发送按钮应触发回调");
}
