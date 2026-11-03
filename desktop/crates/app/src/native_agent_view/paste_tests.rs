use super::*;
use gpui_kit::component::input::{InlineToken, InputContent, Paste, Undo};
use gpui_kit::{ClipboardEntry, ClipboardItem, ClipboardString, ExternalPaths};

struct ImageFile(std::path::PathBuf);

impl ImageFile {
    fn new() -> Self {
        let dir = std::env::temp_dir().join(format!("cgc-composer-paste-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("photo.png");
        std::fs::write(&path, crate::icons::TRAY_ICON_PNG).unwrap();
        Self(path)
    }

    fn clipboard(&self) -> ClipboardItem {
        ClipboardItem {
            entries: vec![
                ClipboardEntry::ExternalPaths(ExternalPaths(vec![self.0.clone()].into())),
                ClipboardEntry::String(ClipboardString::new(self.0.to_string_lossy().into_owned())),
            ],
        }
    }
}

impl Drop for ImageFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(self.0.parent().unwrap());
    }
}

fn mount(cx: &mut TestAppContext) -> (gpui_kit::AnyWindowHandle, Entity<NativeComposerProbe>) {
    cx.update(gpui_kit::init);
    cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds {
                    origin: Default::default(),
                    size: size(px(420.0), px(500.0)),
                })),
                ..Default::default()
            },
            cx,
            |window, cx| cx.new(|cx| NativeComposerProbe::new(window, cx)),
        )
        .unwrap()
    })
}

#[gpui_kit::test]
fn text_paste_mentioning_an_image_keeps_the_text(cx: &mut TestAppContext) {
    let image = ImageFile::new();
    let (handle, probe) = mount(cx);
    cx.update_window(handle, |_, window, cx| {
        let input = probe.read(cx).input(cx);
        input.update(cx, |state, cx| state.focus(window, cx));
        window.render_frame(cx);
        let mut clipboard = image.clipboard();
        clipboard.entries[1] =
            ClipboardEntry::String(ClipboardString::new("请检查 photo.png 的说明".into()));
        cx.write_to_clipboard(clipboard);
        window.dispatch_action(Box::new(Paste), cx);
    })
    .unwrap();
    cx.update_window(handle, |_, _, cx| {
        let input = probe.read(cx).input(cx);
        assert_eq!(
            input.read(cx).content().text().as_str(),
            "请检查 photo.png 的说明"
        );
        assert!(probe.read(cx).view.read(cx).pending_images.is_empty());
    })
    .unwrap();
}

#[gpui_kit::test]
fn image_paste_keeps_multicursor_unicode_tokens_and_undo(cx: &mut TestAppContext) {
    let image = ImageFile::new();
    let (handle, probe) = mount(cx);
    let original = InputContent::new("abc你xxxxxxxxxxx\nB")
        .with_token(0..3, InlineToken::new("file", "abc"))
        .unwrap();
    cx.update_window(handle, |_, window, cx| {
        let input = probe.read(cx).input(cx);
        input.update(cx, |state, cx| {
            state.set_value(original.clone(), window, cx);
            let end = original.text().len();
            state.set_selected_range(end..end, cx);
            state.focus(window, cx);
        });
        window.render_frame(cx);
        window.input("!", cx);
    })
    .unwrap();
    let (draft, selection) = cx
        .update_window(handle, |_, window, cx| {
            let input = probe.read(cx).input(cx);
            input.update(cx, |state, cx| {
                state.set_selected_range(0..0, cx);
                state.add_selection(18..18, cx);
            });
            window.render_frame(cx);
            let draft = input.read(cx).content();
            let selection = input.read(cx).selected_range();
            cx.write_to_clipboard(image.clipboard());
            window.dispatch_action(Box::new(Paste), cx);
            (draft, selection)
        })
        .unwrap();
    cx.update_window(handle, |_, window, cx| {
        let input = probe.read(cx).input(cx);
        assert_eq!(input.read(cx).content(), draft);
        assert_eq!(input.read(cx).selected_range(), selection);
        let view = probe.read(cx).view.read(cx);
        assert_eq!(view.pending_images.len(), 1);
        assert_eq!(view.pending_images[0].name, "photo.png");
        cx.write_to_clipboard(ClipboardItem::new_string("Z".into()));
        window.dispatch_action(Box::new(Paste), cx);
    })
    .unwrap();
    cx.update_window(handle, |_, window, cx| {
        let input = probe.read(cx).input(cx);
        assert_eq!(
            input.read(cx).content().text().as_str(),
            "Zabc你xxxxxxxxxxx\nZB!"
        );
        assert_eq!(input.read(cx).content().tokens()[0].range(), 1..4);
        window.dispatch_action(Box::new(Undo), cx);
    })
    .unwrap();
    cx.update_window(handle, |_, window, cx| {
        let input = probe.read(cx).input(cx);
        assert_eq!(input.read(cx).content(), draft);
        window.dispatch_action(Box::new(Undo), cx);
    })
    .unwrap();
    cx.update_window(handle, |_, _, cx| {
        let input = probe.read(cx).input(cx);
        assert_eq!(input.read(cx).content(), original);
    })
    .unwrap();
}

#[gpui_kit::test]
fn image_paste_preserves_a_reversed_text_selection(cx: &mut TestAppContext) {
    let image = ImageFile::new();
    let (handle, probe) = mount(cx);
    let original = InputContent::new("before 你 after");
    cx.update_window(handle, |_, window, cx| {
        let input = probe.read(cx).input(cx);
        input.update(cx, |state, cx| {
            state.set_value(original.clone(), window, cx);
            state.set_selected_range_with_direction(7..10, true, cx);
            state.focus(window, cx);
        });
        window.render_frame(cx);
        cx.write_to_clipboard(image.clipboard());
        window.dispatch_action(Box::new(Paste), cx);
    })
    .unwrap();
    cx.update_window(handle, |_, _, cx| {
        let input = probe.read(cx).input(cx);
        assert_eq!(input.read(cx).content(), original);
        assert_eq!(input.read(cx).selected_range(), 7..10);
        assert!(input.read(cx).is_selection_reversed());
        assert_eq!(
            probe.read(cx).view.read(cx).pending_images[0].name,
            "photo.png"
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn menu_paste_accepts_a_clipboard_image(cx: &mut TestAppContext) {
    let (handle, probe) = mount(cx);
    cx.update_window(handle, |_, window, cx| {
        let input = probe.read(cx).input(cx);
        input.update(cx, |state, cx| state.focus(window, cx));
        window.render_frame(cx);
        cx.write_to_clipboard(ClipboardItem {
            entries: vec![ClipboardEntry::Image(gpui_kit::Image::from_bytes(
                gpui_kit::ImageFormat::Png,
                crate::icons::TRAY_ICON_PNG.to_vec(),
            ))],
        });
        window.dispatch_action(Box::new(Paste), cx);
    })
    .unwrap();
    cx.update_window(handle, |_, _, cx| {
        let view = probe.read(cx).view.read(cx);
        assert_eq!(view.pending_images.len(), 1);
        assert_eq!(view.pending_images[0].mime, "image/png");
        assert!(view.input.read(cx).content().text().is_empty());
    })
    .unwrap();
}

#[gpui_kit::test]
fn image_file_paste_preserves_draft_when_the_model_rejects_images(cx: &mut TestAppContext) {
    let image = ImageFile::new();
    let (handle, probe) = mount(cx);
    let original = InputContent::new("keep 你 here");
    cx.update_window(handle, |_, window, cx| {
        let view = probe.read(cx).view.clone();
        view.update(cx, |view, _| {
            let snapshot = Arc::get_mut(view.snapshot.as_mut().unwrap()).unwrap();
            Arc::make_mut(&mut snapshot.providers)[0].model_params[0].supports_images = false;
        });
        let input = probe.read(cx).input(cx);
        input.update(cx, |state, cx| {
            state.set_value(original.clone(), window, cx);
            state.set_selected_range(5..8, cx);
            state.focus(window, cx);
        });
        window.render_frame(cx);
        cx.write_to_clipboard(image.clipboard());
        window.dispatch_action(Box::new(Paste), cx);
    })
    .unwrap();
    cx.update_window(handle, |_, _, cx| {
        let view = probe.read(cx).view.read(cx);
        assert_eq!(view.input.read(cx).content(), original);
        assert_eq!(view.input.read(cx).selected_range(), 5..8);
        assert!(view.pending_images.is_empty());
    })
    .unwrap();
}
