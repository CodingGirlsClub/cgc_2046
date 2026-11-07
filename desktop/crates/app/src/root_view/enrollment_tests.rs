//! 公开详情报名闭环：工作区限定的明确文案与报名后的「我的报名」入口。

use super::RootView;
use crate::i18n::Language;
use crate::theme::ThemePreference;
use cgc_events::detail::{EventDetail, EventDetailService};
use cgc_events::enroll::MyEnrollment;
use cgc_events::list::{EventSummary, FakeEventsApi};
use cgc_platform::session::{FakeAuthApi, MemoryStore, SessionService};
use gpui_kit::test::{TestQueryExt, TestWindowExt};
use gpui_kit::{
    div, px, size, AppContext, Bounds, Context, Entity, IntoElement, ParentElement, Render, Styled,
    TestAppContext, Window, WindowBounds, WindowOptions,
};
use std::sync::Arc;

struct EnrollmentProbe {
    root: Entity<RootView>,
    detail: EventDetail,
}

impl Render for EnrollmentProbe {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let detail = self.detail.clone();
        let area = self.root.update(cx, |root, cx| {
            let palette = crate::theme::palette(gpui_kit::component::ThemeMode::Light);
            let mut context = crate::root_view::screens::ScreenContext::new(&mut root.state);
            crate::root_view::screens::render_enrollment_area(
                &mut context,
                Language::En,
                &palette,
                &detail,
                cx,
            )
        });
        div().size(px(640.0)).flex().flex_col().child(area)
    }
}

fn summary(visibility: &str) -> EventSummary {
    EventSummary {
        id: "e-1".into(),
        title: "Public event".into(),
        status: "open".into(),
        visibility: visibility.into(),
        enrollment_policy: "open".into(),
        capacity: Some(10),
        confirmed_count: Some(1),
        enrollment_badge: Some("enrolling".into()),
        registration_deadline: None,
        starts_at: None,
        venue: None,
        pricing_enabled: false,
    }
}

fn open_enrollment_area(
    cx: &mut TestAppContext,
    visibility: &str,
    enrollment: Option<MyEnrollment>,
) -> (gpui_kit::AnyWindowHandle, Entity<RootView>) {
    cx.update(gpui_kit::init);
    cx.update(|cx| {
        let detail = EventDetail::from_summary(&summary(visibility));
        let (handle, probe) = gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(640.), px(400.)),
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
                        "/events/e-1",
                    );
                    let mut service =
                        EventDetailService::new(Arc::new(FakeEventsApi::with_seed(1)));
                    service.adopt(detail.clone());
                    service.adopt_enrollment(enrollment.clone());
                    root.state.detail = service;
                    root
                });
                cx.new(|_| EnrollmentProbe {
                    root,
                    detail: detail.clone(),
                })
            },
        )
        .expect("enrollment probe window");
        let root = probe.read(cx).root.clone();
        (handle, root)
    })
}

#[gpui_kit::test]
fn public_workspace_only_event_explains_the_gate(cx: &mut TestAppContext) {
    let (handle, _root) = open_enrollment_area(cx, "workspace", None);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(
            window
                .try_find_by_label("Only workspace members can enroll. If you're a member, open it from the workspace.")
                .is_some(),
            "workspace-only public detail must explain the membership gate"
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn enrolled_detail_links_to_my_enrollments(cx: &mut TestAppContext) {
    let (handle, _root) = open_enrollment_area(
        cx,
        "public",
        Some(MyEnrollment {
            id: "enr-1".into(),
            status: "confirmed".into(),
            check_in_code: None,
        }),
    );
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(
            window.try_find_by_label("View in My enrollments").is_some(),
            "confirmed enrollment must link to My enrollments"
        );
    })
    .unwrap();
}

struct CourseDetailProbe {
    root: Entity<RootView>,
}

impl Render for CourseDetailProbe {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let detail = self.root.update(cx, |root, cx| {
            let palette = crate::theme::palette(gpui_kit::component::ThemeMode::Light);
            let mut context = crate::root_view::screens::ScreenContext::new(&mut root.state);
            if context.current.as_ref().is_some_and(|route_match| {
                matches!(
                    route_match.route.id,
                    "courses.learning" | "courses.public_learning"
                )
            }) {
                crate::root_view::screens::render_course_learning(
                    &mut context,
                    Language::En,
                    &palette,
                    cx,
                )
            } else {
                crate::root_view::screens::render_course_detail(
                    &mut context,
                    Language::En,
                    &palette,
                    cx,
                )
            }
        });
        div().size(px(640.0)).flex().flex_col().child(detail)
    }
}

fn open_course_detail(
    cx: &mut TestAppContext,
    visibility: &str,
    policy: &str,
    status: Option<&str>,
) -> (gpui_kit::AnyWindowHandle, Entity<RootView>) {
    cx.update(gpui_kit::init);
    cx.update(|cx| {
        let (handle, probe) = gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(640.), px(480.)),
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
                        "/courses/c-1",
                    );
                    let mut service = cgc_courses::catalog::CourseDetailService::new(Arc::new(
                        cgc_courses::catalog::FakeCoursesApi::with_seed(1),
                    ));
                    service.adopt(cgc_courses::catalog::CourseDetail {
                        id: "c-1".into(),
                        title: "Public course".into(),
                        description: None,
                        status: "open".into(),
                        visibility: visibility.into(),
                        workspace_id: Some("ws-1".into()),
                        pricing_enabled: false,
                        enrollment_policy: policy.into(),
                        available_price_tiers: Vec::new(),
                        enrollment_status: status.map(str::to_string),
                        revision_number: None,
                    });
                    root.state.course_detail = service;
                    root
                });
                cx.new(|_| CourseDetailProbe { root })
            },
        )
        .expect("course detail probe window");
        let root = probe.read(cx).root.clone();
        (handle, root)
    })
}

#[gpui_kit::test]
fn public_workspace_only_course_explains_the_gate(cx: &mut TestAppContext) {
    let (handle, _root) = open_course_detail(cx, "workspace", "open", None);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(
            window
                .try_find_by_label("Only workspace members can enroll. If you're a member, open it from the workspace.")
                .is_some(),
            "workspace-only public course must explain the membership gate"
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn public_free_course_shows_enroll_button(cx: &mut TestAppContext) {
    let (handle, _root) = open_course_detail(cx, "public", "open", None);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        let paths = window
            .elements()
            .iter()
            .map(|element| format!("{:?}", element.path()))
            .collect::<Vec<_>>();
        assert!(
            paths
                .iter()
                .any(|path| path.contains("Name(\"course-enroll-button\")")),
            "unenrolled public course must offer enrollment: {paths:?}"
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn payment_pending_course_hides_the_enroll_button(cx: &mut TestAppContext) {
    let (handle, _root) = open_course_detail(cx, "public", "open", Some("payment_pending"));
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        let paths = window
            .elements()
            .iter()
            .map(|element| format!("{:?}", element.path()))
            .collect::<Vec<_>>();
        assert!(
            paths
                .iter()
                .any(|path| path.contains("Name(\"course-view-participations\")")),
            "payment_pending course must link to My enrollments: {paths:?}"
        );
        assert!(
            !paths
                .iter()
                .any(|path| path.contains("Name(\"course-enroll-button\")")),
            "payment_pending course must not offer a second enrollment: {paths:?}"
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn invite_only_course_explains_the_gate(cx: &mut TestAppContext) {
    let (handle, _root) = open_course_detail(cx, "public", "invite_only", None);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        let paths = window
            .elements()
            .iter()
            .map(|element| format!("{:?}", element.path()))
            .collect::<Vec<_>>();
        assert!(
            !paths
                .iter()
                .any(|path| path.contains("Name(\"course-enroll-button\")")),
            "invite-only course must not offer enrollment: {paths:?}"
        );
        assert!(
            window
                .try_find_by_label("Invitation required for this course.")
                .is_some(),
            "invite-only course must explain the gate"
        );
    })
    .unwrap();
}

fn adopt_course_workspaces(root: &mut RootView, accessible: bool) {
    use cgc_platform::workspace::WorkspaceSummary;
    root.workspaces.adopt(vec![
        WorkspaceSummary {
            id: "ws-alpha".into(),
            slug: "alpha".into(),
            name: "Alpha".into(),
            my_role_names: vec![],
            member_count: None,
            can_access: true,
        },
        WorkspaceSummary {
            id: "ws-1".into(),
            slug: "beta".into(),
            name: "Beta".into(),
            my_role_names: vec![],
            member_count: None,
            can_access: accessible,
        },
    ]);
}

#[gpui_kit::test]
fn public_course_detail_opens_its_own_workspace(cx: &mut TestAppContext) {
    let (handle, root) = open_course_detail(cx, "public", "open", None);
    root.update(cx, |root, cx| {
        adopt_course_workspaces(root, true);
        cx.notify();
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(window.find_by_label("Workspace · Beta").visible());
        window.click("course-open-workspace", cx);
        let current = root.read(cx).current.as_ref().unwrap();
        assert_eq!(current.route.id, "courses.detail");
        assert_eq!(current.params.get("slug").map(String::as_str), Some("beta"));
    })
    .unwrap();
}

#[gpui_kit::test]
fn public_course_detail_omits_an_inaccessible_workspace_entry(cx: &mut TestAppContext) {
    let (handle, root) = open_course_detail(cx, "public", "open", None);
    root.update(cx, |root, cx| {
        adopt_course_workspaces(root, false);
        cx.notify();
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(window.try_find("course-open-workspace").is_none());
        assert!(window.find_by_label("Workspace · Beta").visible());
    })
    .unwrap();
}

#[gpui_kit::test]
fn public_learning_opens_the_course_workspace(cx: &mut TestAppContext) {
    let (handle, root) = open_course_detail(cx, "public", "open", Some("confirmed"));
    root.update(cx, |root, cx| {
        adopt_course_workspaces(root, true);
        root.session
            .sign_in("demo@example.com", "demo")
            .expect("fake session");
        root.navigate("/courses/c-1/learn");
        let mut detail = root.course_detail.detail().unwrap().clone();
        detail.revision_number = Some(1);
        root.course_detail.adopt(detail);
        cx.notify();
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(window.find_by_label("Workspace · Beta").visible());
        window.click("course-open-workspace", cx);
        let current = root.read(cx).current.as_ref().unwrap();
        assert_eq!(current.route.id, "courses.learning");
        assert_eq!(current.params.get("slug").map(String::as_str), Some("beta"));
    })
    .unwrap();
}

#[gpui_kit::test]
fn issue_tab_without_owner_access_stays_on_public_learning(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    let (_, root) = open_course_detail(cx, "public", "open", Some("confirmed"));
    root.update(cx, |root, cx| {
        adopt_course_workspaces(root, false);
        root.navigate("/courses/c-1/learn");
        root.open_issue_tab("c-1", "issue-1", "First card", cx);
        assert_eq!(
            root.current.as_ref().unwrap().route.id,
            "courses.public_learning"
        );
        assert_eq!(root.current.as_ref().unwrap().params.get("slug"), None);
    });
}
