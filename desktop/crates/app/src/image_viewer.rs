//! 图片查看器（B4b-b'2：从 native 视图抽出的独立窗口组件）。
//!
//! 纯逻辑（适应窗口/缩放进位与边界）可 headless 单测；渲染与窗口交互保持原样。

use std::sync::Arc;

use gpui_kit::*;

use crate::theme::{space, RADIUS_SMALL};

pub(crate) struct ImageViewer {
    name: String,
    image: Arc<RenderImage>,
    focus: FocusHandle,
    base_width: f32,
    base_height: f32,
    fit_zoom: f32,
    zoom: f32,
    offset: Point<Pixels>,
    dragging: bool,
    drag_start: Option<Point<Pixels>>,
    drag_origin: Point<Pixels>,
}

impl ImageViewer {
    fn reset(&mut self) {
        self.zoom = self.fit_zoom;
        self.offset = point(px(0.0), px(0.0));
    }
}

impl Render for ImageViewer {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let palette = crate::theme::palette_from_theme(cx);
        let zoom = self.zoom;
        let width = self.base_width * zoom;
        let height = self.base_height * zoom;
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(palette.canvas)
            .text_color(palette.ink)
            .track_focus(&self.focus)
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .px(space(2))
                    .py(space(1))
                    .border_b_1()
                    .border_color(palette.line)
                    .child(
                        div()
                            .text_size(px(12.0))
                            .text_color(palette.ink_2)
                            .child(format!("{} · {:.0}%", self.name, (zoom * 100.0).round())),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(space(2))
                            .child(
                                div().text_size(px(10.0)).text_color(palette.ink_3).child(
                                    "滚轮缩放 · 拖动平移 · 双击还原 · Cmd+0 还原 · Esc 关闭",
                                ),
                            )
                            .child(
                                div()
                                    .id("native-image-viewer-fit")
                                    .role(Role::Button)
                                    .aria_label("适应窗口")
                                    .px(space(1))
                                    .rounded(px(RADIUS_SMALL))
                                    .text_size(px(12.0))
                                    .text_color(palette.ink_2)
                                    .hover(|style| style.bg(palette.soft))
                                    .child("适应窗口")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.reset();
                                        cx.notify();
                                    })),
                            )
                            .child(
                                div()
                                    .id("native-image-viewer-close")
                                    .role(Role::Button)
                                    .aria_label("关闭")
                                    .px(space(1))
                                    .rounded(px(RADIUS_SMALL))
                                    .text_size(px(12.0))
                                    .text_color(palette.ink_2)
                                    .hover(|style| style.bg(palette.soft))
                                    .child("关闭")
                                    .on_click(|_, window, _cx| window.remove_window()),
                            ),
                    ),
            )
            .child(
                div()
                    .flex_1()
                    .relative()
                    .overflow_hidden()
                    .on_scroll_wheel(cx.listener(|this, event: &ScrollWheelEvent, _, cx| {
                        let delta = match event.delta {
                            ScrollDelta::Pixels(delta) => {
                                let dy: f32 = delta.y.into();
                                dy / 120.0
                            }
                            ScrollDelta::Lines(delta) => delta.y,
                        };
                        this.zoom = zoom_step(this.zoom, delta);
                        cx.notify();
                    }))
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(|this, event: &MouseDownEvent, _, cx| {
                            if event.click_count == 2 {
                                this.reset();
                            } else {
                                this.dragging = true;
                                this.drag_start = Some(event.position);
                                this.drag_origin = this.offset;
                            }
                            cx.notify();
                        }),
                    )
                    .on_mouse_move(cx.listener(|this, event: &MouseMoveEvent, _, cx| {
                        if this.dragging {
                            if let Some(start) = this.drag_start {
                                this.offset = this.drag_origin + (event.position - start);
                                cx.notify();
                            }
                        }
                    }))
                    .on_mouse_up(
                        MouseButton::Left,
                        cx.listener(|this, _, _, cx| {
                            this.dragging = false;
                            this.drag_start = None;
                            cx.notify();
                        }),
                    )
                    .child(
                        div()
                            .absolute()
                            .left(self.offset.x)
                            .top(self.offset.y)
                            .child(img(self.image.clone()).w(px(width)).h(px(height))),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .px(space(2))
                    .py(px(3.0))
                    .border_t_1()
                    .border_color(palette.line)
                    .text_size(px(10.0))
                    .text_color(palette.ink_3)
                    .child("滚轮缩放 · 拖动平移 · 双击还原 · Cmd+0 还原 · Esc 关闭")
                    .child(format!("{:.0}%", (self.zoom * 100.0).round())),
            )
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                match event.keystroke.key.as_str() {
                    "escape" => window.remove_window(),
                    "0" if event.keystroke.modifiers.platform => {
                        this.reset();
                        cx.notify();
                    }
                    "=" | "+" if event.keystroke.modifiers.platform => {
                        this.zoom = (this.zoom * 1.2).clamp(0.1, 8.0);
                        cx.notify();
                    }
                    "-" if event.keystroke.modifiers.platform => {
                        this.zoom = (this.zoom / 1.2).clamp(0.1, 8.0);
                        cx.notify();
                    }
                    _ => {}
                }
            }))
    }
}

/// 适应窗口的初始缩放（最长边限制 + 不超过 100%）。
pub(crate) fn fit_zoom(base_width: f32, base_height: f32) -> f32 {
    (820.0 / base_width.max(1.0))
        .min(620.0 / base_height.max(1.0))
        .min(1.0)
}

/// 滚轮缩放步进：`zoom * (1 + delta*0.15)`，限制在 0.1–8.0。
pub(crate) fn zoom_step(zoom: f32, delta: f32) -> f32 {
    (zoom * (1.0 + delta * 0.15)).clamp(0.1, 8.0)
}

/// 打开独立图片预览窗口。
pub(crate) fn open(name: String, image: Arc<RenderImage>, focus: FocusHandle, cx: &mut App) {
    let bounds = Bounds {
        origin: point(px(260.0), px(160.0)),
        size: size(px(900.0), px(700.0)),
    };
    let image_size = image.size(0);
    let base_width = image_size.width.0 as f32;
    let base_height = image_size.height.0 as f32;
    let fit = fit_zoom(base_width, base_height);
    let _ = gpui_kit::open_window::<ImageViewer>(
        WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(bounds)),
            ..Default::default()
        },
        cx,
        move |window: &mut Window, cx: &mut App| {
            window.set_window_title("图片预览");
            cx.new(|_| ImageViewer {
                name,
                image,
                focus,
                base_width,
                base_height,
                fit_zoom: fit,
                zoom: fit,
                offset: point(px(0.0), px(0.0)),
                dragging: false,
                drag_start: None,
                drag_origin: point(px(0.0), px(0.0)),
            })
        },
    );
}

#[cfg(test)]
mod tests {
    use super::{fit_zoom, zoom_step};

    #[test]
    fn fit_zoom_limits_long_side_and_caps_at_one() {
        assert_eq!(fit_zoom(820.0, 620.0), 1.0);
        assert!(fit_zoom(1640.0, 620.0) <= 0.5);
        assert!(fit_zoom(0.0, 0.0) <= 1.0);
    }

    #[test]
    fn zoom_step_clamps_bounds() {
        assert!((zoom_step(1.0, 0.0) - 1.0).abs() < f32::EPSILON);
        assert_eq!(zoom_step(8.0, 100.0), 8.0);
        assert_eq!(zoom_step(0.1, -100.0), 0.1);
        assert!(zoom_step(1.0, 1.0) > 1.0);
    }
}
