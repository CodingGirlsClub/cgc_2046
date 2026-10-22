//! 系统托盘：图标、菜单和事件轮询。
//!
//! 用 `tray-icon` 统一 macOS / Windows / Linux(StatusNotifierItem)。tray-icon 的事件
//! 需要由宿主事件循环消费，这里只提供非阻塞的 `take_event`，由 GPUI 主线程轮询。

use std::io::Cursor;

use tray_icon::menu::{Menu, MenuEvent, MenuItem};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder, TrayIconEvent};
#[cfg(not(target_os = "macos"))]
use tray_icon::{MouseButton, MouseButtonState};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TrayLabels {
    pub open: String,
    pub settings: String,
    pub quit: String,
    pub tooltip: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrayEvent {
    Open,
    Settings,
    Quit,
    Click,
}

pub struct Tray {
    _icon: TrayIcon,
    open_item: MenuItem,
    settings_item: MenuItem,
    quit_item: MenuItem,
}

impl Tray {
    /// 非阻塞取一个托盘事件；多个事件按到达顺序返回。
    pub fn take_event(&self) -> Option<TrayEvent> {
        // macOS 的状态项把左键交给菜单（右键菜单在部分系统上不可靠）；
        // Windows/Linux 保留左键直接激活窗口。
        #[cfg(not(target_os = "macos"))]
        if let Ok(TrayIconEvent::Click {
            button: MouseButton::Left,
            button_state: MouseButtonState::Up,
            ..
        }) = TrayIconEvent::receiver().try_recv()
        {
            return Some(TrayEvent::Click);
        }
        #[cfg(target_os = "macos")]
        let _ = TrayIconEvent::receiver().try_recv();
        if let Ok(event) = MenuEvent::receiver().try_recv() {
            if event.id == *self.open_item.id() {
                return Some(TrayEvent::Open);
            }
            if event.id == *self.settings_item.id() {
                return Some(TrayEvent::Settings);
            }
            if event.id == *self.quit_item.id() {
                return Some(TrayEvent::Quit);
            }
        }
        None
    }
}

pub fn create(icon_png: &[u8], labels: TrayLabels) -> Result<Tray, String> {
    let icon = decode_icon(icon_png)?;
    let menu = Menu::new();
    let open_item = MenuItem::with_id("tray-open", labels.open, true, None);
    let settings_item = MenuItem::with_id("tray-settings", labels.settings, true, None);
    let quit_item = MenuItem::with_id("tray-quit", labels.quit, true, None);
    menu.append_items(&[&open_item, &settings_item, &quit_item])
        .map_err(|error| format!("tray menu: {error}"))?;
    #[cfg(target_os = "macos")]
    let builder = TrayIconBuilder::new().with_menu_on_left_click(true);
    #[cfg(not(target_os = "macos"))]
    let builder = TrayIconBuilder::new().with_menu_on_left_click(false);
    let icon = builder
        .with_menu(Box::new(menu))
        .with_tooltip(labels.tooltip)
        .with_icon(icon)
        .build()
        .map_err(|error| format!("tray icon: {error}"))?;
    Ok(Tray {
        _icon: icon,
        open_item,
        settings_item,
        quit_item,
    })
}

fn decode_icon(bytes: &[u8]) -> Result<Icon, String> {
    let decoder = png::Decoder::new(Cursor::new(bytes));
    let mut reader = decoder.read_info().map_err(|error| error.to_string())?;
    let size = reader
        .output_buffer_size()
        .ok_or_else(|| "PNG output buffer size unknown".to_string())?;
    let mut rgba = vec![0; size];
    let info = reader
        .next_frame(&mut rgba)
        .map_err(|error| error.to_string())?;
    if info.color_type != png::ColorType::Rgba {
        return Err(format!(
            "expected RGBA tray icon, got {:?}",
            info.color_type
        ));
    }
    Icon::from_rgba(rgba, info.width, info.height).map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_icon_decodes() {
        let icon = decode_icon(include_bytes!("../../app/icons/32x32.png"));
        assert!(icon.is_ok(), "icon: {icon:?}");
    }
}
