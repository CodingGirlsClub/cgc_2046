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
                .try_find_by_label("Only workspace members can enroll. Join the workspace first.")
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
