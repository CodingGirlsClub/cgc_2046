//! 全局历史侧边栏的动作层（打开/关闭/重命名/归档/unarchive/dirty 刷新）。
//!
//! 与 `history_sidebar` 的渲染分开：这里只做状态迁移和存储调用，便于单测与复用；
//! native / ACP 两轨共用（native 只能 Rename；ACP 支持 Rename/Archive/Unarchive）。

use std::sync::{Mutex, OnceLock};

use super::*;
use crate::acp_history::{self, HistorySource};
use crate::root_view::history_sidebar::{HistoryRename, HistorySidebar, HistoryTab};
use gpui_kit::component::input::InputState;

impl RootView {
    pub(in crate::root_view) fn toggle_history_sidebar(&mut self, cx: &mut Context<Self>) {
        if self.history_sidebar.is_some() {
            self.history_sidebar = None;
        } else {
            self.history_sidebar = Some(HistorySidebar::default());
            self.chat.history = self.load_unified_history();
        }
        cx.notify();
    }

    pub(in crate::root_view) fn close_history_sidebar(&mut self, cx: &mut Context<Self>) {
        self.history_sidebar = None;
        crate::preferences::save_history_sidebar_open(false);
        cx.notify();
    }

    pub(in crate::root_view) fn ensure_history_filter_input(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<InputState> {
        let Some(sidebar) = self.history_sidebar.as_mut() else {
            return cx.new(|cx| InputState::new(window, cx));
        };
        if let Some(input) = &sidebar.filter_input {
            return input.clone();
        }
        let input = cx.new(|cx| InputState::new(window, cx).placeholder("过滤标题 / agent"));
        sidebar.filter_subscription = Some(cx.subscribe_in(
            &input,
            window,
            |_this, _input, event: &InputEvent, _window, cx| {
                if matches!(event, InputEvent::Change) {
                    cx.notify();
                }
            },
        ));
        sidebar.filter_input = Some(input.clone());
        input
    }

    /// 侧栏「＋」：按当前轨新建对话（native 走 native view，ACP 走 new_chat）。
    pub(in crate::root_view) fn start_new_thread_from_history(&mut self, cx: &mut Context<Self>) {
        self.agent_panel_open = true;
        if self.native_chat_mode && RootView::native_agent_enabled() {
            if let Some(view) = &self.native_agent_view {
                view.update(cx, |view, cx| view.start_new_thread(cx));
            }
        } else {
            self.new_chat(cx);
        }
        cx.notify();
    }

    pub(in crate::root_view) fn set_history_tab(
        &mut self,
        tab: HistoryTab,
        cx: &mut Context<Self>,
    ) {
        if let Some(sidebar) = self.history_sidebar.as_mut() {
            sidebar.tab = tab;
            sidebar.rename = None;
        }
        cx.notify();
    }

    pub(in crate::root_view) fn begin_history_rename(
        &mut self,
        thread_id: String,
        title: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let initial = title.unwrap_or_default();
        let input = cx.new(|cx| InputState::new(window, cx).default_value(initial));
        let focus = input.read(cx).focus_handle(cx);
        window.focus(&focus, cx);
        if let Some(sidebar) = self.history_sidebar.as_mut() {
            sidebar.rename = Some(HistoryRename { thread_id, input });
        }
        cx.notify();
    }

    pub(in crate::root_view) fn cancel_history_rename(&mut self, cx: &mut Context<Self>) {
        if let Some(sidebar) = self.history_sidebar.as_mut() {
            sidebar.rename = None;
        }
        cx.notify();
    }

    pub(in crate::root_view) fn commit_history_rename(&mut self, cx: &mut Context<Self>) {
        let Some(sidebar) = self.history_sidebar.as_mut() else {
            return;
        };
        let Some(rename) = sidebar.rename.take() else {
            return;
        };
        let raw = rename.input.read(cx).value().trim().to_string();
        let title = if raw.is_empty() { None } else { Some(raw) };
        let is_acp = rename.thread_id.starts_with(acp_history::ACP_THREAD_PREFIX);
        if is_acp {
            let _ = acp_history::rename_override(&rename.thread_id, title.as_deref());
            if self.chat.session_id.as_deref().is_some_and(|session_id| {
                acp_history::acp_thread_id(session_id) == rename.thread_id
            }) {
                self.chat.title_override = title.clone();
            }
        } else {
            self.rename_native_thread(&rename.thread_id, title);
        }
        self.chat.history = self.load_unified_history();
        acp_history::mark_history_dirty();
        cx.notify();
    }

    /// native 重命名：写 threads.db 既有 title_override 列（schema 不变）。
    fn rename_native_thread(&mut self, thread_id: &str, title: Option<String>) {
        let path = AppPaths::from_env()
            .data_root
            .join("agent")
            .join("threads.db");
        let Ok(mut store) = cgc_agent_store::SessionStore::open(path) else {
            return;
        };
        if let Ok(Some(mut thread)) = store.load_thread(thread_id) {
            thread.title_override = title;
            let _ = store.save_thread(&thread);
        }
    }

    pub(in crate::root_view) fn archive_history_thread(
        &mut self,
        thread_id: String,
        cx: &mut Context<Self>,
    ) {
        let _ = acp_history::archive_thread(&thread_id);
        self.chat.history = self.load_unified_history();
        cx.notify();
    }

    pub(in crate::root_view) fn unarchive_history_thread(
        &mut self,
        thread_id: String,
        cx: &mut Context<Self>,
    ) {
        let _ = acp_history::unarchive_thread(&thread_id);
        self.chat.history = self.load_unified_history();
        cx.notify();
    }

    pub(in crate::root_view) fn open_history_entry(
        &mut self,
        thread_id: String,
        session_id: Option<String>,
        source: HistorySource,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // 侧边栏保持可见（Zed threads sidebar 行为），打开线程后仅高亮当前行。
        match source {
            HistorySource::Native => self.open_local_native_thread(thread_id, window, cx),
            HistorySource::Acp => {
                self.agent_panel_open = true;
                let session_id = session_id.unwrap_or_default();
                self.open_acp_history_thread(thread_id, session_id, cx);
            }
        }
        cx.notify();
    }
}

// ---------------------------------------------------------------------------
// 跨窗口刷新：设置窗口清空历史后，直接通知主窗口 RootView 重载统一列表。
// ---------------------------------------------------------------------------

static HISTORY_ROOT: OnceLock<Mutex<Option<WeakEntity<RootView>>>> = OnceLock::new();

/// 主窗口创建时登记 RootView weak（设置窗口没有 RootView 句柄，靠它回调）。
pub fn register_history_root(weak: WeakEntity<RootView>) {
    let slot = HISTORY_ROOT.get_or_init(|| Mutex::new(None));
    if let Ok(mut slot) = slot.lock() {
        *slot = Some(weak);
    }
}

/// 设置窗口改库（清空 ACP 历史）后调用：刷新主窗口缓存列表；若清掉的正是
/// 当前打开的 ACP 会话，回到新会话/空态并提示（Zed 无永久删除，这是 CGC 扩展）。
pub(crate) fn notify_history_changed(cx: &mut App) {
    let weak = HISTORY_ROOT
        .get()
        .and_then(|slot| slot.lock().ok().and_then(|slot| slot.clone()));
    let Some(weak) = weak else {
        return;
    };
    let generation = acp_history::history_dirty_generation();
    let _ = weak.update(cx, |this, cx| {
        this.history_dirty_seen = generation;
        this.apply_history_dirty_refresh(cx);
        cx.notify();
    });
}
