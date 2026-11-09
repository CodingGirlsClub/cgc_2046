//! 公开目录的标题/空态/筛选与工作区列表分流。

use super::RootView;
use crate::i18n::Language;
use crate::theme::ThemePreference;
use cgc_courses::catalog::{CourseCatalogService, FakeCoursesApi};
use cgc_events::list::{EventListService, FakeEventsApi};
use cgc_platform::session::{FakeAuthApi, MemoryStore, SessionService};
use cgc_platform::workspace::OfferingScope;
use gpui_kit::test::{TestQueryExt, TestWindowExt};
use gpui_kit::{
    div, px, size, AppContext, Bounds, Context, Entity, IntoElement, ParentElement, Render, Styled,
    TestAppContext, Window, WindowBounds, WindowOptions,
};
use std::sync::Arc;

#[derive(Clone, Copy)]
enum ListKind {
    Courses,
    Events,
}

struct ListProbe {
    root: Entity<RootView>,
    kind: ListKind,
}

impl Render for ListProbe {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let kind = self.kind;
        let list = self.root.update(cx, |root, cx| {
            let palette = crate::theme::palette(gpui_kit::component::ThemeMode::Light);
            let mut context = crate::root_view::screens::ScreenContext::new(&mut root.state);
            match kind {
                ListKind::Courses => crate::root_view::screens::render_courses_list(
                    &mut context,
                    Language::En,
                    &palette,
                    cx,
                ),
                ListKind::Events => crate::root_view::screens::render_events_list(
                    &mut context,
                    Language::En,
                    &palette,
                    cx,
                ),
            }
        });
        div().size(px(740.0)).flex().flex_col().child(list)
    }
}

fn open_courses(
    cx: &mut TestAppContext,
    empty: bool,
) -> (gpui_kit::AnyWindowHandle, Entity<RootView>) {
    open_list(cx, "/courses", ListKind::Courses, |root| {
        let mut courses = CourseCatalogService::new(Arc::new(if empty {
            FakeCoursesApi::with_seed(0)
        } else {
            FakeCoursesApi::with_seed(2)
        }));
        courses.begin_first_load();
        let page = courses
            .fetch(None, OfferingScope::Public)
            .expect("courses page");
        courses.adopt_page(page);
        root.state.courses = courses;
    })
}

fn open_events(cx: &mut TestAppContext) -> (gpui_kit::AnyWindowHandle, Entity<RootView>) {
    open_list(cx, "/events", ListKind::Events, |root| {
        let mut events = EventListService::new(Arc::new(FakeEventsApi::with_seed(2)));
        events.begin_first_load();
        let page = events
            .fetch(None, OfferingScope::Public)
            .expect("events page");
        events.adopt_page(page);
        root.state.events = events;
    })
}

fn open_list(
    cx: &mut TestAppContext,
    start_path: &'static str,
    kind: ListKind,
    seed: impl FnOnce(&mut RootView),
) -> (gpui_kit::AnyWindowHandle, Entity<RootView>) {
    cx.update(gpui_kit::init);
    cx.update(|cx| {
        let (handle, probe) = gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(740.), px(520.)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                let root = cx.new(|_| {
                    let mut root = RootView::with_session_from(
                        crate::registration::build_registry().unwrap(),
                        Language::En,
                        ThemePreference::Light,
                        SessionService::new(
                            Box::new(FakeAuthApi::demo()),
                            Box::new(MemoryStore::default()),
                        ),
                        start_path,
                    );
                    seed(&mut root);
                    root
                });
                cx.new(|_| ListProbe { root, kind })
            },
        )
        .expect("list probe window");
        let root = probe.read(cx).root.clone();
        (handle, root)
    })
}

#[gpui_kit::test]
fn public_courses_list_uses_public_title(cx: &mut TestAppContext) {
    let (handle, _root) = open_courses(cx, false);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(
            window.try_find_by_label("Public courses").is_some(),
            "public courses list must use the public title"
        );
        assert!(
            window.try_find_by_label("Courses").is_none(),
            "public courses list must not reuse the workspace title"
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn public_courses_empty_state_uses_public_copy(cx: &mut TestAppContext) {
    let (handle, _root) = open_courses(cx, true);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(
            window
                .try_find_by_label("No public courses right now.")
                .is_some(),
            "public empty state must explain the public catalog"
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn public_events_list_hides_workspace_filters(cx: &mut TestAppContext) {
    let (handle, _root) = open_events(cx);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(
            window.try_find_by_label("Public events").is_some(),
            "public events list must use the public title"
        );
        let paths = window
            .elements()
            .iter()
            .map(|element| format!("{:?}", element.path()))
            .collect::<Vec<_>>();
        assert!(
            !paths.iter().any(|path| path.contains("events-filter-")),
            "public events list must not show workspace status filters: {paths:?}"
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn public_course_card_displays_its_own_workspace(cx: &mut TestAppContext) {
    let (handle, root) = open_courses(cx, false);
    root.update(cx, |root, cx| {
        root.workspaces
            .adopt(vec![cgc_platform::workspace::WorkspaceSummary {
                id: "ws-demo".into(),
                slug: "demo".into(),
                name: "Demo".into(),
                my_role_names: vec![],
                member_count: None,
                can_access: true,
            }]);
        cx.notify();
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        let origin = window
            .within("course-row-crs-000")
            .find_by_label("Workspace · Demo");
        assert!(origin.visible());
    })
    .unwrap();
}
