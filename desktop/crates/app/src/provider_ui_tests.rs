//! Provider 表单新控件的 headless 回归：启用开关与多选 Combobox。
//!
//! 只在 `CGC_UI_TESTS=1` + `--features gpui-kit/test-support` 下编译。

use std::cell::Cell;
use std::rc::Rc;

use gpui_kit::component::combobox::{Combobox, ComboboxState};
use gpui_kit::component::searchable_list::SearchableVec;
use gpui_kit::component::switch::Switch;
use gpui_kit::component::IndexPath;
use gpui_kit::test::TestWindowExt;
use gpui_kit::{
    div, px, size, AppContext, Bounds, Context, Entity, IntoElement, ParentElement, Render, Styled,
    TestAppContext, Window, WindowBounds, WindowOptions,
};

struct Probe {
    enabled: Rc<Cell<bool>>,
    picker: Entity<ComboboxState<SearchableVec<String>>>,
}

impl Render for Probe {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let enabled = self.enabled.clone();
        let value = self.enabled.get();
        div()
            .flex()
            .flex_col()
            .child(
                Switch::new("probe-enabled")
                    .checked(value)
                    .accessibility_label("启用 provider")
                    .on_change(move |checked, _, _| enabled.set(*checked)),
            )
            .child(Combobox::new(&self.picker))
    }
}

#[gpui_kit::test]
fn provider_controls_behave(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    let enabled = Rc::new(Cell::new(false));
    let enabled_for_probe = enabled.clone();
    let (handle, probe) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(420.), px(240.)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |window, cx| {
                let items = SearchableVec::new(vec![
                    "deepseek-flash".to_string(),
                    "deepseek-v4-pro".to_string(),
                ]);
                let selected = vec![IndexPath::new(0), IndexPath::new(1)];
                let picker = cx.new(|cx| {
                    ComboboxState::new(items, selected, window, cx)
                        .multiple(true)
                        .searchable(true)
                });
                cx.new(|_| Probe {
                    enabled: enabled_for_probe,
                    picker,
                })
            },
        )
        .expect("window")
    });

    let _ = cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(window.find("probe-enabled").visible(), "启用开关应渲染");
        window.click("probe-enabled", cx);
        assert!(enabled.get(), "开关点击应回写状态");
        window.render_frame(cx);

        assert_eq!(
            probe.read(cx).picker.read(cx).selected_values(),
            vec!["deepseek-flash".to_string(), "deepseek-v4-pro".to_string()],
            "获取模型后面板默认全选"
        );
        let picker = probe.read(cx).picker.clone();
        picker.update(cx, |state, cx| {
            state.set_selected_values(&["deepseek-v4-pro".to_string()], window, cx);
        });
        assert_eq!(
            probe.read(cx).picker.read(cx).selected_values(),
            vec!["deepseek-v4-pro".to_string()],
            "取消勾选后只剩选中的模型"
        );
    });
}
