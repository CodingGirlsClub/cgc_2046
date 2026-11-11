use super::*;
use crate::agent_ingest;
use cgc_agent_store::SessionStore;
use cgc_agent_ui::conversation::{ConversationThread, ThreadCapabilities};
use cgc_platform::notifications::NotificationsApi as _;
use cgc_platform::registry::install::install_entry;
use state::SiteTreeSection;

#[cfg(all(test, cgc_ui_tests))]
#[path = "workspace_layout_tests.rs"]
mod workspace_layout_tests;

#[cfg(all(test, cgc_ui_tests))]
#[path = "breadcrumb_tests.rs"]
mod breadcrumb_tests;

#[cfg(all(test, cgc_ui_tests))]
#[path = "public_list_tests.rs"]
mod public_list_tests;

#[cfg(all(test, cgc_ui_tests))]
#[path = "enrollment_tests.rs"]
mod enrollment_tests;

#[cfg(all(test, cgc_ui_tests))]
#[path = "site_tree_tests.rs"]
mod site_tree_tests;

#[cfg(all(test, cgc_ui_tests))]
#[path = "issue_card_tests.rs"]
mod issue_card_tests;

#[cfg(all(test, cgc_ui_tests))]
#[path = "offering_workspace_tests.rs"]
mod offering_workspace_tests;

#[cfg(all(test, cgc_ui_tests))]
#[path = "navigation_lifecycle_tests.rs"]
mod navigation_lifecycle_tests;

#[cfg(all(test, cgc_ui_tests))]
#[path = "public_course_workspace_tests.rs"]
mod public_course_workspace_tests;

#[cfg(all(test, cgc_ui_tests))]
#[path = "offering_scope_fix_tests.rs"]
mod offering_scope_fix_tests;

#[cfg(test)]
#[path = "list_generation_tests.rs"]
mod list_generation_tests;

/// 登录标识是否是邮箱。客户端只支持邮箱登录，这里做最小形状校验：
/// 本地部分非空、域部分含点且不以点开头/结尾（真正的校验在服务端）。
/// 列表响应是否允许落地的判定结果（R2）。
///
/// 用三值而不是布尔：过期响应分两种处理——有更新的请求在途时**什么都不做**
/// （复位会把新请求打回 Idle 并触发重复拉取），scope/epoch 越界时才丢弃并复位闸门。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::root_view) enum ListResponseDisposition {
    Apply,
    Ignore,
    DiscardAndReset,
}

/// 判定一次列表响应能否落地：代次 → 完整 scope（数据面 + 工作区 epoch）。
///
/// 公开面 epoch 恒为 `None`，所以「工作区 → 公开」的反向切换只能靠 `active_scope`
/// 与代次拦住，这正是串台的两个入口。
pub(in crate::root_view) fn list_response_disposition(
    latest_serial: u64,
    response_serial: u64,
    active_scope: Option<crate::routing::ListScope>,
    response_scope: crate::routing::ListScope,
    response_epoch: Option<u64>,
    epoch_is_current: bool,
    session_is_current: bool,
) -> ListResponseDisposition {
    if latest_serial != response_serial {
        return ListResponseDisposition::Ignore;
    }
    if !session_is_current {
        // 账号已切换/已登出：公开面的旧账响应同样不能落地（R1/P1）。
        return ListResponseDisposition::DiscardAndReset;
    }
    if active_scope != Some(response_scope) {
        return ListResponseDisposition::DiscardAndReset;
    }
    if response_epoch.is_some_and(|_| !epoch_is_current) {
        return ListResponseDisposition::DiscardAndReset;
    }
    ListResponseDisposition::Apply
}

fn looks_like_email(value: &str) -> bool {
    let Some((local, domain)) = value.split_once('@') else {
        return false;
    };
    !local.is_empty()
        && !domain.is_empty()
        && domain.contains('.')
        && !domain.starts_with('.')
        && !domain.ends_with('.')
        && !value.contains(char::is_whitespace)
}

impl RootView {
    pub fn current(&self) -> Option<Route> {
        self.current.as_ref().map(|route_match| route_match.route)
    }

    pub fn current_match(&self) -> Option<&RouteMatch> {
        self.current.as_ref()
    }

    pub fn language(&self) -> Language {
        self.language
    }

    pub fn preference(&self) -> ThemePreference {
        self.preference
    }

    pub fn is_signed_in(&self) -> bool {
        self.session.signed_in().is_some()
    }

    pub fn session_state(&self) -> &SessionState {
        self.session.state()
    }

    pub fn select(&mut self, route: Route) {
        self.current = Some(RouteMatch {
            route,
            params: std::collections::BTreeMap::new(),
            query: std::collections::BTreeMap::new(),
        });
    }

    /// 按路径导航（动态路由在此完成参数解析）。
    pub fn set_tray_preferences(
        &mut self,
        close_to_tray: Arc<std::sync::atomic::AtomicBool>,
        tray_hint_shown: Arc<std::sync::atomic::AtomicBool>,
    ) {
        self.close_to_tray = close_to_tray;
        self.tray_hint_shown = tray_hint_shown;
    }

    pub fn set_close_to_tray(&mut self, enabled: bool) {
        self.close_to_tray
            .store(enabled, std::sync::atomic::Ordering::Relaxed);
    }

    /// 主窗口关闭策略：关到托盘开启时隐藏窗口（首次给一次提示），否则落盘后退出。
    ///
    /// 系统关闭（`on_window_should_close`）与 Linux 自绘标题栏的关闭按钮共用这一条路径：
    /// gpui-kit 的关闭按钮默认直接 `window.remove_window()`，会绕过 flush 与 `cx.quit()`，
    /// 关托盘关闭时留下无窗口的后台进程。
    pub(in crate::root_view) fn handle_main_window_close(&mut self, cx: &mut Context<Self>) {
        if !self
            .close_to_tray
            .load(std::sync::atomic::Ordering::Relaxed)
        {
            // 退出前把已接受的写入落盘：后台 writer 不确认就等于可能丢最后一批。
            self.flush_store_writer();
            cx.quit();
            return;
        }
        if !self
            .tray_hint_shown
            .swap(true, std::sync::atomic::Ordering::Relaxed)
        {
            let language = self.language;
            let app_name = translate(language, Key::AppName).to_string();
            let hint_body = translate(language, Key::AppTrayFirstClose).to_string();
            cx.show_system_notification(SystemNotification {
                tag: "tray-first-close".into(),
                title: app_name.into(),
                body: hint_body.into(),
                actions: Vec::new(),
            });
            crate::preferences::update(|preferences| preferences.tray_hint_shown = true);
        }
    }

    /// 主窗口生命周期：记录句柄、拦截关闭、跟踪系统外观。
    pub fn install_main_window_lifecycle(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.window_handle = Some(window.window_handle());
        self.window_opening = false;
        let root = cx.entity().downgrade();
        window.on_window_should_close(cx, move |_window, cx| {
            let _ = root.update(cx, |this, cx| this.handle_main_window_close(cx));
            true
        });
        let observer = cx.entity().downgrade();
        window
            .observe_window_appearance(move |window, cx| {
                let _ = observer.update(cx, |this, cx| {
                    this.on_appearance_changed(window.appearance(), cx)
                });
            })
            .detach();
    }

    pub fn set_notification_responses(
        &mut self,
        responses: Arc<std::sync::Mutex<Vec<SystemNotificationResponse>>>,
    ) {
        self.notification_responses = responses;
    }

    pub fn notification_unread_count(&self) -> usize {
        crate::notification_center::unread_count(&self.notification_items)
    }

    pub fn toggle_notifications(&mut self, cx: &mut Context<Self>) {
        if self.right_panel_open && self.right_panel == RightPanel::Notifications {
            self.right_panel_open = false;
            cx.notify();
            return;
        }
        self.open_notifications(cx);
    }

    pub fn open_notifications(&mut self, cx: &mut Context<Self>) {
        if !self.is_signed_in() {
            return;
        }
        self.right_panel = RightPanel::Notifications;
        self.right_panel_open = true;
        self.refresh_notifications(cx);
        cx.notify();
    }

    /// Copy 反馈：记录 key 并启动 1.2s 定时清除（同 key 的更新会取消旧计时）。
    pub(in crate::root_view) fn mark_chat_actions_copied(
        &mut self,
        key: String,
        cx: &mut Context<Self>,
    ) {
        self.chat.copied_actions = Some(key);
        self.chat.copied_actions_serial = self.chat.copied_actions_serial.wrapping_add(1);
        let serial = self.chat.copied_actions_serial;
        cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(std::time::Duration::from_millis(1200))
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.chat.copied_actions_serial == serial {
                    this.chat.copied_actions = None;
                    cx.notify();
                }
            });
        })
        .detach();
        cx.notify();
    }

    pub fn refresh_notifications(&mut self, cx: &mut Context<Self>) {
        let Some(token) = self.notification_token() else {
            return;
        };
        if self.notification_loading {
            return;
        }
        self.notification_loading = true;
        self.notification_error = None;
        cx.notify();
        let root = cx.entity();
        let api = Arc::new(cgc_platform::notifications::HttpNotificationsApi::from_env());
        cx.spawn(async move |_weak, cx| {
            let result = cx
                .background_executor()
                .spawn(async move { api.feed_page(&token, 50, None) })
                .await;
            root.update(cx, |this, cx| {
                this.apply_notification_page(result, false, cx)
            });
        })
        .detach();
    }

    pub fn set_notification_filter(
        &mut self,
        filter: crate::notification_center::NotificationFilter,
        cx: &mut Context<Self>,
    ) {
        self.notification_filter = filter;
        cx.notify();
    }

    pub fn load_more_notifications(&mut self, cx: &mut Context<Self>) {
        let Some(token) = self.notification_token() else {
            return;
        };
        let Some(cursor) = self.notification_next_cursor.clone() else {
            return;
        };
        if self.notification_loading {
            return;
        }
        self.notification_loading = true;
        self.notification_error = None;
        cx.notify();
        let root = cx.entity();
        let api = Arc::new(cgc_platform::notifications::HttpNotificationsApi::from_env());
        cx.spawn(async move |_weak, cx| {
            let result = cx
                .background_executor()
                .spawn(async move { api.feed_page(&token, 50, Some(&cursor)) })
                .await;
            root.update(cx, |this, cx| {
                this.apply_notification_page(result, true, cx)
            });
        })
        .detach();
    }

    fn apply_notification_page(
        &mut self,
        result: Result<cgc_platform::notifications::NotificationPage, cgc_platform::api::ApiError>,
        append: bool,
        cx: &mut Context<Self>,
    ) {
        self.notification_loading = false;
        match result {
            Ok(page) => {
                self.notification_items = crate::notification_center::merge_notifications(
                    &self.notification_items,
                    &page.items,
                    append,
                );
                self.notification_next_cursor = page.next_cursor;
                self.notification_loaded = true;
                self.notification_error = None;
            }
            Err(error) => {
                self.notification_error = Some(error.diagnostic());
            }
        }
        cx.notify();
    }

    pub fn mark_notification_read(&mut self, id: &str, cx: &mut Context<Self>) {
        if let Some(item) = self
            .notification_items
            .iter_mut()
            .find(|item| item.id == id)
        {
            if item.read_at.is_none() {
                item.read_at = Some("local".to_string());
            }
        }
        cx.dismiss_system_notification(id);
        cx.notify();
        let Some(token) = self.notification_token() else {
            return;
        };
        let id = id.to_string();
        let api = Arc::new(cgc_platform::notifications::HttpNotificationsApi::from_env());
        cx.background_executor()
            .spawn(async move {
                let _ = api.mark_read(&token, &id);
            })
            .detach();
    }

    pub fn open_notification(&mut self, id: &str, cx: &mut Context<Self>) {
        let item = self
            .notification_items
            .iter()
            .find(|item| item.id == id)
            .cloned();
        let Some(item) = item else {
            return;
        };
        self.mark_notification_read(id, cx);
        let link = item
            .client_deep_link()
            .unwrap_or_else(|| "cgc://workspace".to_string());
        self.handle_deep_link_in_current_window(&link, cx);
    }

    pub fn start_notification_poll(&mut self, cx: &mut Context<Self>) {
        if self.notification_started {
            return;
        }
        self.notification_started = true;
        let root = cx.entity();
        let responses = self.notification_responses.clone();
        let api = Arc::new(cgc_platform::notifications::HttpNotificationsApi::from_env());
        cx.spawn(async move |_weak, cx| {
            let mut last_fetch: Option<std::time::Instant> = None;
            loop {
                loop {
                    let response = responses.lock().ok().and_then(|mut queue| queue.pop());
                    let Some(response) = response else {
                        break;
                    };
                    root.update(cx, |this, cx| {
                        this.handle_notification_response(response, cx)
                    });
                }
                let token = root.update(cx, |this, _| this.notification_token());
                if let Some(token) = token {
                    let should_fetch = last_fetch
                        .map(|last| last.elapsed() >= std::time::Duration::from_secs(60))
                        .unwrap_or(true);
                    if should_fetch {
                        let api = api.clone();
                        let result = cx
                            .background_executor()
                            .spawn(async move { api.feed(&token, 20) })
                            .await;
                        root.update(cx, |this, cx| this.handle_notification_feed(result, cx));
                        last_fetch = Some(std::time::Instant::now());
                    }
                }
                cx.background_executor()
                    .timer(std::time::Duration::from_millis(500))
                    .await;
            }
        })
        .detach();
    }

    fn notification_token(&self) -> Option<String> {
        self.session
            .signed_in()
            .map(|signed_in| signed_in.token.clone())
            .filter(|token| !token.is_empty())
    }

    fn handle_notification_feed(
        &mut self,
        result: Result<Vec<cgc_platform::notifications::Notification>, cgc_platform::api::ApiError>,
        cx: &mut Context<Self>,
    ) {
        let items = match result {
            Ok(items) => items,
            Err(error) => {
                if !matches!(error, cgc_platform::api::ApiError::Unauthorized) {
                    log::warn!(target: "notifications", "通知列表拉取失败：{error:?}");
                }
                return;
            }
        };
        self.notification_items = crate::notification_center::merge_notifications(
            &self.notification_items,
            &items,
            false,
        );
        cx.notify();
        let first_launch = self.notification_seen.is_empty();
        let fresh = items
            .into_iter()
            .filter(|item| item.read_at.is_none() && !self.notification_seen.contains_key(&item.id))
            .collect::<Vec<_>>();
        if fresh.is_empty() {
            return;
        }
        let language = self.language;
        if crate::notifications::should_summarize(first_launch, fresh.len()) {
            let latest = &fresh[0];
            let title = translate(language, Key::AppNotificationsUnreadSummary)
                .replace("{count}", &fresh.len().to_string());
            cx.show_system_notification(SystemNotification {
                tag: latest.id.clone().into(),
                title: title.into(),
                body: latest.title.clone().into(),
                actions: Vec::new(),
            });
            for item in &fresh {
                let link = item
                    .client_deep_link()
                    .unwrap_or_else(|| "cgc://workspace".to_string());
                crate::notifications::remember(&mut self.notification_seen, &item.id, &link);
            }
        } else {
            for item in fresh.iter().take(3) {
                let link = item
                    .client_deep_link()
                    .unwrap_or_else(|| "cgc://workspace".to_string());
                cx.show_system_notification(SystemNotification {
                    tag: item.id.clone().into(),
                    title: item.title.clone().into(),
                    body: item.body.clone().into(),
                    actions: Vec::new(),
                });
                crate::notifications::remember(&mut self.notification_seen, &item.id, &link);
            }
        }
        crate::notifications::save_seen(&self.notification_seen);
    }

    fn handle_notification_response(
        &mut self,
        response: SystemNotificationResponse,
        cx: &mut Context<Self>,
    ) {
        let tag = response.tag.to_string();
        let Some(link) = self.notification_seen.get(&tag).cloned() else {
            return;
        };
        if let Some(item) = self
            .notification_items
            .iter_mut()
            .find(|item| item.id == tag)
        {
            if item.read_at.is_none() {
                item.read_at = Some("local".to_string());
            }
        }
        self.handle_deep_link(&link, cx);
        if let Some(token) = self.notification_token() {
            let api = Arc::new(cgc_platform::notifications::HttpNotificationsApi::from_env());
            cx.background_executor()
                .spawn(async move {
                    let _ = api.mark_read(&token, &tag);
                })
                .detach();
        }
    }

    pub fn install_tray(&mut self, tray: cgc_platform::tray::Tray, cx: &mut Context<Self>) {
        let root = cx.entity();
        let tray = tray;
        cx.spawn(async move |_weak, cx| loop {
            while let Some(event) = tray.take_event() {
                root.update(cx, |this, cx| this.handle_tray_event(event, cx));
            }
            cx.background_executor()
                .timer(std::time::Duration::from_millis(100))
                .await;
        })
        .detach();
    }

    fn handle_tray_event(&mut self, event: cgc_platform::tray::TrayEvent, cx: &mut Context<Self>) {
        match event {
            cgc_platform::tray::TrayEvent::Open | cgc_platform::tray::TrayEvent::Click => {
                self.activate_window(cx);
            }
            cgc_platform::tray::TrayEvent::Notifications => {
                self.open_notifications(cx);
                self.activate_window(cx);
            }
            cgc_platform::tray::TrayEvent::Settings => self.open_settings_window(cx),
            cgc_platform::tray::TrayEvent::Quit => cx.quit(),
        }
    }

    pub fn open_main_window(&mut self, cx: &mut Context<Self>) {
        if self.window_opening || self.window_handle.is_some() {
            return;
        }
        self.window_opening = true;
        let root = cx.entity();
        // 这里通常正处于 RootView 的一次 update 中（深链/托盘事件）；open_window
        // 会立即绘制 root，不能在 update 未结束时重入。把开窗整体推迟到 effect 阶段。
        cx.defer(move |cx| {
            let root_for_window = root.clone();
            let Ok(window_handle) = cx.open_window(main_window_options(), move |_window, _cx| {
                root_for_window.clone()
            }) else {
                root.update(cx, |this, _| this.window_opening = false);
                return;
            };
            let window_handle: AnyWindowHandle = window_handle.into();
            let Some(handle) = window_handle.downcast::<RootView>() else {
                return;
            };
            let _ = handle.update(cx, |this, window, cx| {
                this.install_main_window_lifecycle(window, cx);
            });
        });
    }

    pub(in crate::root_view) fn activate_window(&mut self, cx: &mut Context<Self>) {
        if self.window_opening {
            return;
        }
        if let Some(window_handle) = self.window_handle {
            if window_handle
                .update(cx, |_, window, _| window.activate_window())
                .is_ok()
            {
                return;
            }
            // update 失败也可能只是当前窗口正在更新（重入），并不代表窗口已关闭。
            // 只有确实没有 RootView 窗口时才重建，避免一次点击多开一个窗口。
            let root_window_exists = cx
                .windows()
                .iter()
                .any(|handle| handle.downcast::<RootView>().is_some());
            if root_window_exists {
                return;
            }
            self.window_handle = None;
        }
        self.open_main_window(cx);
    }

    pub fn handle_deep_link(&mut self, raw: &str, cx: &mut Context<Self>) {
        self.handle_deep_link_with_activation(raw, true, cx);
    }

    /// 通知中心点击：当前窗口已经存在，只导航，不能再调用 activate_window，
    /// 否则同一次 update 内的 activate 失败会被误判成“窗口已关闭”而新建窗口。
    fn handle_deep_link_in_current_window(&mut self, raw: &str, cx: &mut Context<Self>) {
        self.handle_deep_link_with_activation(raw, false, cx);
    }

    fn handle_deep_link_with_activation(
        &mut self,
        raw: &str,
        activate: bool,
        cx: &mut Context<Self>,
    ) {
        let mut should_activate = activate;
        match crate::deep_link::parse(raw) {
            Ok(link) if link.path == "/settings" => {
                if self.is_signed_in() {
                    self.open_settings_window(cx);
                    should_activate = false;
                } else {
                    self.pending_link = Some(link.path);
                }
            }
            Ok(link) => {
                self.pending_link = Some(link.path);
                self.consume_pending_link();
            }
            Err(error) => {
                log::warn!(target: "deeplink", "深链被拒绝：{error:?}");
                self.pending_link = None;
                self.navigate("/");
                self.pane_notice =
                    Some(translate(self.language, Key::AppDeeplinkInvalid).to_string());
            }
        }
        if should_activate && self.is_signed_in() {
            self.activate_window(cx);
        }
        cx.notify();
    }

    pub(in crate::root_view) fn consume_pending_link(&mut self) {
        if !self.is_signed_in() {
            return;
        }
        // Settings 是独立窗口；留给 render 在登录后打开，不能走中心路由。
        if self.pending_link.as_deref() == Some("/settings") {
            return;
        }
        if let Some(path) = self.pending_link.take() {
            // R11：本次登录后已消费显式深链；随后首次工作区列表到达时，
            // restore 必须保留该路由，不能拿旧 active tab 把它覆盖掉。
            self.deep_link_keep_route = true;
            self.navigate(&path);
        }
    }

    pub fn start_external_link_pump(
        &mut self,
        instance: cgc_platform::instance::Instance,
        os_urls: Arc<std::sync::Mutex<Vec<String>>>,
        initial_urls: Vec<String>,
        cx: &mut Context<Self>,
    ) {
        cx.spawn(async move |this, cx| {
            let mut queued = initial_urls;
            loop {
                let mut urls = std::mem::take(&mut queued);
                if let Ok(mut os_urls) = os_urls.lock() {
                    urls.append(&mut os_urls);
                }
                let mut focus = false;
                while let Some(message) = instance.try_recv() {
                    urls.extend(message.urls);
                    focus = true;
                }
                let had_urls = !urls.is_empty();
                if had_urls || focus {
                    let updated = this.update(cx, |this, cx| {
                        for url in urls {
                            this.handle_deep_link(&url, cx);
                        }
                        // 带 URL 的 handoff 已经由 handle_deep_link 负责激活/开窗；
                        // 只有“无 URL 的二次启动”才额外聚焦。
                        if focus && !had_urls {
                            this.activate_window(cx);
                        }
                    });
                    if updated.is_err() {
                        break;
                    }
                }
                cx.background_executor()
                    .timer(std::time::Duration::from_millis(100))
                    .await;
            }
        })
        .detach();
    }

    pub fn navigate(&mut self, path: &str) {
        self.site_tree_search_focused = false;
        // `/` 不是可渲染页面：落到上次工作区概览，没有记录则落到「我的学习」。
        let target = if path == "/" {
            crate::routing::home_target(self.last_workspace_slug.as_deref())
        } else {
            path.to_string()
        };
        let path = target.as_str();
        if let crate::routing::RouteSelection::Match(route_match) = self.registry.select(path) {
            // 切台前先把旧台的导航状态落盘，否则 active tab 已随导航被清空。
            let next_slug = route_match.params.get("slug").cloned();
            let current_slug = self
                .workspaces
                .current()
                .map(|workspace| workspace.slug.clone())
                .or_else(|| self.last_workspace_slug.clone());
            if next_slug.is_some() && next_slug != current_slug {
                if let Some(previous) = self.workspaces.current_id().map(str::to_string) {
                    self.persist_workspace_state(&previous);
                }
                self.courses.reset();
                self.courses_started = false;
                self.courses_scope = None;
                self.events.reset();
                self.events_started = false;
                self.events_scope = None;
            }
            if let Some(slug) = next_slug.clone() {
                self.last_workspace_slug = Some(slug);
            }
            // 列表缓存带数据面身份：从详情/其它页面回到列表时也能发现归属不符。
            let route_id = route_match.route.id;
            if let Some(next_scope) = crate::routing::offering_list_scope(route_id) {
                let uses_events = matches!(
                    route_id,
                    "events.list" | "events.public_list" | "account.workspace"
                );
                let uses_courses = matches!(
                    route_id,
                    "courses.catalog" | "courses.public_list" | "account.workspace"
                );
                if uses_events
                    && crate::routing::list_scope_needs_reload(self.events_scope, next_scope)
                {
                    self.events.reset();
                    self.events_started = false;
                    self.events_scope = None;
                }
                if uses_courses
                    && crate::routing::list_scope_needs_reload(self.courses_scope, next_scope)
                {
                    self.courses.reset();
                    self.courses_started = false;
                    self.courses_scope = None;
                }
            }
            let is_learning = matches!(
                route_match.route.id,
                "courses.learning" | "courses.public_learning"
            );
            let next_course = matches!(
                route_match.route.id,
                "courses.detail"
                    | "courses.learning"
                    | "courses.public_detail"
                    | "courses.public_learning"
            )
            .then(|| route_match.params.get("id"))
            .flatten();
            let previous_course = self
                .current
                .as_ref()
                .filter(|current| {
                    matches!(
                        current.route.id,
                        "courses.detail"
                            | "courses.learning"
                            | "courses.public_detail"
                            | "courses.public_learning"
                    )
                })
                .and_then(|current| current.params.get("id"));
            if next_course.is_some() && next_course != previous_course {
                self.course_detail_started = false;
                self.course_detail.reset();
                self.projection.reset();
                self.selected_tier = None;
                self.age_confirmed = false;
                self.enrollment_error = None;
                self.enrolling = false;
                if self
                    .content
                    .content()
                    .is_none_or(|content| Some(&content.course_id) != next_course)
                {
                    self.content.reset();
                }
            }
            self.current = Some(route_match);
            self.active_tab = crate::root_view::state::active_tab_for_path(
                &self.tabs,
                self.active_tab.as_deref(),
                path,
            );
            self.events_started = false;
            self.detail_started = false;
            if is_learning && self.right_panel_open {
                self.right_panel = RightPanel::Outline;
                self.panel_memory = state::PanelMemory {
                    panel: RightPanel::Outline,
                    open: true,
                };
            }
        }
    }

    pub(in crate::root_view) fn navigate_to_event_detail(
        &mut self,
        event_id: &str,
        cx: &mut Context<Self>,
    ) {
        let public_face = self.current.as_ref().is_some_and(|route_match| {
            matches!(
                route_match.route.id,
                "events.public_list" | "events.public_detail"
            )
        });
        let path = match (&self.workspaces.current(), public_face) {
            (Some(workspace), false) => {
                crate::routing::workspace_path(&workspace.slug, &format!("/events/{event_id}"))
            }
            _ => format!("/events/{event_id}"),
        };
        let title = self
            .events
            .items()
            .iter()
            .find(|event| event.id == event_id)
            .map(|event| event.title.clone())
            .unwrap_or_else(|| "活动".to_string());
        self.open_page_tab(&path, title, cx);
    }

    pub fn toggle_language(&mut self) -> Language {
        self.language = self.language.toggle();
        self.language
    }

    pub fn cycle_theme(&mut self) -> ThemePreference {
        self.preference = self.preference.cycle();
        self.preference
    }

    pub fn select_theme(&mut self, name: String, cx: &mut Context<Self>) {
        if theme::apply_named(&name, cx) {
            theme::save_selected_theme(&name);
            self.theme_name = name;
            // 全局主题观察者可能在 `apply_named` 期间就触发了，那时
            // `theme_name` 还是旧值；这里用新名字再同步一次终端。
            self.sync_terminal_theme(cx);
        }
        cx.notify();
    }

    pub fn on_appearance_changed(&mut self, appearance: WindowAppearance, cx: &mut Context<Self>) {
        let _ = appearance;
        let _ = cx;
    }

    pub(in crate::root_view) fn session_token(&self) -> Option<String> {
        self.session
            .signed_in()
            .map(|session| session.token.clone())
    }

    pub(in crate::root_view) fn reset_events(&mut self) {
        self.events_started = false;
        self.enrollments_started = false;
        self.enrollments_rows.clear();
        self.learning_runs.clear();
        self.enrollments_state = EnrollmentsListState::Idle;
        self.enrollments_load_more_failed = false;
        self.detail_started = false;
        self.courses_started = false;
        self.course_detail_started = false;
        self.selected_event = None;
    }

    pub(in crate::root_view) fn force_sign_out(&mut self, cx: &mut Context<Self>) {
        self.session_epoch = self.session_epoch.wrapping_add(1);
        self.revoke_agent_authorization(cx);
        if let Some(runtime) = &self.native_runtime {
            runtime.stop();
        }
        self.session.sign_out_local();
        self.workspaces.reset();
        self.workspaces_started = false;
        self.session_checked = false;
        self.reset_workspace_data(cx);
        self.prepare_agent_authorization(cx);
        self.navigate("/");
        cx.notify();
    }

    pub(in crate::root_view) fn start_session_validation(&mut self, cx: &mut Context<Self>) {
        let Some(token) = self.session_token() else {
            return;
        };
        let api = self.session.api_handle();
        let task = cx
            .background_executor()
            .spawn(async move { api.validate(&token) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            if let Ok(false) = result {
                let _ = this.update(cx, |this, cx| this.force_sign_out(cx));
            }
        })
        .detach();
    }

    pub(in crate::root_view) fn start_workspace_load(&mut self, cx: &mut Context<Self>) {
        self.workspaces.begin_load();
        self.workspaces_started = true;
        let api = self.workspaces.api_handle();
        let token = self.session_token();
        let task = cx
            .background_executor()
            .spawn(async move { api.list_workspaces(token.as_deref()) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                match result {
                    Ok(workspaces) => {
                        let had_accessible_workspaces = this
                            .workspaces
                            .workspaces()
                            .iter()
                            .any(|workspace| workspace.can_access);
                        this.workspaces.adopt(workspaces);
                        // R4：工作区列表从空变非空后，此前按空 workspace_ids 加载的公开课程
                        // 列表/详情需要补查归属，否则来源徽标与工作区入口永远缺失。
                        if state::should_backfill_public_ownership(
                            had_accessible_workspaces,
                            this.workspaces
                                .workspaces()
                                .iter()
                                .any(|workspace| workspace.can_access),
                            this.courses_scope,
                            this.courses
                                .items()
                                .iter()
                                .any(|course| course.workspace_id.is_none()),
                        ) {
                            this.backfill_public_course_ownership(cx);
                        }
                        // 启动路由（上次工作区）优先于 adopt 的默认第一项。
                        let route_slug = this
                            .current
                            .as_ref()
                            .and_then(|route_match| route_match.params.get("slug"))
                            .cloned();
                        if let Some(slug) = route_slug {
                            let selected = this.workspaces.switch_to_slug(&slug)
                                || this
                                    .workspaces
                                    .current()
                                    .is_some_and(|workspace| workspace.slug == slug);
                            if selected {
                                this.last_workspace_slug = Some(slug);
                            }
                        }
                        this.prepare_agent_authorization(cx);
                        let keep_route = state::should_keep_initial_route(std::mem::take(
                            &mut this.deep_link_keep_route,
                        ));
                        this.restore_workspace_state(cx, keep_route);
                        // R5：工作区列表到达后，Site Tree 才能拿到当前工作区的数据面。
                        if this.right_panel_open && this.right_panel == RightPanel::SiteTree {
                            this.ensure_navigation_data(cx);
                        }
                    }
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) => this.workspaces.fail(&error),
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 失败态的重试入口（概览页 / 工作台切换器）：复位为 Idle 后重新拉列表。
    ///
    /// `start_workspace_load` 只在 `Idle` 时被自动触发，失败后不会自愈，
    /// 因此必须有一个显式入口把状态机推回加载（issue #1238）。
    pub(in crate::root_view) fn retry_workspace_load(&mut self, cx: &mut Context<Self>) {
        self.workspaces.retry_ready();
        self.start_workspace_load(cx);
        cx.notify();
    }

    pub(in crate::root_view) fn switch_workspace(
        &mut self,
        workspace_id: &str,
        cx: &mut Context<Self>,
    ) {
        // 路由是工作区的唯一真源：只导航到目标 slug，切换与恢复由 sync 完成。
        let Some(slug) = self
            .workspaces
            .workspaces()
            .iter()
            .find(|workspace| workspace.id == workspace_id && workspace.can_access)
            .map(|workspace| workspace.slug.clone())
        else {
            return;
        };
        self.navigate(&crate::routing::workspace_path(&slug, ""));
        cx.notify();
    }

    /// 路由里的 `/w/<slug>` 是工作区的唯一真源：路由变了就把当前工作区切过去。
    ///
    /// 未知或无权限的 slug 不静默保留错配的工作区，回到当前台并给出一次提示。
    pub(in crate::root_view) fn sync_workspace_route(&mut self, cx: &mut Context<Self>) {
        let route_slug = self
            .current
            .as_ref()
            .and_then(|route_match| route_match.params.get("slug"))
            .cloned();
        let current_slug = self
            .workspaces
            .current()
            .map(|workspace| workspace.slug.clone());
        let action = crate::routing::route_workspace_action(
            route_slug.as_deref(),
            current_slug.as_deref(),
            self.workspaces.workspaces(),
        );
        match action {
            crate::routing::WorkspaceRouteAction::Keep => {}
            crate::routing::WorkspaceRouteAction::Inaccessible => {
                self.notice_inaccessible_workspace();
            }
            crate::routing::WorkspaceRouteAction::Switch { id, slug } => {
                if self.workspaces.switch_to(&id) {
                    self.last_workspace_slug = Some(slug.clone());
                    crate::workspace_state::set_last_workspace(&slug);
                    self.reset_workspace_data(cx);
                    // 显式深链目标优先于该台上次停留的 tab；概览仍恢复上次页面。
                    let keep_route = self
                        .current
                        .as_ref()
                        .is_some_and(|route_match| route_match.route.id != "account.workspace");
                    self.restore_workspace_state(cx, keep_route);
                    self.prepare_agent_authorization(cx);
                }
            }
        }
    }

    fn notice_inaccessible_workspace(&mut self) {
        let Some(path) = self
            .workspaces
            .current()
            .map(|workspace| crate::routing::workspace_path(&workspace.slug, ""))
        else {
            return;
        };
        self.pane_notice = Some("该工作区不存在或你没有访问权限".to_string());
        self.navigate(&path);
    }

    pub(in crate::root_view) fn reset_workspace_data(&mut self, cx: &mut Context<Self>) {
        self.reset_events();
        self.events.reset();
        self.events_scope = None;
        self.detail.reset();
        self.courses.reset();
        self.courses_scope = None;
        self.nav_events.reset();
        self.nav_events_started = false;
        self.nav_events_serial = 0;
        self.nav_courses.reset();
        self.nav_courses_started = false;
        self.nav_courses_serial = 0;
        self.course_enrollments.clear();
        self.course_detail.reset();
        self.content.reset();
        self.notes.reset();
        self.notes_started = false;
        self.note_edit = None;
        self.note_pending_delete = None;
        self.notes_notice = None;
        self.selection_material_id = None;
        self.expanded_notes.clear();
        self.retro_checked.clear();
        self.projection.reset();
        self.pending_link = None;
        self.selected_event = None;
        self.selected_tier = None;
        self.age_confirmed = false;
        self.enrolling = false;
        self.enrollment_error = None;
        self.payment = PaymentViewState::Idle;
        self.payment_generation = self.payment_generation.saturating_add(1);
        self.deposit_consent = false;
        self.reset_chat_local(cx);
        self.tabs.clear();
        self.active_tab = None;
        self.site_tree_query.clear();
        self.site_tree_search_input = None;
        self.site_tree_search_subscription = None;
        self.site_tree_search_language = None;
        self.site_tree_course_open = None;
        self.site_tree_scroll = ScrollHandle::new();
        self.site_tree_scroll_restore = None;
        self.review_event_keys.clear();
        self.notification_items.clear();
        self.notification_next_cursor = None;
        self.notification_loaded = false;
        self.notification_loading = false;
        self.notification_error = None;
        self.notification_filter = crate::notification_center::NotificationFilter::All;
        self.notification_scroll = ScrollHandle::new();
        if self.right_panel == RightPanel::Notifications {
            self.right_panel = RightPanel::SiteTree;
            self.right_panel_open = false;
        }
    }

    /// 详情/正文/projection 的 epoch 守卫：只有依赖工作区的路由才绑定 epoch。
    ///
    /// 公开路由（`courses.public_*` / `events.public_*`）的请求与工作区无关；绑定 epoch 会
    /// 让「工作区列表先返回」把已经在途的响应判过期，而 `adopt()` 递增 epoch 后没人重发，
    /// 页面永久停在加载态（R1）。与 `start_courses_load_with_scope` 的列表口径一致。
    pub(in crate::root_view) fn workspace_bound_epoch(&self) -> Option<u64> {
        self.current
            .as_ref()
            .is_some_and(|route_match| crate::routing::requires_workspace(route_match.route.id))
            .then(|| self.workspaces.epoch())
    }

    /// 当前路由指向的对象 id（课程与活动都用 `:id` 参数）。
    ///
    /// 过期响应丢弃时用它判断「用户是否还停在这条稿子上」：只有还在，复位才安全。
    pub(in crate::root_view) fn route_object_id(&self) -> Option<&str> {
        self.current
            .as_ref()
            .and_then(|route_match| route_match.params.get("id"))
            .map(String::as_str)
    }

    pub(in crate::root_view) fn start_chat(&mut self, cx: &mut Context<Self>) {
        if matches!(
            self.chat.session.phase,
            ConnectionPhase::Starting | ConnectionPhase::Ready
        ) {
            return;
        }
        let Some(authority) = self
            .agent_mcp
            .clone()
            .filter(|context| !context.is_revoked())
        else {
            self.chat.start_after_authorization = true;
            self.prepare_agent_authorization(cx);
            return;
        };
        let lease = authority.lease().clone();
        let epoch = self.workspaces.epoch();
        let cwd = self
            .native_scope
            .as_ref()
            .map(|scope| scope.root.clone())
            .unwrap_or_else(crate::agent_workspace_root);
        self.chat.session.disconnect();
        let client_generation = self.chat.session.generation;
        let requested_agent = self.chat.selected_agent.clone();
        // Stage 3.5a：不再有课程页专用会话指针；只按历史侧栏的 restore_id 恢复。
        let load_session = self.chat.restore_id.take();
        self.chat.load_retry_available = load_session.is_some();
        self.chat.session.session_id = None;
        self.chat.session.configs.clear();
        self.chat.session.commands.clear();
        self.chat.configs_applied = false;
        self.chat.history_open = load_session.is_some();
        self.chat.session.phase = ConnectionPhase::Starting;
        // Stage 3.3：从本地历史恢复时保留已加载的内容先渲染（离线可读），
        // 新会话/普通启动才清空线程。
        if self.chat.replay.is_none() {
            self.chat.session.thread =
                ConversationThread::default().with_capabilities(ThreadCapabilities::acp());
        }
        self.chat.auto_prompted = false;
        let task = cx.background_executor().spawn(async move {
            let registry = Registry::builtin().map_err(|error| ChatStartError {
                message: error.diagnostic(),
                detected: Vec::new(),
                node_found: None,
            })?;
            let managed = NodeRuntime::new(NodeRuntimeManager::default_manager().root);
            let detected = detect_all(&registry, Some(&managed));
            let guidance = detected
                .iter()
                .map(|agent| {
                    (
                        agent.entry.display_name.clone(),
                        format!("{:?}", agent.status),
                    )
                })
                .collect::<Vec<_>>();
            let node_found = managed.version().filter(|version| {
                cgc_platform::agent::detect::version_at_least(
                    version,
                    cgc_platform::agent::node_runtime::NODE_VERSION,
                )
            });
            if std::env::var("CGC_NO_AGENT").as_deref() == Ok("1") {
                return Err(ChatStartError {
                    message: "no local agent ready (QA)".to_string(),
                    detected: guidance,
                    node_found,
                });
            }
            let chosen = match requested_agent.as_deref() {
                Some(requested) => detected
                    .iter()
                    .find(|agent| {
                        agent.entry.id == requested
                            && matches!(agent.status, AgentStatus::Ready { .. })
                    })
                    .ok_or_else(|| ChatStartError {
                        message: format!("selected agent not ready: {requested}"),
                        detected: guidance.clone(),
                        node_found: node_found.clone(),
                    })?,
                None => detected
                    .iter()
                    .find(|agent| {
                        agent.entry.id == "omp" && matches!(agent.status, AgentStatus::Ready { .. })
                    })
                    .or_else(|| {
                        detected
                            .iter()
                            .find(|agent| matches!(agent.status, AgentStatus::Ready { .. }))
                    })
                    .ok_or_else(|| ChatStartError {
                        message: "no local agent ready".to_string(),
                        detected: guidance.clone(),
                        node_found: node_found.clone(),
                    })?,
            };
            let plan = build_launch(&chosen.entry, Some(&managed), &cwd).map_err(|error| {
                ChatStartError {
                    message: error.to_string(),
                    detected: guidance,
                    node_found,
                }
            })?;
            // `None`：用当前生效端点（env > settings.json > 编译期默认值），与 GraphQL 同源。
            let endpoint = mcp_endpoint(None);
            let server = build_mcp_server(&chosen.entry, &lease, &endpoint);
            Ok::<PreparedChat, ChatStartError>(PreparedChat {
                agent_id: chosen.entry.id.clone(),
                agent_name: chosen.entry.display_name.clone(),
                plan,
                server,
            })
        });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                if this.workspaces.epoch() != epoch
                    || this.chat.session.generation != client_generation
                    || authority.is_revoked()
                {
                    return;
                }
                match result {
                    Ok(prepared) => {
                        let plan = prepared.plan;
                        let server = prepared.server.clone();
                        let make_config = |load_session: Option<&str>| {
                            let config = AcpHostConfig::from_launch_plan(plan.clone())
                                .with_name("agent")
                                .with_mcp_servers(vec![server.clone()]);
                            match load_session {
                                Some(session_id) => config.with_load_session(session_id),
                                None => config,
                            }
                        };
                        let started = match load_session.as_deref() {
                            Some(session_id) => match AcpHost::start(make_config(Some(session_id)))
                            {
                                Ok(host) => Ok(host),
                                // 会话可能已被 agent 清理；重新建会话，
                                // 不把用户卡在“重试也会失败”的错误页。
                                Err(_) => AcpHost::start(make_config(None)),
                            },
                            None => AcpHost::start(make_config(None)),
                        };
                        match started {
                            Ok(host) => {
                                let generation = this.chat.session.attach(host);
                                this.chat.selected_agent = Some(prepared.agent_id.clone());
                                this.chat.agent = prepared.agent_name;
                                this.chat.npx_cache_retry = false;
                                this.spawn_chat_poller(cx, generation);
                            }
                            Err(error) => {
                                let message = error.to_string();
                                let recovered = !this.chat.npx_cache_retry
                                    && npx_cache_dir_from_error(&message).map(|dir| {
                                        this.chat.npx_cache_retry = true;
                                        let _ = std::fs::remove_dir_all(&dir);
                                        true
                                    }) == Some(true);
                                if recovered {
                                    this.chat.session.phase = ConnectionPhase::Idle;
                                    this.start_chat(cx);
                                } else {
                                    this.chat.session.phase = ConnectionPhase::Failed(message);
                                }
                            }
                        }
                    }
                    Err(error) => {
                        this.chat.guidance = Some(ChatGuidance {
                            detected: error.detected,
                            node_found: error.node_found,
                        });
                        this.chat.session.phase = ConnectionPhase::Failed(error.message);
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn spawn_chat_poller(
        &mut self,
        cx: &mut Context<Self>,
        generation: u64,
    ) {
        cx.spawn(async move |this, cx| loop {
            cx.background_executor()
                .timer(Duration::from_millis(100))
                .await;
            let keep = this
                .update(cx, |this, cx| this.drain_chat_events(generation, cx))
                .unwrap_or(false);
            if !keep {
                break;
            }
        })
        .detach();
    }

    pub(in crate::root_view) fn drain_chat_events(
        &mut self,
        generation: u64,
        cx: &mut Context<Self>,
    ) -> bool {
        if generation != self.chat.session.generation {
            return false;
        }
        let events = self.chat.session.drain(generation);
        let had_events = !events.is_empty();
        let mut turn_ended = false;
        for event in events {
            if generation != self.chat.session.generation {
                return false;
            }
            // Stage 3.2b 路线 A（Zed 对齐）：settings 级 toolPermissions 规则只作用于
            // native agent。external ACP agent 的审批完全由 agent 自身模式与 options
            // 决定——客户端只渲染共享审批卡、按用户选择的 option_id 回传，不做策略
            // 拦截/自动决定（agent 若在 auto 模式自行放行，客户端也收不到请求）。
            //
            // 会话行（消息 / 工具卡 / 计划 / 用量 / 审批 / 结束 / 错误）统一走两轨共用的
            // ingestion；这里只保留 ACP 连接自身的会话级状态（就绪、配置、历史、退出）。
            //
            // Stage 3.3：从本地历史恢复 ACP 会话时，agent 经 session/load 回放的历史
            // 先收进 replay 线程；Ready 时按 resume_decision 决定替换本地内容或降级。
            let replayed = self.chat.replay.as_mut().is_some_and(|replay| {
                let applied = agent_ingest::apply_thread_event(&mut replay.thread, &event);
                replay.saw_events |= applied;
                applied
            });
            if !replayed && !self.chat.session.ingest_external(generation, &event) {
                continue;
            }
            if !replayed {
                self.chat.learning_mutation.observe(&event);
            }
            self.page_context
                .observe_event(&self.chat.conversation_scope(), &event);
            match &event {
                HostEvent::Ready {
                    agent_name,
                    version,
                    session_id: _,
                } => {
                    self.page_context
                        .invalidate_loaded(&self.chat.conversation_scope());
                    self.chat.agent = agent_name.clone();
                    self.chat.version = Some(version.clone());
                    // Stage 3.3：本地历史恢复结果（回放替换 / 降级保留本地记录）。
                    self.finish_history_restore(cx);
                }
                HostEvent::AvailableCommands { .. } => {}
                HostEvent::ConfigOptions { .. } => {
                    if !self.chat.configs_applied {
                        self.chat.configs_applied = true;
                        let agent_id = self
                            .chat
                            .selected_agent
                            .clone()
                            .unwrap_or_else(|| "omp".to_string());
                        for config in self.chat.session.configs.clone() {
                            if let Some(value) = load_chat_pref(&agent_id, &config.id) {
                                if let Some(host) = &self.chat.session.host {
                                    let _ = host.set_config(config.id.clone(), value);
                                }
                            }
                        }
                    }
                }
                HostEvent::Sessions { sessions } => {
                    self.chat.sessions = sessions.clone();
                    // agent 的 session 列表只用于标题/指针；统一历史从本地库加载。
                    self.chat.history = self.load_unified_history();
                    if std::env::var("CGC_AUTO_RESTORE").as_deref() == Ok("1")
                        && !self.chat.auto_prompted
                        && !self.chat.sessions.is_empty()
                    {
                        self.chat.auto_prompted = true;
                        let session_id = self.chat.sessions[0].session_id.clone();
                        self.restore_chat_session(session_id, cx);
                    }
                }
                HostEvent::ThoughtDelta(_) | HostEvent::Delta(_) | HostEvent::ToolCall { .. } => {}
                HostEvent::TitleUpdated { .. } => {
                    // Stage 3.3：TitleUpdated 是 agent 生成的标题（ingestion 已写入
                    // thread.title）；title_override 只由用户重命名写入，二者互不覆盖。
                    self.schedule_acp_transcript_save(cx);
                }
                HostEvent::PermissionRequested { .. } => {
                    if std::env::var("CGC_AUTO_APPROVE").as_deref() == Ok("1") {
                        self.respond_chat_permission(true, cx);
                    }
                }
                HostEvent::TurnEnd { .. } => {
                    turn_ended = true;
                }
                HostEvent::Error { message } => {
                    // Stage 3.3：本地历史恢复失败（session/load 不可用）→ 保留本地
                    // 记录并提示，不再清指针重开新会话（用户可点「新建会话」）。
                    if self.chat.replay.is_some() {
                        let replay = self.chat.replay.take().expect("replay state");
                        if crate::acp_history::resume_decision(
                            true,
                            replay.has_local_content,
                            replay.saw_events,
                        ) == crate::acp_history::ResumeDecision::KeepLocalRecord
                        {
                            self.chat.session.host.take();
                            self.chat.load_retry_available = false;
                            self.chat.restore_id = None;
                            self.chat.resumed_without_history = true;
                            self.chat.session.phase = ConnectionPhase::Ready;
                            agent_ingest::apply_notice(
                                &mut self.chat.session.thread,
                                crate::acp_history::RESUMED_WITHOUT_HISTORY,
                            );
                            // 降级提示只是 UI 层 Notice，不重复写回本地 transcript。
                            cx.notify();
                            return false;
                        }
                    }
                    if Self::should_retry_stale_session(self.chat.load_retry_available, message) {
                        // session/load 的错误是在 host 线程异步返回的，不是 AcpHost::start
                        // 的同步 Err；这里丢弃旧 host、清指针并重开 session/new。
                        self.chat.load_retry_available = false;
                        self.chat.session.host.take();
                        self.chat.restore_id = None;
                        self.chat.session.phase = ConnectionPhase::Idle;
                        self.start_chat(cx);
                        // 旧 host 可能紧接着发 Exited；不能让它在下一轮把新 host 清掉。
                        cx.notify();
                        return false;
                    }
                    self.chat.session.phase = ConnectionPhase::Failed(message.clone());
                }
                HostEvent::Exited => {}
                HostEvent::ModeUpdated { .. }
                | HostEvent::PlanUpdated { .. }
                | HostEvent::UsageUpdated { .. }
                | HostEvent::CompactionUpdated { .. }
                | HostEvent::UserMessage(_)
                | HostEvent::ToolCallUpdated { .. } => {}
            }
        }
        if self.chat.learning_mutation.take_changed() {
            self.refresh_projection_after_learning_mutation(cx);
        }
        if matches!(self.chat.session.phase, ConnectionPhase::Ready)
            && std::env::var("CGC_AUTO_HISTORY").as_deref() == Ok("1")
            && self.history_sidebar.is_none()
        {
            self.open_chat_history(cx);
        }
        // QA/截图：Ready 后自动发一条 prompt。
        if self.chat.session.can_submit()
            && !self.chat.auto_prompted
            && std::env::var("CGC_AUTO_CHAT").as_deref() == Ok("1")
        {
            self.chat.auto_prompted = true;
            if let Ok(prompt) = std::env::var("CGC_AUTO_CHAT_PROMPT") {
                if !prompt.trim().is_empty() {
                    self.send_chat_text(prompt, cx);
                }
            }
        }
        if had_events {
            if turn_ended {
                // 回合结束立刻落库（内容 + metadata），保证进程退出/重启前已持久化。
                self.save_acp_transcript_now();
            } else if !self.chat.session.thread.entries.is_empty() {
                self.schedule_acp_transcript_save(cx);
            }
        }
        cx.notify();
        self.chat.session.host.is_some()
    }

    /// 本地历史恢复收尾：回放可用则替换为 agent 回放内容；否则保留本地记录并提示
    /// （Zed `resumed_without_history` 语义）。
    fn finish_history_restore(&mut self, cx: &mut Context<Self>) {
        let Some(replay) = self.chat.replay.take() else {
            return;
        };
        // 回放成功也不证明某个 tab 的完整正文仍在模型历史里；下一次提交保守重载。
        self.page_context
            .invalidate_loaded(&self.chat.conversation_scope());
        match crate::acp_history::resume_decision(
            false,
            replay.has_local_content,
            replay.saw_events,
        ) {
            crate::acp_history::ResumeDecision::UseReplay => {
                let mut restored = replay.thread;
                let users = |thread: &ConversationThread| {
                    thread
                        .entries
                        .iter()
                        .filter_map(|entry| match entry {
                            cgc_agent_ui::conversation::Entry::User { text } => Some(text.clone()),
                            _ => None,
                        })
                        .collect::<Vec<_>>()
                };
                if users(&restored) == users(&self.chat.session.thread) {
                    restored.user_drafts = self.chat.session.thread.user_drafts.clone();
                } else if self
                    .chat
                    .session
                    .thread
                    .user_drafts
                    .iter()
                    .any(Option::is_some)
                {
                    restored = self.chat.session.thread.clone();
                }
                self.chat.session.restore_thread(restored);
                self.chat.resumed_without_history = false;
            }
            crate::acp_history::ResumeDecision::KeepLocalRecord => {
                self.chat.resumed_without_history = true;
                agent_ingest::apply_notice(
                    &mut self.chat.session.thread,
                    crate::acp_history::RESUMED_WITHOUT_HISTORY,
                );
                // 降级提示只是 UI 层 Notice，不重复写回本地 transcript。
                cx.notify();
                return;
            }
            crate::acp_history::ResumeDecision::NewSession
            | crate::acp_history::ResumeDecision::Empty => {
                self.chat.resumed_without_history = false;
            }
        }
        if !self.chat.session.thread.entries.is_empty() {
            self.save_acp_transcript_now();
        }
        cx.notify();
    }

    /// 从统一线程列表恢复 native 线程。
    pub(in crate::root_view) fn open_local_native_thread(
        &mut self,
        thread_id: String,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.dismiss_terminal_for_chat(cx);
        let Some(runtime) = self.native_runtime.clone() else {
            return;
        };
        let operation = runtime.open_thread(thread_id);
        cx.spawn(async move |this, cx| {
            let result = operation.await;
            let _ = this.update(cx, |this, cx| {
                match result {
                    Ok(_) => {
                        this.set_native_chat_mode(true);
                        this.agent_panel_open = true;
                    }
                    Err(error) => this.pane_notice = Some(error.to_string()),
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// Stage 3.3：把当前 ACP 会话写入本地 conversations.db（内容 + metadata）。
    fn save_acp_transcript_now(&mut self) {
        let Some(session_id) = self.chat.session.session_id.clone() else {
            return;
        };
        if self.chat.session.thread.entries.is_empty() {
            return;
        }
        let agent_id = self
            .chat
            .selected_agent
            .clone()
            .unwrap_or_else(|| self.chat.agent.clone());
        if agent_id.trim().is_empty() {
            return;
        }
        let Ok(mut store) = crate::acp_history::open_conversation_store() else {
            return;
        };
        let now = cgc_agent_store::now_utc_rfc3339();
        let _ = crate::acp_history::save_transcript(
            &mut store,
            &self.chat.session.thread,
            &session_id,
            &agent_id,
            self.chat.title_override.as_deref(),
            &now,
        );
        // 同一份会话再写一份可恢复投影（add-only 新表）：未答审批不会被当成活跃授权。
        let paths = AppPaths::from_env();
        if self.store_writer.is_none() {
            self.store_writer = Some(cgc_agent_store::StoreWriter::spawn(
                paths.data_root.join(cgc_agent_store::CONVERSATIONS_DB),
                paths.data_root.join("agent").join("threads.db"),
            ));
        }
        let snapshot = cgc_agent_store::SavedConversation::from_thread(
            &self.chat.session.thread,
            cgc_agent_store::SnapshotSource::Acp,
            self.chat.acp_save_generation,
        );
        if let Some(writer) = &self.store_writer {
            let _ = writer.submit(cgc_agent_store::WriterCommand::Snapshot {
                target: cgc_agent_store::StoreTarget::Acp,
                thread: None,
                snapshot: Box::new(snapshot),
            });
        }
        // 本地历史排序依赖 conversations.db 的 updated_at：保存后刷新统一列表。
        self.chat.history = self.load_unified_history();
    }

    /// 事件驱动保存做防抖：流式期间每批事件只重置计时器，空闲 400ms 后落库。
    fn schedule_acp_transcript_save(&mut self, cx: &mut Context<Self>) {
        self.chat.acp_save_generation = self.chat.acp_save_generation.wrapping_add(1);
        let generation = self.chat.acp_save_generation;
        cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(std::time::Duration::from_millis(400))
                .await;
            let _ = this.update(cx, |this, _cx| {
                if this.chat.acp_save_generation == generation {
                    this.save_acp_transcript_now();
                }
            });
        })
        .detach();
    }

    /// 统一历史：native（threads.db，仅 native agent）+ ACP（conversations.db），
    /// 按 updated_at 倒序。native store 的 schema/内容不变。
    /// 统一历史：native（threads.db，仅 native agent）+ ACP（conversations.db），
    /// 按 updated_at 倒序；读前执行 ACP 自动归档（每 agent 最近 N 条，幂等）。
    /// ACP 归档在 sidebar_threads.archived；native 归档在 native_archived
    /// （threads.db schema 不变），这里统一 merge 成 archived 位。
    pub(in crate::root_view) fn load_unified_history(
        &self,
    ) -> Vec<crate::acp_history::HistoryEntry> {
        let _ = crate::acp_history::auto_archive_recent(crate::acp_history::RECENT_PER_AGENT);
        let native_path = AppPaths::from_env()
            .data_root
            .join("agent")
            .join("threads.db");
        let native = SessionStore::open(native_path)
            .ok()
            .and_then(|store| store.list_threads(50).ok())
            .unwrap_or_default();
        let store = crate::acp_history::open_conversation_store().ok();
        let acp = store
            .as_ref()
            .and_then(|store| store.list_all(200).ok())
            .unwrap_or_default();
        let native_archived = store
            .as_ref()
            .and_then(|store| store.archived_native_threads().ok())
            .unwrap_or_default();
        let terminals = store
            .as_ref()
            .and_then(|store| store.list_terminal_sessions(50).ok())
            .unwrap_or_default();
        crate::acp_history::merge_history_with_terminals(native, acp, &native_archived, terminals)
    }

    pub(in crate::root_view) fn reset_config_search(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.chat.config_search.clear();
        if let Some(input) = self.chat.config_search_input.clone() {
            input.update(cx, |input, cx| {
                input.set_value("", window, cx);
                input.focus(window, cx);
            });
        }
        cx.notify();
    }

    pub(in crate::root_view) fn complete_chat_command(
        &mut self,
        text: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.chat.focused = true;
        if let Some(input) = self.chat_input.clone() {
            input.update(cx, |input, cx| {
                if let Some(range) = crate::composer_context::slash_query_range(&input.content()) {
                    input.set_selected_range(range, cx);
                    input.replace(text, window, cx);
                }
                input.focus(window, cx);
            });
            self.chat.input = crate::composer_context::command_text(&input.read(cx).content());
        }
        self.chat.slash_dismissed = true;
        cx.notify();
    }

    pub(in crate::root_view) fn clear_chat_input(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.chat.input.clear();
        self.chat.pending_agent_call = None;
        if let Some(input) = self.chat_input.clone() {
            input.update(cx, |input, cx| {
                input.set_value("", window, cx);
            });
        }
    }

    pub(in crate::root_view) fn toggle_chat_tool(&mut self, index: usize, cx: &mut Context<Self>) {
        if let Some(entry) = self.chat.session.thread.entries.get_mut(index) {
            entry.toggle_tool();
            cx.notify();
        }
    }

    pub(in crate::root_view) fn toggle_chat_thinking(
        &mut self,
        index: usize,
        cx: &mut Context<Self>,
    ) {
        if let Some(entry) = self.chat.session.thread.entries.get_mut(index) {
            entry.toggle_thinking();
            cx.notify();
        }
    }

    /// 滚到指定用户消息（`Scroll to User Message`）。
    pub(in crate::root_view) fn scroll_chat_to_user(
        &mut self,
        user_index: usize,
        cx: &mut Context<Self>,
    ) {
        self.chat.chat_scroll.scroll_to_top_of_item(user_index);
        cx.notify();
    }

    pub(in crate::root_view) fn scroll_chat_to_bottom(&mut self, cx: &mut Context<Self>) {
        self.chat.chat_scroll.scroll_to_bottom();
        cx.notify();
    }

    pub(in crate::root_view) fn scroll_chat_to_top(&mut self, cx: &mut Context<Self>) {
        self.chat
            .chat_scroll
            .set_offset(gpui_kit::point(px(0.0), px(0.0)));
        cx.notify();
    }

    pub(in crate::root_view) fn handle_slash_keystroke(
        &mut self,
        keystroke: &Keystroke,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.chat.slash_dismissed
            || self
                .chat_input
                .as_ref()
                .is_none_or(|input| !input.read(cx).focus_handle(cx).is_focused(window))
        {
            return false;
        }
        let candidates = slash_candidates(&self.chat.session.commands, &self.chat.input);
        if candidates.is_empty() {
            return false;
        }
        match keystroke.key.as_str() {
            "up" => {
                self.chat.slash_selection = if self.chat.slash_selection == 0 {
                    candidates.len() - 1
                } else {
                    self.chat.slash_selection - 1
                };
                cx.notify();
                true
            }
            "down" => {
                self.chat.slash_selection = (self.chat.slash_selection + 1) % candidates.len();
                cx.notify();
                true
            }
            "enter" | "tab" => {
                let index = self.chat.slash_selection.min(candidates.len() - 1);
                let command_index = candidates[index].command_index;
                let Some(command) = self.chat.session.commands.get(command_index) else {
                    return false;
                };
                let text = format!("/{} ", command.name);
                self.complete_chat_command(text, window, cx);
                self.chat.slash_selection = 0;
                true
            }
            "escape" => {
                self.chat.slash_dismissed = true;
                cx.notify();
                true
            }
            _ => false,
        }
    }

    pub(crate) fn open_context_source(&mut self, id: &str, cx: &mut Context<Self>) {
        let normalized;
        let id = if let Some(value) = id.strip_prefix("cgc-context://") {
            normalized = format!("context:snapshot:{value}");
            normalized.as_str()
        } else {
            id
        };
        let page = if id == crate::composer_context::AUTO_PAGE_TOKEN {
            self.page_context.visible()
        } else {
            self.chat
                .composer_context
                .source(id)
                .or_else(|| {
                    crate::composer_context::source_from_history(&self.chat.session.thread, id)
                })
                .or_else(|| {
                    self.native_agent_view
                        .as_ref()
                        .and_then(|view| view.read(cx).context_source(id))
                })
        };
        if let Some(page) = page {
            self.open_context_page(page, cx);
        }
    }

    pub(in crate::root_view) fn open_context_page(
        &mut self,
        page: crate::page_context::PageContext,
        cx: &mut Context<Self>,
    ) {
        if self.tabs.iter().any(|tab| tab.id == page.tab_id) {
            self.activate_tab(&page.tab_id, cx);
        } else if let Some((course, unit)) = page
            .course
            .as_ref()
            .and_then(|course| course.unit.as_ref().map(|unit| (course, unit)))
        {
            self.open_issue_tab(&course.id, &unit.id, unit.title.clone(), cx);
        } else if matches!(
            self.registry.select(&page.route),
            crate::routing::RouteSelection::Match(_)
        ) {
            self.open_page_tab(&page.route, page.title, cx);
        }
    }

    pub(in crate::root_view) fn add_chat_context(
        &mut self,
        selection: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let token = if selection {
            self.page_context
                .selection()
                .map(|(page, text)| self.chat.composer_context.add_selection(page, text))
        } else {
            self.page_context
                .visible()
                .map(|page| self.chat.composer_context.add_page(page))
        };
        if let (Some(token), Some(input)) = (token, self.chat_input.clone()) {
            input.update(cx, |input, cx| {
                let _ = input.replace_with_token(token, window, cx);
                input.focus(window, cx);
            });
            self.chat.input = crate::composer_context::user_text(&input.read(cx).content());
        }
        cx.notify();
    }

    pub(in crate::root_view) fn edit_chat_message_copy(
        &mut self,
        index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let saved =
            crate::composer_context::draft_for_entry(&self.chat.session.thread, index).cloned();
        let text = self
            .chat
            .session
            .thread
            .entries
            .get(index)
            .and_then(|entry| match entry {
                cgc_agent_ui::conversation::Entry::User { text } => Some(text.clone()),
                _ => None,
            });
        let Some(text) = text else { return };
        let content = match saved {
            Some(draft) => self.chat.composer_context.restore(&draft),
            None => {
                self.chat.composer_context.reset();
                self.chat.composer_context.disable_auto();
                gpui_kit::component::input::InputContent::new(text)
            }
        };
        self.chat.input = crate::composer_context::user_text(&content);
        if let Some(input) = self.chat_input.clone() {
            input.update(cx, |input, cx| {
                input.set_value(content, window, cx);
                input.focus(window, cx);
            });
        }
        cx.notify();
    }

    pub(in crate::root_view) fn send_chat(&mut self, cx: &mut Context<Self>) -> bool {
        if !self.chat.session.can_submit() {
            return false;
        }
        let text = self
            .chat_input
            .as_ref()
            .map(|input| crate::composer_context::user_text(&input.read(cx).content()))
            .unwrap_or_else(|| self.chat.input.trim().to_string());
        if text.is_empty() {
            return false;
        }
        let sent = self.send_chat_text(text, cx);
        if sent {
            self.chat.input.clear();
            self.chat_input_pending_clear = true;
        }
        sent
    }

    pub(in crate::root_view) fn send_chat_text(
        &mut self,
        text: String,
        cx: &mut Context<Self>,
    ) -> bool {
        self.refresh_page_context();
        if !self.chat.session.can_submit() || self.chat.session.session_id.is_none() {
            return false;
        }
        let scope = self.chat.conversation_scope();
        let pending_agent_call = self.chat.pending_agent_call.take();
        let content = self
            .chat_input
            .as_ref()
            .map(|input| input.read(cx).content())
            .filter(|content| crate::composer_context::user_text(content) == text)
            .unwrap_or_else(|| gpui_kit::component::input::InputContent::new(text.clone()));
        let workspace = self
            .native_scope
            .as_ref()
            .map(|scope| scope.root.clone())
            .unwrap_or_else(crate::agent_workspace_root);
        let (draft, prompt, context) = self.chat.composer_context.freeze(
            &content,
            self.page_context.visible(),
            &workspace,
            &self.page_context,
            scope.clone(),
        );
        let mut submission =
            self.chat
                .session
                .submission(draft.text.clone(), prompt, context, Vec::new(), false);
        submission.draft = Some(draft);
        submission.agent_call = pending_agent_call
            .as_ref()
            .map(|pending| pending.call.clone());
        let page_context = self.page_context.clone();
        if !self
            .chat
            .session
            .send_with_context(&mut submission, &page_context, &scope)
        {
            self.chat.pending_agent_call = pending_agent_call;
            return false;
        }
        self.chat.composer_context.reset();
        self.chat.history_open = false;
        cx.notify();
        true
    }

    pub(in crate::root_view) fn send_chat_agent_call(
        &mut self,
        call: crate::agent_call::AgentCall,
        prompt: String,
        cx: &mut Context<Self>,
    ) -> bool {
        self.refresh_page_context();
        if !self.chat.session.can_submit() || self.chat.session.session_id.is_none() {
            return false;
        }
        let scope = self.chat.conversation_scope();
        let display = prompt.clone();
        let page = self.page_context.visible();
        let (prompt, context) = self.page_context.freeze_page(scope.clone(), prompt, page);
        let mut submission =
            self.chat
                .session
                .submission(display, prompt, context, Vec::new(), false);
        submission.agent_call = Some(call);
        let page_context = self.page_context.clone();
        if !self
            .chat
            .session
            .send_with_context(&mut submission, &page_context, &scope)
        {
            return false;
        }
        self.chat.history_open = false;
        cx.notify();
        true
    }

    pub(in crate::root_view) fn stop_chat_turn(&mut self, cx: &mut Context<Self>) {
        self.chat.session.stop();
        cx.notify();
    }

    /// 按 ACP option_id 回传审批（共享权限卡的按钮路径，两轨同一接口）。
    pub(in crate::root_view) fn respond_chat_permission_option(
        &mut self,
        option_id: &str,
        cx: &mut Context<Self>,
    ) {
        self.chat.session.resolve_permission(option_id);
        cx.notify();
    }

    /// 允许/拒绝的折叠路径（键盘快捷键 + QA 自动批准）：优先按 options 里的
    /// allow_*/reject_* 选具体 option，没有匹配选项时回退到旧的二态回传。
    pub(in crate::root_view) fn respond_chat_permission(
        &mut self,
        allow: bool,
        cx: &mut Context<Self>,
    ) {
        let Some(pending) = self.chat.session.thread.pending_permission.clone() else {
            return;
        };
        let option = crate::agent_ingest::first_permission_option(&pending.options, allow)
            .map(|option| option.id.clone());
        if let Some(option_id) = option {
            self.respond_chat_permission_option(&option_id, cx);
            return;
        }
        if let Some(host) = &self.chat.session.host {
            let _ = host.respond_permission(&pending.request_id, allow);
        }
        crate::agent_ingest::apply_permission_resolved(
            &mut self.chat.session.thread,
            pending.request_id,
            allow,
        );
        cx.notify();
    }

    pub(in crate::root_view) fn set_chat_config(
        &mut self,
        index: usize,
        value: String,
        cx: &mut Context<Self>,
    ) {
        let Some(config) = self.chat.session.configs.get(index).cloned() else {
            return;
        };
        if let Some(host) = &self.chat.session.host {
            let _ = host.set_config(config.id.clone(), value.clone());
        }
        let agent_id = self
            .chat
            .selected_agent
            .clone()
            .unwrap_or_else(|| "omp".to_string());
        save_chat_pref(&agent_id, &config.id, &value);
        if let Some(entry) = self.chat.session.configs.get_mut(index) {
            entry.current = value;
        }
        cx.notify();
    }

    pub(in crate::root_view) fn new_chat(&mut self, cx: &mut Context<Self>) {
        self.agent_panel_open = true;
        self.chat.title_override = None;
        self.chat.npx_cache_retry = false;
        self.agent_panel_editing_title = false;
        self.agent_panel_title_original = None;
        self.reset_chat_local(cx);
        self.start_chat(cx);
    }

    /// 打开统一历史侧边栏（native + ACP 本地 transcript；Zed Threads sidebar 形态）。
    pub(in crate::root_view) fn open_chat_history(&mut self, cx: &mut Context<Self>) {
        if let Some(host) = &self.chat.session.host {
            let _ = host.list_sessions();
        }
        self.history_dirty_seen = crate::acp_history::history_dirty_generation();
        self.history_cleared_seen = crate::acp_history::history_cleared_generation();
        self.chat.history = self.load_unified_history();
        self.history_sidebar = Some(crate::root_view::history_sidebar::HistorySidebar::default());
        cx.notify();
    }

    /// 设置窗口清空历史 / 归档等改库后，RootView 在下一帧发现脏标记并重载列表。
    pub(in crate::root_view) fn refresh_history_if_dirty(&mut self, cx: &mut Context<Self>) {
        let generation = crate::acp_history::history_dirty_generation();
        if generation == self.history_dirty_seen {
            return;
        }
        self.history_dirty_seen = generation;
        let root = cx.entity().downgrade();
        cx.defer(move |cx| {
            let _ = root.update(cx, |this, cx| this.apply_history_dirty_refresh(cx));
        });
    }

    pub(in crate::root_view) fn apply_history_dirty_refresh(&mut self, cx: &mut Context<Self>) {
        self.chat.history = self.load_unified_history();
        let cleared = crate::acp_history::history_cleared_generation();
        if cleared != self.history_cleared_seen {
            self.history_cleared_seen = cleared;
            // 清空后当前 ACP 会话的本地记录也被删：回到新会话/空态并提示。
            let transcript_missing =
                self.chat
                    .session
                    .session_id
                    .as_deref()
                    .is_some_and(|session_id| {
                        let thread_id = crate::acp_history::acp_thread_id(session_id);
                        !self
                            .chat
                            .history
                            .iter()
                            .any(|entry| entry.thread_id == thread_id)
                    });
            if transcript_missing
                && (self.chat.opened_from_history || !self.chat.session.thread.entries.is_empty())
            {
                self.pane_notice = Some("ACP 对话历史已清空，已回到新会话".to_string());
                self.new_chat(cx);
            }
        }
        cx.notify();
    }

    /// 恢复 ACP 会话（`session/load` 路径）：先从本地 history 读内容离线渲染。
    pub(in crate::root_view) fn restore_chat_session(
        &mut self,
        session_id: String,
        cx: &mut Context<Self>,
    ) {
        let thread_id = crate::acp_history::acp_thread_id(&session_id);
        self.open_acp_history_thread(thread_id, session_id, cx);
    }

    /// 打开 ACP 历史：先用本地 content 渲染（离线可读），后台尝试 `session/load`；
    /// 成功且 agent 回放 → 用回放替换；失败/无回放 → 降级提示 + 新建会话入口。
    pub(in crate::root_view) fn open_acp_history_thread(
        &mut self,
        thread_id: String,
        session_id: String,
        cx: &mut Context<Self>,
    ) {
        self.dismiss_terminal_for_chat(cx);
        self.agent_panel_editing_title = false;
        self.agent_panel_title_original = None;
        self.reset_chat_local(cx);
        let sidebar = crate::acp_history::load_local_sidebar(&thread_id);
        self.chat.title_override = sidebar
            .as_ref()
            .and_then(|sidebar| sidebar.title_override.clone());
        // 3.3 收尾：历史条目的 agent 与当前选中不一致时同步面板 header 的
        // agent 图标/名称（否则 header 会显示打开前的 agent）。
        if let Some(agent_id) = sidebar
            .as_ref()
            .and_then(|sidebar| sidebar.agent_id.clone())
        {
            if !agent_id.trim().is_empty() && self.chat.selected_agent.as_deref() != Some(&agent_id)
            {
                crate::chat_state::save_selected_agent(&agent_id);
                self.chat.selected_agent = Some(agent_id);
            }
        }
        let local = crate::acp_history::load_local_transcript(&thread_id);
        let has_local_content = local
            .as_ref()
            .is_some_and(|thread| !thread.entries.is_empty());
        if let Some(local) = local {
            self.chat.session.thread = local;
        }
        self.chat.replay = Some(ReplayState {
            thread: ConversationThread::default().with_capabilities(ThreadCapabilities::acp()),
            saw_events: false,
            has_local_content,
        });
        self.chat.opened_from_history = true;
        self.chat.resumed_without_history = false;
        self.chat.restore_id = Some(session_id);
        self.chat.npx_cache_retry = false;
        self.start_chat(cx);
    }

    pub(in crate::root_view) fn install_node_runtime(&mut self, cx: &mut Context<Self>) {
        if matches!(self.chat.session.phase, ConnectionPhase::Starting) {
            return;
        }
        self.chat.session.phase = ConnectionPhase::Starting;
        let task = cx
            .background_executor()
            .spawn(async { NodeRuntimeManager::default_manager().install(&HttpDownloader) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                match result {
                    Ok(()) => {
                        this.chat.guidance = None;
                        this.chat.session.phase = ConnectionPhase::Idle;
                        this.start_chat(cx);
                    }
                    Err(error) => {
                        this.chat.session.phase = ConnectionPhase::Failed(error.to_string());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 等待此前已接受的持久化写入 commit；失败只在日志里留痕，不阻塞退出。
    pub(in crate::root_view) fn flush_store_writer(&mut self) {
        let Some(writer) = &self.store_writer else {
            return;
        };
        if let Err(error) = writer.flush(std::time::Duration::from_millis(1500)) {
            log::warn!(target: "store", "退出前落盘未确认：{error}");
        }
    }

    pub(in crate::root_view) fn reset_chat_local(&mut self, _cx: &mut Context<Self>) {
        self.page_context
            .invalidate_loaded(&self.chat.conversation_scope());
        self.chat.session.disconnect();
        self.chat.composer_context.reset();
        self.chat.pending_agent_call = None;
        self.chat.agent.clear();
        self.chat.version = None;
        self.chat.session.thread =
            ConversationThread::default().with_capabilities(ThreadCapabilities::acp());
        self.chat.input.clear();
        self.chat.focused = false;
        self.chat.auto_prompted = false;
        self.chat.session.configs.clear();
        self.chat.sessions.clear();
        self.chat.opened_from_history = false;
        self.chat.session.session_id = None;
        self.chat.configs_applied = false;
        self.chat.history_open = false;
        self.chat.guidance = None;
        self.chat.load_retry_available = false;
        self.chat.replay = None;
        self.chat.resumed_without_history = false;
        self.chat.acp_save_generation = self.chat.acp_save_generation.wrapping_add(1);
        self.chat.session.commands.clear();
        self.chat.slash_selection = 0;
        self.chat.slash_dismissed = false;
        self.chat_input_pending_clear = true;
    }

    pub(in crate::root_view) fn adopt_course_detail(
        &mut self,
        detail: cgc_courses::catalog::CourseDetail,
    ) {
        self.course_enrollments
            .insert(detail.id.clone(), detail.enrollment_status.clone());
        if self.content.content().is_some_and(|content| {
            content.course_id != detail.id || content.revision_number != detail.revision_number
        }) {
            self.content.reset();
        }
        self.course_detail.adopt(detail);
    }

    pub(in crate::root_view) fn navigate_to_course_detail(
        &mut self,
        course_id: &str,
        cx: &mut Context<Self>,
    ) {
        let public_face = self.current.as_ref().is_some_and(|route_match| {
            matches!(
                route_match.route.id,
                "courses.public_list" | "courses.public_detail"
            )
        });
        let path = match (&self.workspaces.current(), public_face) {
            (Some(workspace), false) => {
                crate::routing::workspace_path(&workspace.slug, &format!("/courses/{course_id}"))
            }
            _ => format!("/courses/{course_id}"),
        };
        let title = self
            .courses
            .items()
            .iter()
            .find(|course| course.id == course_id)
            .map(|course| course.title.clone())
            .unwrap_or_else(|| "课程".to_string());
        self.open_page_tab(&path, title, cx);
    }

    /// 切换 Agent Panel 的 native/ACP 模式：内存态与持久化必须同时落。
    ///
    /// 只写 chat_state 会让内存里的 `native_chat_mode` 保持旧值，面板继续渲染
    /// 旧模式（外部 ACP 会话在后台建出来却看不见）。
    fn set_native_chat_mode(&mut self, enabled: bool) {
        self.native_chat_mode = enabled;
        crate::chat_state::save_native_chat_mode(enabled);
    }

    /// 切到聊天内容时只隐藏终端：进程与输出保留，可从 ＋ 菜单或历史恢复。
    pub(in crate::root_view) fn dismiss_terminal_for_chat(&mut self, cx: &mut Context<Self>) {
        if self.terminal_view.is_some() && self.terminal_visible {
            self.terminal_visible = false;
            self.pending_terminal_open = None;
            cx.notify();
        }
    }

    /// 「+」菜单选择 CGC Agent：在 Agent Panel 内切到 native agent。
    pub fn enter_native_chat(&mut self, cx: &mut Context<Self>) {
        self.dismiss_terminal_for_chat(cx);
        self.set_native_chat_mode(true);
        self.agent_panel_editing_title = false;
        self.agent_panel_title_original = None;
        cx.notify();
    }

    /// 在 Agent Panel 内开启一个新的 native 会话。
    pub fn new_native_chat(&mut self, cx: &mut Context<Self>) {
        self.dismiss_terminal_for_chat(cx);
        self.set_native_chat_mode(true);
        self.agent_panel_editing_title = false;
        self.agent_panel_title_original = None;
        if let Some(view) = &self.native_agent_view {
            view.update(cx, |view, cx| view.start_new_thread(cx));
        }
        cx.notify();
    }

    /// 「+」菜单 → Terminal：已有终端则恢复显示（隐藏不等于销毁）。
    pub fn open_terminal(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.agent_panel_editing_title = false;
        if self.terminal_view.is_some() {
            self.terminal_visible = true;
            self.pending_terminal_open = None;
            cx.notify();
            return;
        }
        let cwd = self.default_terminal_cwd();
        self.spawn_terminal(cwd, window, cx);
    }

    /// 从历史侧栏打开终端：同目录直接恢复；不同目录需二次点击才替换。
    pub(in crate::root_view) fn open_terminal_at(
        &mut self,
        cwd: std::path::PathBuf,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.agent_panel_editing_title = false;
        if self.terminal_view.is_some() {
            if terminal_matches_directory(self.terminal_cwd.as_deref(), &cwd) {
                // 同一目录：复用现有实例（隐藏中的也直接恢复）。
                self.terminal_visible = true;
                self.pending_terminal_open = None;
                cx.notify();
                return;
            }
            if self.pending_terminal_open.as_ref() == Some(&cwd) {
                self.pending_terminal_open = None;
                self.close_terminal(cx);
                self.spawn_terminal(Some(cwd), window, cx);
            } else {
                self.pending_terminal_open = Some(cwd);
                self.pane_notice = Some("已有终端在运行：再点一次历史记录替换".to_string());
                cx.notify();
            }
            return;
        }
        self.spawn_terminal(Some(cwd), window, cx);
    }

    /// 新终端的工作目录：上次关闭时的目录 → agent 工作区 → home（方案 A）。
    /// 上次的目录可能已被删除；agent 工作区首次使用可能还不存在，
    /// 所以先补建目录，建不出来就退回下一级。
    fn default_terminal_cwd(&self) -> Option<std::path::PathBuf> {
        let last = self.last_terminal_cwd.clone().filter(|path| path.is_dir());
        let scope_root = self.native_scope.as_ref().map(|scope| scope.root.clone());
        let home = home_dir();
        terminal_cwd(last.as_deref(), scope_root.as_deref(), home.as_deref())
            .map(std::path::Path::to_path_buf)
            .filter(|dir| match std::fs::create_dir_all(dir) {
                Ok(()) => true,
                Err(error) => {
                    log::warn!(
                        target: "terminal",
                        "无法创建工作目录 {}：{error}",
                        dir.display()
                    );
                    false
                }
            })
    }

    fn spawn_terminal(
        &mut self,
        cwd: Option<std::path::PathBuf>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let size = cgc_terminal::GridSize { cols: 80, rows: 24 };
        let mut session = match cgc_terminal::Session::spawn_default_in(size, cwd.as_deref()) {
            Ok(session) => session,
            Err(error) => {
                self.pane_notice = Some(format!("无法启动终端：{error}"));
                cx.notify();
                return;
            }
        };
        if let Err(error) = session.set_theme(&theme::terminal_theme(&self.theme_name, cx)) {
            log::warn!(target: "terminal", "应用终端配色失败：{error}");
        }

        let style = theme::terminal_style(cx);

        let key_input = match cgc_terminal::KeyInput::new() {
            Ok(key_input) => key_input,
            Err(error) => {
                self.pane_notice = Some(format!("无法初始化终端输入：{error}"));
                cx.notify();
                return;
            }
        };
        let view = cx
            .new(|cx| cgc_terminal_view::TerminalView::new(session, style, key_input, window, cx));
        view.update(cx, |view, cx| view.poll(cx));
        view.update(cx, |view, cx| view.focus(window, cx));
        self.terminal_view = Some(view.clone());

        // 会话日志：open 时插入一行，close 时回填标题/退出码（低频写库）。
        let session_id = next_terminal_session_id();
        let record = cgc_agent_store::TerminalSession {
            terminal_id: session_id.clone(),
            title: cwd
                .as_deref()
                .and_then(std::path::Path::file_name)
                .map(|name| name.to_string_lossy().into_owned()),
            custom_title: None,
            working_directory: cwd.as_ref().map(|dir| dir.display().to_string()),
            created_at: cgc_agent_store::now_utc_rfc3339(),
            closed_at: None,
            exit_code: None,
        };
        if let Err(error) = crate::acp_history::open_conversation_store()
            .and_then(|store| store.upsert_terminal_session(&record))
        {
            log::warn!(target: "terminal", "记录终端会话失败：{error}");
        }
        self.terminal_session_id = Some(session_id);
        self.terminal_visible = true;
        self.terminal_cwd = cwd.clone();
        self.pending_terminal_open = None;
        self.chat.history = self.load_unified_history();
        cx.notify();

        // 33ms 轮询 PTY；视图析构后 `update` 失败，循环自然退出。
        let weak = view.downgrade();
        cx.spawn(async move |_root, cx| loop {
            cx.background_executor()
                .timer(std::time::Duration::from_millis(33))
                .await;
            if weak.update(cx, |view, cx| view.poll(cx)).is_err() {
                break;
            }
        })
        .detach();
    }

    /// 关闭终端并回到对话视图；记住当前目录、回填会话日志。
    pub fn close_terminal(&mut self, cx: &mut Context<Self>) {
        if let Some(view) = self.terminal_view.take() {
            let (cwd, title, exit_code) = {
                let view = view.read(cx);
                let title = view.title().trim().to_string();
                (
                    view.cwd().map(std::path::PathBuf::from),
                    (!title.is_empty()).then_some(title),
                    view.exit_code(),
                )
            };
            self.last_terminal_cwd = cwd;
            if let Some(session_id) = self.terminal_session_id.take() {
                let closed_at = cgc_agent_store::now_utc_rfc3339();
                if let Err(error) =
                    crate::acp_history::open_conversation_store().and_then(|store| {
                        store.finish_terminal_session(
                            &session_id,
                            title.as_deref(),
                            &closed_at,
                            exit_code.map(i64::from),
                        )
                    })
                {
                    log::warn!(target: "terminal", "回填终端会话失败：{error}");
                }
            }
        }
        self.pending_terminal_open = None;
        self.terminal_visible = false;
        self.terminal_cwd = None;
        self.chat.history = self.load_unified_history();
        cx.notify();
    }

    /// 应用主题变化后，把新配色同步给已打开的终端（历史输出一起换色）。
    pub(in crate::root_view) fn sync_terminal_theme(&mut self, cx: &mut Context<Self>) {
        let Some(view) = self.terminal_view.clone() else {
            return;
        };
        let style = theme::terminal_style(cx);
        let colors = theme::terminal_theme(&self.theme_name, cx);
        match view.update(cx, |view, cx| view.apply_theme(style, &colors, cx)) {
            Ok(()) => {}
            Err(error) => log::warn!(target: "terminal", "同步终端配色失败：{error}"),
        }
    }

    /// 执行 native agent 投递的应用内动作（AppAction）。
    pub fn apply_native_agent_action(
        &mut self,
        action: cgc_agent_tools::AppAction,
        workspace: std::path::PathBuf,
        cx: &mut Context<Self>,
    ) {
        match action {
            cgc_agent_tools::AppAction::OpenPage { route } => {
                self.navigate(&route);
                self.native_agent_highlight = None;
            }
            cgc_agent_tools::AppAction::HighlightRange {
                path,
                start_line,
                end_line,
            } => {
                let mut preview = Vec::new();
                let mut error = None;
                match std::fs::read_to_string(workspace.join(&path)) {
                    Ok(text) => {
                        let lines: Vec<&str> = text.lines().collect();
                        let window_start = start_line.saturating_sub(4).max(1) as usize;
                        let window_end = (end_line as usize + 4).min(lines.len());
                        for line_number in window_start..=window_end {
                            if let Some(line) = lines.get(line_number - 1) {
                                preview.push((line_number as u32, line.to_string()));
                            }
                        }
                    }
                    Err(read_error) => error = Some(read_error.to_string()),
                }
                self.native_agent_highlight = Some(state::NativeAgentHighlight {
                    path,
                    start_line,
                    end_line,
                    workspace,
                    preview,
                    error,
                });
            }
        }
        cx.notify();
    }

    pub fn clear_native_agent_highlight(&mut self, cx: &mut Context<Self>) {
        self.native_agent_highlight = None;
        cx.notify();
    }

    /// native agent 是否对当前用户开放（3.5b：两轨默认 native，课程页同开）。
    ///
    /// 覆盖顺序：
    ///
    /// 1. `CGC_NATIVE_AGENT`（显式 env，`0` = 关闭）
    /// 2. `preferences.nativeAgentEnabled`（设置开关，默认开；关闭后用 External Agent）
    pub fn native_agent_enabled() -> bool {
        let env_native_agent = std::env::var("CGC_NATIVE_AGENT").ok();
        let pref = crate::preferences::load().native_agent_enabled;
        Self::resolve_native_agent_enabled(env_native_agent.as_deref(), pref)
    }

    /// 3.5b：默认 native 的纯决策函数（env/prefs 覆盖 + 页面默认）。
    ///
    /// 规则：
    ///
    /// 1. `CGC_NATIVE_AGENT` 显式设置时，`"0"` 关闭、其余值开启；
    /// 2. 否则 `preferences.nativeAgentEnabled`（默认开；关闭 = 用 External Agent）。
    pub(crate) fn resolve_native_agent_enabled(env_native_agent: Option<&str>, pref: bool) -> bool {
        match env_native_agent {
            Some(value) => value != "0",
            None => pref,
        }
    }

    pub fn open_settings_window(&mut self, cx: &mut Context<Self>) {
        self.open_settings_window_inner(false, cx);
    }

    /// 从 Agent Panel 的未配置空态直接打开 Settings → AI → LLM Providers。
    pub(crate) fn open_settings_ai_window(&mut self, cx: &mut Context<Self>) {
        self.open_settings_window_inner(true, cx);
    }

    fn open_settings_window_inner(&mut self, open_llm_providers: bool, cx: &mut Context<Self>) {
        if let Some((existing, view)) = cx.windows().into_iter().find_map(|window| {
            let root = window.downcast::<gpui_kit::base::Root>()?;
            let view = root
                .read(cx)
                .ok()?
                .view()
                .clone()
                .downcast::<SettingsWindowView>()
                .ok()?;
            Some((window, view))
        }) {
            let _ = existing.update(cx, |_, window, cx| {
                if open_llm_providers {
                    view.update(cx, |view, cx| view.open_llm_providers(cx));
                }
                window.activate_window();
            });
            return;
        }
        let Some(signed_in) = self.session.signed_in().cloned() else {
            return;
        };
        let language = self.language;
        let email = signed_in.email.clone();
        let user_id = signed_in.user_id.clone();
        let token = signed_in.token.clone();
        let workspace = self
            .workspaces
            .current()
            .map(|workspace| workspace.name.clone());
        let api = self.session.api_handle();
        let title = translate(language, Key::AppSettingsTitle);
        let bounds = WindowBounds::centered(
            Size {
                width: px(620.0),
                height: px(560.0),
            },
            cx,
        );
        let options = WindowOptions {
            titlebar: Some(TitlebarOptions {
                title: Some(title.into()),
                traffic_light_position: Some(point(px(TRAFFIC_LIGHT_X), px(TRAFFIC_LIGHT_Y))),
                ..TitleBar::title_bar_options()
            }),
            focus: true,
            show: true,
            is_movable: true,
            window_decorations: Some(WindowDecorations::Client),
            window_min_size: Some(Size {
                width: px(480.0),
                height: px(360.0),
            }),
            window_bounds: Some(bounds),
            ..TitleBar::window_options()
        };
        let native_runtime = self.native_runtime.clone();
        let root = cx.entity().downgrade();
        gpui_kit::open_window(options, cx, move |window, cx| {
            let view = cx.new(|cx| {
                SettingsWindowView::new(
                    language,
                    email,
                    user_id,
                    workspace,
                    token,
                    api,
                    self.close_to_tray.clone(),
                    native_runtime,
                    root,
                    cx,
                )
            });
            if open_llm_providers {
                view.update(cx, |view, cx| view.open_llm_providers(cx));
            }
            let focus = view.read(cx).focus_handle();
            window.focus(&focus, cx);
            view
        })
        .ok();
    }

    pub(in crate::root_view) fn breadcrumb_context(
        &self,
    ) -> Option<(&'static str, Option<String>)> {
        let route_id = self
            .current
            .as_ref()
            .map(|route_match| route_match.route.id)?;
        match route_id {
            "account.workspace" => Some(("account.workspace.overview", None)),
            "events.list" => Some(("events.list.title", None)),
            "events.participations" => Some(("events.participations.title", None)),
            "events.detail" => Some((
                "events.list.title",
                self.detail.detail().map(|detail| detail.title.clone()),
            )),
            "events.public_list" => Some(("events.public.title", None)),
            "events.public_detail" => Some((
                "events.public.title",
                self.detail.detail().map(|detail| detail.title.clone()),
            )),
            "courses.catalog" | "courses.learning_home" => Some(("courses.catalog.title", None)),
            "courses.public_learning" => Some((
                "courses.public.title",
                self.course_detail
                    .detail()
                    .map(|detail| detail.title.clone()),
            )),
            "courses.public_list" => Some(("courses.public.title", None)),
            "courses.public_detail" => Some((
                "courses.public.title",
                self.course_detail
                    .detail()
                    .map(|detail| detail.title.clone()),
            )),
            "courses.detail" | "courses.learning" => Some((
                "courses.catalog.title",
                self.course_detail
                    .detail()
                    .map(|detail| detail.title.clone()),
            )),
            _ => None,
        }
    }

    pub(in crate::root_view) fn render_breadcrumb_bar(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let palette = *palette;
        let workspace_switcher = self.render_workspace_switcher(language, &palette, cx);
        let context = self.breadcrumb_context();
        let section_label = match context {
            Some((label_key, _)) => translate_registered(language, label_key),
            None => translate(language, Key::AppBreadcrumbSections),
        };
        // 只显示位置；导航职责归 Site Tree。
        let section = div().child(section_label);
        let mut bar = div()
            .flex()
            .flex_row()
            .items_center()
            .gap(px(4.0))
            .text_size(px(12.0))
            .text_color(palette.ink_3)
            .child(workspace_switcher)
            .child(div().child("›"))
            .child(section);
        if let Some((_, Some(title))) = context {
            bar = bar.child(div().child("›")).child(div().child(title));
        }
        bar.into_any_element()
    }

    pub(in crate::root_view) fn toggle_agent_panel(&mut self, cx: &mut Context<Self>) {
        self.agent_panel_open = !self.agent_panel_open;
        self.workspace_layout_overridden = true;
        if self.agent_panel_open
            && !self.native_chat_mode
            && matches!(self.chat.session.phase, ConnectionPhase::Idle)
        {
            self.start_chat(cx);
        }
        self.persist_current_workspace_state();
        cx.notify();
    }

    /// 套用 Panels 默认值：只改面板布局，不碰标签与站点树等导航记忆。
    ///
    /// 新工作台与设置页「重置当前工作台布局」共用。重置回到「无覆盖」语义，
    /// 与 Zed 的 `PanelSizeState::default()` 同构：不把当前像素写死成新的默认。
    pub(in crate::root_view) fn apply_panel_defaults(
        &mut self,
        preferences: &crate::preferences::Preferences,
    ) {
        self.agent_panel_open = true;
        self.right_panel_open = preferences.dock_starts_open;
        self.right_panel = RightPanel::SiteTree;
        self.panel_memory = state::PanelMemory {
            panel: RightPanel::SiteTree,
            open: preferences.dock_starts_open,
        };
        self.right_panel_width = preferences.dock_width as f32;
        self.agent_panel_width = preferences.agent_panel_width as f32;
        self.agent_panel_side = preferences.agent_panel_side;
        self.dock_side = preferences.dock_side;
        self.display_preferences = preferences.clone();
        self.workspace_layout_overridden = false;
        self.resize_drag = None;
    }

    /// 设置页动作：当前工作台的布局恢复为 Panels 默认值，保留已打开的标签。
    ///
    /// 只重置布局字段；标签、当前标签、站点树展开/搜索/滚动属于导航记忆，
    /// 与 Zed 的 `ResetActiveDockSize` 一样不动。没有当前工作台时返回 `false`，
    /// 由调用方提示先选工作台。
    pub(crate) fn reset_workspace_layout(&mut self, cx: &mut Context<Self>) -> bool {
        let Some(workspace_id) = self.workspaces.current_id().map(str::to_string) else {
            return false;
        };
        self.apply_panel_defaults(&crate::preferences::load());
        self.persist_workspace_state(&workspace_id);
        cx.notify();
        true
    }

    pub(in crate::root_view) fn toggle_site_tree_course(
        &mut self,
        course_id: &str,
        cx: &mut Context<Self>,
    ) {
        if self.site_tree_course_open.as_deref() == Some(course_id) {
            self.site_tree_course_open = None;
        } else {
            self.site_tree_course_open = Some(course_id.to_string());
            self.ensure_navigation_data(cx);
            self.load_expanded_site_tree_course(cx);
        }
        cx.notify();
    }

    pub(in crate::root_view) fn toggle_site_tree_section(
        &mut self,
        section: SiteTreeSection,
        cx: &mut Context<Self>,
    ) {
        match section {
            SiteTreeSection::Events => {
                self.site_tree_events_open = !self.site_tree_events_open;
                if self.site_tree_events_open {
                    self.ensure_navigation_data(cx);
                }
            }
            SiteTreeSection::Courses => {
                self.site_tree_courses_open = !self.site_tree_courses_open;
                if self.site_tree_courses_open {
                    self.ensure_navigation_data(cx);
                    self.load_course_enrollments(cx);
                }
            }
        }
        self.persist_current_workspace_state();
        cx.notify();
    }

    /// 打开指定右栏 panel；已打开且是同一个 panel 时收起（Zed 图标语义）。
    pub(in crate::root_view) fn toggle_right_panel(
        &mut self,
        panel: RightPanel,
        cx: &mut Context<Self>,
    ) {
        let (panel, open) =
            state::toggled_right_panel(self.right_panel, self.right_panel_open, panel);
        self.right_panel = panel;
        self.right_panel_open = open;
        if open && panel == RightPanel::SiteTree {
            self.ensure_navigation_data(cx);
        }
        // 通知面板是临时入口，不写入记忆。
        if !matches!(panel, RightPanel::Notifications) {
            self.workspace_layout_overridden = true;
            self.panel_memory = state::PanelMemory { panel, open };
            self.persist_current_workspace_state();
        }
        cx.notify();
    }

    /// 刷新显示偏好快照与停靠侧；不动当前窗口宽度。
    pub(crate) fn apply_display_snapshot(&mut self, cx: &mut Context<Self>) {
        let preferences = crate::preferences::load();
        self.agent_panel_side = preferences.agent_panel_side;
        self.dock_side = preferences.dock_side;
        if !self.workspace_layout_overridden
            && preferences.dock_starts_open != self.display_preferences.dock_starts_open
        {
            self.panel_memory.open = preferences.dock_starts_open;
            if self.right_panel != RightPanel::Notifications {
                self.right_panel_open = preferences.dock_starts_open;
            }
        }
        self.display_preferences = preferences;
        cx.notify();
    }

    /// 无布局覆盖时应用默认宽度；导航记录不影响继承 Panels 偏好。
    pub(crate) fn apply_default_panel_widths(&mut self, cx: &mut Context<Self>) {
        if self.workspaces.current_id().is_none() || self.workspace_layout_overridden {
            return;
        }
        let preferences = crate::preferences::load();
        self.agent_panel_width = preferences.agent_panel_width as f32;
        self.right_panel_width = preferences.dock_width as f32;
        cx.notify();
    }

    /// 右键菜单 Dock Left / Dock Right：只改停靠侧，不动宽度。
    pub(crate) fn set_agent_panel_side(
        &mut self,
        side: crate::preferences::PanelSide,
        cx: &mut Context<Self>,
    ) {
        if self.agent_panel_side == side {
            return;
        }
        self.agent_panel_side = side;
        self.display_preferences.agent_panel_side = side;
        crate::preferences::update(|preferences| preferences.agent_panel_side = side);
        cx.notify();
    }

    pub(crate) fn set_dock_side(
        &mut self,
        side: crate::preferences::PanelSide,
        cx: &mut Context<Self>,
    ) {
        if self.dock_side == side {
            return;
        }
        self.dock_side = side;
        self.display_preferences.dock_side = side;
        crate::preferences::update(|preferences| preferences.dock_side = side);
        cx.notify();
    }

    /// 右键菜单 Hide Button：隐藏对应状态栏按钮。
    pub(in crate::root_view) fn hide_status_bar_button(
        &mut self,
        button: state::StatusBarButton,
        cx: &mut Context<Self>,
    ) {
        match button {
            state::StatusBarButton::History => {
                self.display_preferences.status_bar_history_button = false;
            }
            state::StatusBarButton::Agent => {
                self.display_preferences.agent_panel_button = false;
            }
            state::StatusBarButton::Navigation => {
                self.display_preferences.dock_navigation_button = false;
            }
            state::StatusBarButton::Outline => {
                self.display_preferences.dock_outline_button = false;
            }
        }
        crate::preferences::update(|preferences| match button {
            state::StatusBarButton::History => preferences.status_bar_history_button = false,
            state::StatusBarButton::Agent => preferences.agent_panel_button = false,
            state::StatusBarButton::Navigation => preferences.dock_navigation_button = false,
            state::StatusBarButton::Outline => preferences.dock_outline_button = false,
        });
        cx.notify();
    }

    pub(in crate::root_view) fn select_events_filter(
        &mut self,
        filter: StatusFilter,
        cx: &mut Context<Self>,
    ) {
        self.events.set_filter(filter);
        self.events.retry_ready();
        self.start_events_load(cx, true);
    }

    pub(in crate::root_view) fn retry_events(&mut self, cx: &mut Context<Self>) {
        self.events.retry_ready();
        self.start_events_load(cx, true);
    }

    pub(in crate::root_view) fn open_agent_registry(&mut self, cx: &mut Context<Self>) {
        let title = translate(self.language, Key::AgentRegistryTitle).to_string();
        self.open_page_tab("/agents", title, cx);
        if !self.agent_registry_started {
            self.start_agent_registry_load(cx);
        }
    }

    pub(in crate::root_view) fn set_agent_registry_filter(
        &mut self,
        filter: AgentRegistryFilter,
        cx: &mut Context<Self>,
    ) {
        self.agent_registry_filter = filter;
        cx.notify();
    }

    pub(in crate::root_view) fn start_agent_registry_load(&mut self, cx: &mut Context<Self>) {
        if self.agent_registry_loading {
            return;
        }
        self.agent_registry_started = true;
        self.agent_registry_loading = true;
        self.agent_registry_error = None;
        let task = cx.background_executor().spawn(async move {
            let registry = Registry::builtin().map_err(|error| error.diagnostic())?;
            let managed = NodeRuntime::new(NodeRuntimeManager::default_manager().root);
            let rows = detect_all(&registry, Some(&managed));
            Ok::<_, String>(rows)
        });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.agent_registry_loading = false;
                match result {
                    Ok(rows) => this.agent_registry_rows = rows,
                    Err(error) => this.agent_registry_error = Some(error),
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn install_agent(&mut self, id: &str, cx: &mut Context<Self>) {
        if self.agent_installing.as_deref() == Some(id) {
            return;
        }
        let Some(entry) = self
            .agent_registry_rows
            .iter()
            .find(|row| row.entry.id == id)
            .map(|row| row.entry.clone())
        else {
            return;
        };
        self.agent_installing = Some(id.to_string());
        self.agent_install_stage = Some("准备运行环境".to_string());
        self.agent_install_error = None;
        let installed_id = id.to_string();
        let installed_version = entry.minimum_version.clone();
        let is_npx = matches!(
            entry.distribution,
            cgc_platform::registry::manifest::Distribution::Npx { .. }
        );
        let task = cx.background_executor().spawn(async move {
            let manager = NodeRuntimeManager::default_manager();
            let mut node = manager.installed_runtime();
            if node.is_none() && is_npx {
                manager
                    .install(&HttpDownloader)
                    .map_err(|error| error.to_string())?;
                node = manager.installed_runtime();
            }
            install_entry(&entry, node.as_ref()).map_err(|error| error.to_string())
        });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.agent_installing = None;
                this.agent_install_stage = None;
                match result {
                    Ok(result) => {
                        this.agent_install_error = None;
                        if let Some(row) = this
                            .agent_registry_rows
                            .iter_mut()
                            .find(|row| row.entry.id == installed_id)
                        {
                            row.status = AgentStatus::Ready {
                                version: result
                                    .version
                                    .clone()
                                    .unwrap_or_else(|| installed_version.clone()),
                            };
                        }
                    }
                    Err(error) => this.agent_install_error = Some(error.to_string()),
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 切到 external ACP agent 前的面板状态重置（不含 host 生命周期与启动）。
    ///
    /// 必须把面板切回 ACP 视图：只写 chat_state 会让 Agent Panel 继续渲染
    /// native 视图，ACP 会话在后台建出来却看不见。
    pub(in crate::root_view) fn reset_chat_for_external_agent(
        &mut self,
        id: &str,
        display_name: &str,
    ) {
        self.site_tree_search_focused = false;
        save_selected_agent(id);
        self.chat.selected_agent = Some(id.to_string());
        self.chat.agent = display_name.to_string();
        self.set_native_chat_mode(false);
        self.chat.session.phase = ConnectionPhase::Idle;
        self.chat.session.host.take();
        self.chat.session.thread =
            ConversationThread::default().with_capabilities(ThreadCapabilities::acp());
        self.chat.session.session_id = None;
        self.chat.restore_id = None;
        self.chat.title_override = None;
        self.chat.npx_cache_retry = false;
        self.agent_panel_editing_title = false;
        self.agent_panel_title_original = None;
        self.chat.session.configs.clear();
        self.chat.session.commands.clear();
        self.chat.pending_agent_call = None;
        self.chat.composer_context.reset();
        self.chat.configs_applied = false;
        self.chat.auto_prompted = false;
    }

    pub(in crate::root_view) fn select_chat_agent(
        &mut self,
        id: String,
        display_name: String,
        cx: &mut Context<Self>,
    ) {
        self.dismiss_terminal_for_chat(cx);
        self.reset_chat_for_external_agent(&id, &display_name);
        self.start_chat(cx);
    }

    /// 发消息时给 agent 的当前卡上下文（用户移除芯片后不再注入）。
    pub(in crate::root_view) fn is_stale_session_error(message: &str) -> bool {
        message.contains("session/load") || message.contains("no rollout found")
    }

    pub(in crate::root_view) fn should_retry_stale_session(
        load_retry_available: bool,
        message: &str,
    ) -> bool {
        load_retry_available && Self::is_stale_session_error(message)
    }

    pub(in crate::root_view) fn ensure_key_focus(&mut self, cx: &mut Context<Self>) -> FocusHandle {
        self.key_focus
            .get_or_insert_with(|| cx.focus_handle())
            .clone()
    }

    pub(in crate::root_view) fn submit_login(&mut self, cx: &mut Context<Self>) {
        if self.signing_in {
            return;
        }
        let login = self.login_email.trim().to_string();
        let password = self.login_password.clone();
        if login.is_empty() || password.is_empty() {
            self.login_error = Some(LoginError::Invalid);
            cx.notify();
            return;
        }
        // 客户端只保留「邮箱 + 密码」这一条密码登录（扫码注册走小程序）：
        // 手机号登录已下线，别把手机号交给后端的手机号分支。
        if !looks_like_email(&login) {
            self.login_error = Some(LoginError::EmailRequired);
            cx.notify();
            return;
        }

        self.signing_in = true;
        self.login_error = None;
        self.session.begin_sign_in();
        cx.notify();

        let api = self.session.api_handle();
        let task = cx
            .background_executor()
            .spawn(async move { api.sign_in(&login, &password) });

        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.finish_login(result);
                this.prepare_agent_authorization(cx);
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn finish_login(
        &mut self,
        result: Result<SignedInSession, AuthError>,
    ) {
        self.signing_in = false;
        match result {
            Ok(session) => {
                // 账号切换（含重新登录）后，上一账号在途的详情/列表响应必须作废。
                self.session_epoch = self.session_epoch.wrapping_add(1);
                if self.session.adopt_signed_in(session).is_err() {
                    self.login_error = Some(LoginError::Network);
                }
                self.reset_events();
                self.workspaces.reset();
                self.workspaces_started = false;
                self.session_checked = false;
                self.login_password.clear();
                self.navigate("/");
                self.consume_pending_link();
            }
            Err(error) => {
                self.session.fail_sign_in(&error);
                self.login_error = Some(LoginError::from_auth_error(&error));
            }
        }
    }

    pub(in crate::root_view) fn sign_out(&mut self, cx: &mut Context<Self>) {
        self.session_epoch = self.session_epoch.wrapping_add(1);
        self.revoke_agent_authorization(cx);
        if let Some(runtime) = &self.native_runtime {
            runtime.stop();
        }
        let token = self.session.sign_out_local();
        if let Some(token) = token {
            let api = self.session.api_handle();
            let authorization = self.agent_authorization_tail.clone();
            cx.background_executor()
                .spawn(async move {
                    super::agent_session::after_authorization(authorization, || {
                        let _ = api.revoke(&token);
                    })
                    .await;
                })
                .detach();
        }
        self.workspaces.reset();
        self.workspaces_started = false;
        self.reset_workspace_data(cx);
        self.prepare_agent_authorization(cx);
        self.login_email.clear();
        self.login_password.clear();
        self.login_error = None;
        self.switch_login_mode(LoginMode::Password);
        self.ensure_wechat_login(cx);
        cx.notify();
    }

    pub(in crate::root_view) fn handle_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // 登录页是自绘输入框，没有 InputState 的剪贴板处理；显式支持
        // Cmd/Ctrl+V，否则从密码管理器复制的邮箱/密码只能手工重敲。
        if (event.keystroke.modifiers.platform || event.keystroke.modifiers.control)
            && event.keystroke.key.eq_ignore_ascii_case("v")
        {
            let pasted = cx.read_from_clipboard().and_then(|item| {
                item.entries.into_iter().find_map(|entry| match entry {
                    gpui_kit::ClipboardEntry::String(text) => {
                        super::screens::sanitize_login_paste(&text.text)
                    }
                    _ => None,
                })
            });
            if let Some(text) = pasted {
                self.field_mut().push_str(&text);
            }
            let focus = self.ensure_key_focus(cx);
            window.focus(&focus, cx);
            cx.notify();
            return;
        }
        match event.keystroke.key.as_str() {
            "tab" => self.cycle_login_field(),
            "enter" => match self.login_mode {
                LoginMode::Password => self.submit_login(cx),
                LoginMode::Reset => {
                    if self.reset_sent {
                        self.submit_reset_password(cx)
                    } else {
                        self.request_password_reset(cx)
                    }
                }
            },
            "backspace" => {
                let buffer = self.field_mut();
                buffer.pop();
            }
            _ => {
                if let Some(text) = event.keystroke.key_char.as_deref() {
                    if !event.keystroke.modifiers.modified() && !text.is_empty() {
                        self.field_mut().push_str(text);
                    }
                }
            }
        }
        let focus = self.ensure_key_focus(cx);
        window.focus(&focus, cx);
        cx.notify();
    }

    pub(in crate::root_view) fn field_mut(&mut self) -> &mut String {
        match self.focused {
            LoginField::Email => &mut self.login_email,
            LoginField::Password => &mut self.login_password,
            LoginField::ResetToken => &mut self.login_reset_token,
            LoginField::NewPassword => &mut self.login_new_password,
        }
    }

    pub(in crate::root_view) fn login_fields(&self) -> Vec<LoginField> {
        match self.login_mode {
            LoginMode::Password => vec![LoginField::Email, LoginField::Password],
            LoginMode::Reset => {
                if self.reset_sent {
                    vec![LoginField::ResetToken, LoginField::NewPassword]
                } else {
                    vec![LoginField::Email]
                }
            }
        }
    }

    pub(in crate::root_view) fn cycle_login_field(&mut self) {
        let fields = self.login_fields();
        let index = fields
            .iter()
            .position(|field| *field == self.focused)
            .unwrap_or(0);
        self.focused = fields[(index + 1) % fields.len()];
    }

    pub(in crate::root_view) fn switch_login_mode(&mut self, mode: LoginMode) {
        self.login_mode = mode;
        self.login_error = None;
        self.login_notice = None;
        self.reset_sent = false;
        // 离开 Password 视图即停止轮询与倒计时；切回时由 render 重新出码。
        self.wechat_generation += 1;
        self.wechat_login = WechatLoginView::Idle;
        self.focused = match mode {
            LoginMode::Password => LoginField::Email,
            LoginMode::Reset => LoginField::Email,
        };
    }

    /// 自动出码条件：密码登录视图且当前没有进行中的扫码。
    pub(in crate::root_view) fn should_auto_start_wechat(&self) -> bool {
        self.login_mode == LoginMode::Password && matches!(self.wechat_login, WechatLoginView::Idle)
    }

    /// 登录视图（Password）挂载时调用；fake 模式下不自动出码。
    pub fn ensure_wechat_login(&mut self, cx: &mut Context<Self>) {
        if self.should_auto_start_wechat() {
            self.start_wechat_login(cx);
        }
    }

    pub(in crate::root_view) fn back_to_password_login(&mut self, cx: &mut Context<Self>) {
        self.switch_login_mode(LoginMode::Password);
        self.ensure_wechat_login(cx);
        cx.notify();
    }

    pub(in crate::root_view) fn start_wechat_login(&mut self, cx: &mut Context<Self>) {
        if self.signing_in {
            return;
        }
        self.wechat_generation += 1;
        let generation = self.wechat_generation;
        self.wechat_login = WechatLoginView::Starting;
        self.login_error = None;
        let api = self.session.api_handle();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move { api.start_wechat_login() })
                .await;
            let _ = this.update(cx, |this, cx| {
                if generation != this.wechat_generation {
                    return;
                }
                match result {
                    Ok(start) => match start.launch_url {
                        Some(launch_url) => {
                            let expires_at = start.expires_at.clone();
                            let remaining_seconds = remaining_seconds(expires_at.as_deref());
                            this.wechat_login = WechatLoginView::Ready {
                                launch_url,
                                approved: false,
                                expires_at,
                                remaining_seconds,
                            };
                            this.spawn_wechat_poller(
                                cx,
                                generation,
                                start.request_id,
                                start.proof,
                                start.poll_interval_seconds,
                            );
                            this.spawn_wechat_countdown(cx, generation);
                        }
                        None => {
                            this.wechat_login = WechatLoginView::Failed(LoginError::Wechat);
                        }
                    },
                    Err(error) => {
                        this.wechat_login =
                            WechatLoginView::Failed(LoginError::from_auth_error(&error));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn spawn_wechat_poller(
        &mut self,
        cx: &mut Context<Self>,
        generation: u64,
        request_id: String,
        proof: String,
        interval_seconds: i64,
    ) {
        let api = self.session.api_handle();
        let interval = Duration::from_secs(interval_seconds.clamp(1, 10) as u64);
        cx.spawn(async move |this, cx| loop {
            cx.background_executor().timer(interval).await;
            let poll_api = api.clone();
            let poll_request = request_id.clone();
            let poll_proof = proof.clone();
            let result = cx
                .background_executor()
                .spawn(async move { poll_api.wechat_login_status(&poll_request, &poll_proof) })
                .await;
            let next_request = request_id.clone();
            let next_proof = proof.clone();
            let keep = this
                .update(cx, |this, cx| {
                    if generation != this.wechat_generation
                        || this.login_mode != LoginMode::Password
                    {
                        return false;
                    }
                    match result {
                        Ok(poll) => match poll.status {
                            WechatLoginStatus::Pending => true,
                            WechatLoginStatus::Approved => {
                                this.consume_wechat_login(cx, generation, next_request, next_proof);
                                false
                            }
                            WechatLoginStatus::Consumed => false,
                            WechatLoginStatus::Cancelled | WechatLoginStatus::Expired => {
                                this.wechat_login = WechatLoginView::Expired;
                                cx.notify();
                                false
                            }
                        },
                        Err(error) => {
                            this.wechat_login =
                                WechatLoginView::Failed(LoginError::from_auth_error(&error));
                            cx.notify();
                            false
                        }
                    }
                })
                .unwrap_or(false);
            if !keep {
                break;
            }
        })
        .detach();
    }

    /// 每秒刷新二维码剩余有效期；归零即显示过期（不依赖下一次轮询）。
    pub(in crate::root_view) fn spawn_wechat_countdown(
        &mut self,
        cx: &mut Context<Self>,
        generation: u64,
    ) {
        cx.spawn(async move |this, cx| loop {
            cx.background_executor().timer(Duration::from_secs(1)).await;
            let keep = this
                .update(cx, |this, cx| {
                    if generation != this.wechat_generation
                        || this.login_mode != LoginMode::Password
                    {
                        return false;
                    }
                    let next = match &mut this.wechat_login {
                        WechatLoginView::Ready {
                            approved: false,
                            remaining_seconds,
                            ..
                        } => {
                            *remaining_seconds = (*remaining_seconds - 1).max(0);
                            Some(*remaining_seconds)
                        }
                        _ => None,
                    };
                    match next {
                        Some(seconds) if seconds > 0 => {
                            cx.notify();
                            true
                        }
                        Some(_) => {
                            this.wechat_login = WechatLoginView::Expired;
                            cx.notify();
                            false
                        }
                        None => false,
                    }
                })
                .unwrap_or(false);
            if !keep {
                break;
            }
        })
        .detach();
    }

    pub(in crate::root_view) fn consume_wechat_login(
        &mut self,
        cx: &mut Context<Self>,
        generation: u64,
        request_id: String,
        proof: String,
    ) {
        if let WechatLoginView::Ready { approved, .. } = &mut self.wechat_login {
            *approved = true;
        }
        self.signing_in = true;
        let api = self.session.api_handle();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move { api.consume_wechat_login(&request_id, &proof) })
                .await;
            let _ = this.update(cx, |this, cx| {
                if generation != this.wechat_generation {
                    return;
                }
                this.finish_login(result);
                this.prepare_agent_authorization(cx);
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn request_password_reset(&mut self, cx: &mut Context<Self>) {
        let email = self.login_email.trim().to_string();
        if email.is_empty() || self.signing_in {
            return;
        }
        self.signing_in = true;
        self.login_error = None;
        let api = self.session.api_handle();
        let task = cx
            .background_executor()
            .spawn(async move { api.request_password_reset(&email) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.signing_in = false;
                match result {
                    Ok(true) => {
                        this.reset_sent = true;
                        this.login_notice = Some(Key::AppAuthResetSent);
                        this.focused = LoginField::ResetToken;
                    }
                    Ok(false) => this.login_error = Some(LoginError::Reset),
                    Err(error) => this.login_error = Some(LoginError::from_auth_error(&error)),
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn submit_reset_password(&mut self, cx: &mut Context<Self>) {
        let token = self.login_reset_token.trim().to_string();
        let password = self.login_new_password.clone();
        if token.is_empty() || password.len() < 8 || self.signing_in {
            self.login_error = Some(LoginError::Reset);
            return;
        }
        self.signing_in = true;
        self.login_error = None;
        let api = self.session.api_handle();
        let task = cx
            .background_executor()
            .spawn(async move { api.reset_password(&token, &password) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.signing_in = false;
                match result {
                    Ok(true) => {
                        this.back_to_password_login(cx);
                        this.login_notice = Some(Key::AppAuthResetSent);
                    }
                    Ok(false) => this.login_error = Some(LoginError::Reset),
                    Err(error) => this.login_error = Some(LoginError::from_auth_error(&error)),
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 测试用：直接访问会话状态机（生产 UI 只通过按钮/异步回调驱动）。
    #[cfg(test)]
    pub(crate) fn session_mut(&mut self) -> &mut SessionService {
        &mut self.session
    }

    #[cfg(test)]
    pub(crate) fn login_error(&self) -> Option<LoginError> {
        self.login_error
    }
}

impl RootView {
    pub(in crate::root_view) fn revoke_device(&mut self, cx: &mut Context<Self>) {
        if self.revoking {
            return;
        }
        let Some(token) = self
            .session
            .signed_in()
            .map(|session| session.token.clone())
        else {
            return;
        };
        self.revoking = true;
        self.settings_error = None;
        let api = self.session.api_handle();
        let task = cx
            .background_executor()
            .spawn(async move { api.revoke(&token) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.revoking = false;
                match result {
                    Ok(()) => {
                        this.session.sign_out_local();
                        this.workspaces.reset();
                        this.workspaces_started = false;
                        this.reset_workspace_data(cx);
                        this.navigate("/");
                    }
                    Err(error) => {
                        this.settings_error = Some(error.diagnostic());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }
}

/// 从 npm ENOENT 错误里提取损坏的 npx 缓存目录（`.../_npx/<hash>/package.json`）。
fn npx_cache_dir_from_error(message: &str) -> Option<std::path::PathBuf> {
    if !message.contains("Could not read package.json") {
        return None;
    }
    let marker = ".npm/_npx/";
    let marker_index = message.find(marker)?;
    let boundary = message[..marker_index]
        .rfind(|ch: char| ch == '\'' || ch == '"' || ch.is_whitespace() || ch == '(' || ch == ':')
        .unwrap_or(0);
    let start = boundary + message[boundary..].chars().next()?.len_utf8();
    let rest = &message[start..];
    let end = rest.find("/package.json")?;
    Some(std::path::PathBuf::from(&rest[..end]))
}

#[cfg(test)]
mod npx_cache_tests {
    use super::npx_cache_dir_from_error;

    #[test]
    fn extracts_corrupt_npx_cache_dir() {
        let message = "acp connection: Internal error: Process exited with exit status: 254: npm error enoent Could not read package.json: Error: ENOENT: no such file or directory, open '/Users/example/.npm/_npx/1f87/package.json'";
        assert_eq!(
            npx_cache_dir_from_error(message).as_deref(),
            Some(std::path::Path::new("/Users/example/.npm/_npx/1f87"))
        );
        assert!(npx_cache_dir_from_error("other error").is_none());
    }
}

#[cfg(test)]
mod native_default_tests {
    use crate::root_view::RootView;

    #[test]
    fn native_is_enabled_by_default_for_both_tracks() {
        assert!(RootView::resolve_native_agent_enabled(None, true));
        assert!(!RootView::resolve_native_agent_enabled(None, false));
    }

    #[test]
    fn env_overrides_prefs() {
        assert!(RootView::resolve_native_agent_enabled(Some("1"), false));
        assert!(!RootView::resolve_native_agent_enabled(Some("0"), true));
    }
}

#[cfg(test)]
mod login_email_tests {
    use super::looks_like_email;

    #[test]
    fn accepts_email_shapes() {
        assert!(looks_like_email("student@example.com"));
        assert!(looks_like_email("a.b+tag@sub.example.org"));
    }

    #[test]
    fn rejects_phone_and_malformed_identifiers() {
        // 客户端只保留邮箱登录：手机号登录已下线。
        assert!(!looks_like_email("{{PHONE_mwhpa2nr}}"));
        assert!(!looks_like_email("13800138000"));
        assert!(!looks_like_email("no-at-sign"));
        assert!(!looks_like_email("@example.com"));
        assert!(!looks_like_email("user@"));
        assert!(!looks_like_email("user@localhost"));
        assert!(!looks_like_email("user@.com"));
        assert!(!looks_like_email("user@example."));
        assert!(!looks_like_email("user name@example.com"));
    }
}

/// 历史点击时，现有终端是否就在目标目录（可直接复用实例而不是替换）。
pub(in crate::root_view) fn terminal_matches_directory(
    current: Option<&std::path::Path>,
    target: &std::path::Path,
) -> bool {
    current == Some(target)
}

/// 进程内唯一、按时间可排序的终端会话 id。
fn next_terminal_session_id() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or_default();
    format!("term-{millis}-{}", COUNTER.fetch_add(1, Ordering::Relaxed))
}

/// 用户 home：macOS/Linux 用 `HOME`，Windows 用 `USERPROFILE`。
fn home_dir() -> Option<std::path::PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(std::path::PathBuf::from)
}

/// 新终端的默认工作目录优先级：上次关闭时的目录 → agent 工作区 → home。
///
/// 只做选择，不做存在性检查：调用方过滤已删除的 `last`，并为 agent 工作区补建目录。
pub(in crate::root_view) fn terminal_cwd<'a>(
    last: Option<&'a std::path::Path>,
    scope_root: Option<&'a std::path::Path>,
    home: Option<&'a std::path::Path>,
) -> Option<&'a std::path::Path> {
    last.or(scope_root).or(home)
}
