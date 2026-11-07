//! Site Tree：搜索过滤与未报名学习内容锁定。

use super::RootView;
use crate::i18n::Language;
use crate::theme::ThemePreference;
use cgc_courses::catalog::{CourseCatalogService, FakeCoursesApi};
use cgc_platform::session::{FakeAuthApi, MemoryStore, SessionService};
use cgc_platform::workspace::{OfferingScope, WorkspaceScope, WorkspaceSummary};
use gpui_kit::test::{TestQueryExt, TestWindowExt};
use gpui_kit::{
    div, px, size, AppContext, Bounds, Context, Entity, IntoElement, ParentElement, Render, Styled,
    TestAppContext, Window, WindowBounds, WindowOptions,
};
use std::sync::Arc;

struct SiteTreeProbe {
    root: Entity<RootView>,
    language: Language,
}

impl Render for SiteTreeProbe {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let language = self.language;
        let area = self.root.update(cx, |root, cx| {
            let palette = crate::theme::palette(gpui_kit::component::ThemeMode::Light);
            let mut context = crate::root_view::screens::ScreenContext::new(&mut root.state);
            crate::root_view::screens::render_right_dock(
                &mut context,
                language,
                &palette,
                window,
                cx,
            )
        });
        div().size(px(360.0)).flex().flex_col().child(area)
    }
}

fn site_tree_window(cx: &mut TestAppContext) -> (gpui_kit::AnyWindowHandle, Entity<RootView>) {
    cx.update(gpui_kit::init);
    cx.update(|cx| {
        let (handle, probe) = gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(960.), px(720.)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                let root = cx.new(|_| {
                    let mut root = RootView::with_session_from(
                        crate::registration::build_registry().expect("registry"),
                        Language::Zh,
                        ThemePreference::Light,
                        SessionService::new(
                            Box::new(FakeAuthApi::demo()),
                            Box::new(MemoryStore::default()),
                        ),
                        "/w/2046/courses",
                    );
                    root.workspaces.adopt(vec![WorkspaceSummary {
                        id: "ws-1".into(),
                        slug: "2046".into(),
                        name: "CGC 2046".into(),
                        my_role_names: Vec::new(),
                        member_count: None,
                        can_access: true,
                    }]);
                    root
                });
                cx.new(|_| SiteTreeProbe {
                    root: root.clone(),
                    language: Language::Zh,
                })
            },
        )
        .expect("site tree window");
        let root = probe.read(cx).root.clone();
        (handle, root)
    })
}

fn load_fake_courses(root: &mut RootView) {
    root.right_panel = crate::root_view::state::RightPanel::SiteTree;
    root.right_panel_open = true;
    root.right_panel_width = 360.0;
    root.site_tree_courses_open = true;
    root.courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(5)));
    root.courses.begin_first_load();
    let page = root
        .courses
        .fetch(
            None,
            OfferingScope::Workspace(&WorkspaceScope {
                workspace_id: "ws-1".into(),
                epoch: 1,
            }),
        )
        .expect("courses page");
    root.courses.adopt_page(page);
    root.courses_started = true;
    root.events_started = true;
}

#[gpui_kit::test]
fn typing_and_clearing_tree_search_filters_then_restores_courses(cx: &mut TestAppContext) {
    let (handle, root) = site_tree_window(cx);
    root.update(cx, |root, cx| {
        load_fake_courses(root);
        cx.notify();
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.click("site-tree-search", cx);
        window.input("课程 3", cx);
        assert!(window.try_find_by_label("展开 课程 3").is_some());
        assert!(window.try_find_by_label("展开 课程 1").is_none());
        window.press("cmd-a", cx);
        window.press("backspace", cx);
        assert!(window.try_find_by_label("展开 课程 1").is_some());
        assert!(window.try_find_by_label("展开 课程 3").is_some());
    })
    .unwrap();
}

#[gpui_kit::test]
fn searching_an_issue_preserves_and_expands_its_course(cx: &mut TestAppContext) {
    let (handle, root) = site_tree_window(cx);
    root.update(cx, |root, cx| {
        load_fake_courses(root);
        root.course_enrollments
            .insert("crs-000".into(), Some("confirmed".into()));
        let content = root
            .courses
            .api_handle()
            .get_course_content(None, "crs-000")
            .expect("published course content");
        root.content.adopt(content);
        cx.notify();
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.click("site-tree-search", cx);
        window.input("第一次运行", cx);
        assert!(window.try_find_by_label("收起 课程 1").is_some());
        assert!(window.try_find_by_label("展开 课程 2").is_none());
    })
    .unwrap();
}

#[gpui_kit::test]
fn unconfirmed_course_expansion_keeps_learning_content_unloaded(cx: &mut TestAppContext) {
    let (handle, root) = site_tree_window(cx);
    root.update(cx, |root, _| load_fake_courses(root));

    for status in [
        None,
        Some("pending"),
        Some("payment_pending"),
        Some("cancelled"),
    ] {
        root.update(cx, |root, cx| {
            root.site_tree_course_open = None;
            root.content =
                cgc_courses::content::CourseContentService::new(root.courses.api_handle());
            root.course_enrollments
                .insert("crs-000".into(), status.map(str::to_owned));
            cx.notify();
        });
        cx.update_window(handle, |_, window, cx| {
            window.render_frame(cx);
            window.click("site-course-chevron-crs-000", cx);
            assert_eq!(
                root.read(cx).content.state(),
                &cgc_courses::content::CourseContentState::Idle,
                "an enrollment with status {status:?} cannot open learning content"
            );
        })
        .unwrap();
    }
}

#[gpui_kit::test]
fn confirmed_course_expansion_loads_its_learning_content(cx: &mut TestAppContext) {
    let (handle, root) = site_tree_window(cx);
    root.update(cx, |root, cx| {
        load_fake_courses(root);
        root.content = cgc_courses::content::CourseContentService::new(root.courses.api_handle());
        root.course_enrollments
            .insert("crs-000".into(), Some("confirmed".into()));
        cx.notify();
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.click("site-course-chevron-crs-000", cx);
        assert_eq!(root.read(cx).content.course_id(), Some("crs-000"));
    })
    .unwrap();
}

#[gpui_kit::test]
fn public_catalog_third_page_courses_can_unlock_in_the_tree(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    let (handle, root) = site_tree_window(cx);
    root.update(cx, |root, cx| {
        load_fake_courses(root);
        let api = Arc::new(FakeCoursesApi::with_seed(25));
        root.courses = CourseCatalogService::new(api.clone());
        root.content = cgc_courses::content::CourseContentService::new(api);
        root.navigate("/courses");
        root.start_courses_load(cx, true);
    });
    cx.run_until_parked();
    for _ in 0..2 {
        root.update(cx, |root, cx| root.start_courses_load(cx, false));
        cx.run_until_parked();
    }
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.click("site-tree-search", cx);
        window.input("课程 21", cx);
    })
    .unwrap();
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.click("site-course-chevron-crs-020", cx);
        assert_eq!(root.read(cx).content.course_id(), Some("crs-020"));
        assert_eq!(
            root.read(cx).current().map(|route| route.id),
            Some("courses.public_list")
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn enrollment_arrival_loads_the_course_already_expanded(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    let (_, root) = site_tree_window(cx);
    root.update(cx, |root, cx| {
        load_fake_courses(root);
        root.content = cgc_courses::content::CourseContentService::new(root.courses.api_handle());
        root.load_course_enrollments(cx);
        root.toggle_site_tree_course("crs-000", cx);
    });
    cx.run_until_parked();
    root.update(cx, |root, _| {
        assert_eq!(
            root.content
                .content()
                .map(|content| content.course_id.as_str()),
            Some("crs-000")
        );
    });
}

#[gpui_kit::test]
fn authoritative_course_detail_unlocks_a_previously_unenrolled_tree_entry(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    let (handle, root) = site_tree_window(cx);
    root.update(cx, |root, cx| {
        load_fake_courses(root);
        root.content = cgc_courses::content::CourseContentService::new(root.courses.api_handle());
        root.course_enrollments.insert("crs-000".into(), None);
        let detail = root
            .courses
            .api_handle()
            .get_course(None, "crs-000")
            .unwrap();
        root.adopt_course_detail(detail);
        cx.notify();
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.click("site-course-chevron-crs-000", cx);
        assert_eq!(root.read(cx).content.course_id(), Some("crs-000"));
    })
    .unwrap();
}

#[gpui_kit::test]
fn enrollment_completion_updates_the_tree_only_in_the_origin_workspace(cx: &mut TestAppContext) {
    for leave_workspace in [false, true] {
        let _files = super::workspace_layout_tests::LayoutFiles::new();
        let (_, root) = site_tree_window(cx);
        root.update(cx, |root, cx| {
            load_fake_courses(root);
            root.session.sign_in("demo@example.com", "demo").unwrap();
            root.navigate("/w/2046/courses/crs-000");
            root.course_enrollments.insert("crs-000".into(), None);
            root.course_detail =
                cgc_courses::catalog::CourseDetailService::new(root.courses.api_handle());
            let mut detail = root
                .courses
                .api_handle()
                .get_course(None, "crs-000")
                .unwrap();
            detail.enrollment_status = None;
            root.course_detail.adopt(detail);
            root.submit_course_enrollment("crs-000", cx);
            if leave_workspace {
                let mut workspaces = root.workspaces.workspaces().to_vec();
                workspaces.push(WorkspaceSummary {
                    id: "ws-other".into(),
                    slug: "other".into(),
                    name: "Other".into(),
                    my_role_names: vec![],
                    member_count: None,
                    can_access: true,
                });
                root.workspaces.adopt(workspaces);
                root.switch_workspace("ws-other", cx);
                root.sync_workspace_route(cx);
            } else {
                root.navigate("/w/2046/courses/crs-001");
            }
        });
        cx.run_until_parked();
        root.update(cx, |root, _| {
            let status = root
                .course_enrollments
                .get("crs-000")
                .and_then(Option::as_deref);
            assert_eq!(
                status,
                if leave_workspace {
                    None
                } else {
                    Some("confirmed")
                }
            );
        });
    }
}
