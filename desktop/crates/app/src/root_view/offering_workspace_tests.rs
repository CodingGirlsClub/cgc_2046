//! 从真实 HTTP 读取报名归属，再通过个人页面验证跨工作台导航。

use super::RootView;
use crate::{i18n::Language, theme::ThemePreference, workspace_state};
use cgc_events::enrollments::{
    EnrollmentsApi, HttpEnrollmentsApi, LearningNextAction, LearningProgress, MyEnrollmentRow,
    MyLearningRunRow,
};
use cgc_platform::{
    api::GraphqlClient,
    session::{FakeAuthApi, MemoryStore, SessionService},
    workspace::WorkspaceSummary,
};
use gpui_kit::test::{TestQueryExt, TestWindowExt};
use gpui_kit::{
    div, px, size, AppContext, Bounds, Context, Entity, IntoElement, ParentElement, Render, Styled,
    TestAppContext, Window, WindowBounds, WindowOptions,
};
use std::{
    io::{Read, Write},
    net::TcpListener,
};

#[derive(Clone, Copy)]
enum PersonalPage {
    Learning,
    Participations,
}

struct PersonalPageProbe {
    root: Entity<RootView>,
    page: PersonalPage,
}

impl Render for PersonalPageProbe {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let page = self.page;
        let body = self.root.update(cx, |root, cx| {
            let palette = crate::theme::palette(gpui_kit::component::ThemeMode::Light);
            let mut ctx = crate::root_view::screens::ScreenContext::new(&mut root.state);
            match page {
                PersonalPage::Learning => crate::root_view::screens::render_learning_home(
                    &mut ctx,
                    Language::En,
                    &palette,
                    cx,
                ),
                PersonalPage::Participations => crate::root_view::screens::render_participations(
                    &mut ctx,
                    Language::En,
                    &palette,
                    cx,
                ),
            }
        });
        div().size_full().child(body)
    }
}

pub(super) fn read_graphql_request(stream: &mut std::net::TcpStream) -> serde_json::Value {
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(5)))
        .unwrap();
    let mut request = Vec::new();
    let mut buffer = [0; 4096];
    let header_end = loop {
        let count = stream.read(&mut buffer).unwrap();
        assert_ne!(count, 0, "request headers must complete");
        request.extend_from_slice(&buffer[..count]);
        if let Some(end) = request.windows(4).position(|bytes| bytes == b"\r\n\r\n") {
            break end + 4;
        }
    };
    let headers = String::from_utf8_lossy(&request[..header_end]);
    let content_length = headers
        .lines()
        .find_map(|line| {
            let (key, value) = line.split_once(':')?;
            key.eq_ignore_ascii_case("content-length")
                .then(|| value.trim().parse::<usize>().unwrap())
        })
        .expect("request body length");
    while request.len() < header_end + content_length {
        let count = stream.read(&mut buffer).unwrap();
        assert_ne!(count, 0, "request body must complete");
        request.extend_from_slice(&buffer[..count]);
    }
    serde_json::from_slice(&request[header_end..]).unwrap()
}

fn fetch_owned_enrollment(course: bool, status: &str) -> Vec<MyEnrollmentRow> {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind GraphQL fixture");
    let address = listener.local_addr().unwrap();
    let status = status.to_owned();
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let request = read_graphql_request(&mut stream);
        let mut row = serde_json::json!({
            "id": "owned-enrollment", "status": status, "targetTitle": "Beta offering",
            "eventId": if course { None } else { Some("e-1") },
            "courseId": if course { Some("c-1") } else { None },
        });
        // GraphQL 仅返回实际被选中的字段，不能用无条件 fixture 掩盖漏选。
        if request["query"].as_str().unwrap().contains("workspaceId") {
            row["workspaceId"] = serde_json::json!("ws-beta");
        }
        let body =
            serde_json::json!({"data":{"myEnrollments":{"count":1,"results":[row]}}}).to_string();
        write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
    });
    let result =
        HttpEnrollmentsApi::new(GraphqlClient::new(format!("http://{address}/api/graphql")))
            .my_enrollments(None)
            .expect("enrollment response");
    server.join().unwrap();
    result
}

fn open_personal_page(
    cx: &mut TestAppContext,
    page: PersonalPage,
    course: bool,
    status: &str,
    accessible: bool,
) -> (gpui_kit::AnyWindowHandle, Entity<RootView>) {
    let rows = fetch_owned_enrollment(course, status);
    cx.update(gpui_kit::init);
    cx.update(|cx| {
        let (window, probe) = gpui_kit::open_window(
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
                        match page {
                            PersonalPage::Learning => "/learning",
                            PersonalPage::Participations => "/participations",
                        },
                    );
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
                            id: "ws-beta".into(),
                            slug: "beta".into(),
                            name: "Beta".into(),
                            my_role_names: vec![],
                            member_count: None,
                            can_access: accessible,
                        },
                    ]);
                    root.enrollments_rows = rows;
                    root.enrollments_state = super::EnrollmentsListState::Ready;
                    root
                });
                cx.new(|_| PersonalPageProbe { root, page })
            },
        )
        .unwrap();
        (window, probe.read(cx).root.clone())
    })
}

#[gpui_kit::test]
fn learning_entry_uses_enrollment_workspace_instead_of_current_workspace(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    let (window, root) = open_personal_page(cx, PersonalPage::Learning, true, "confirmed", true);
    cx.update_window(window, |_, window, cx| {
        window.render_frame(cx);
        window.click("learning-home-owned-enrollment", cx);
        let current = root.read(cx).current.as_ref().expect("learning route");
        assert_eq!(current.params.get("slug").map(String::as_str), Some("beta"));
        assert_eq!(current.route.id, "courses.learning");
        assert_eq!(current.params.get("id").map(String::as_str), Some("c-1"));
    })
    .unwrap();
}

#[gpui_kit::test]
fn personal_entries_show_the_owning_workspace(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    for page in [PersonalPage::Learning, PersonalPage::Participations] {
        let (window, _) = open_personal_page(cx, page, true, "confirmed", true);
        cx.update_window(window, |_, window, cx| {
            window.render_frame(cx);
            assert!(window.try_find_by_label("Workspace · Beta").is_some());
            assert!(window.try_find_by_label("Workspace · Alpha").is_none());
        })
        .unwrap();
    }
}

#[gpui_kit::test]
fn participation_entries_route_courses_and_events_to_their_owner(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    for (course, status, expected_route, expected_path) in [
        (true, "pending", "courses.detail", "/w/beta/courses/c-1"),
        (false, "confirmed", "events.detail", "/w/beta/events/e-1"),
    ] {
        let (window, root) =
            open_personal_page(cx, PersonalPage::Participations, course, status, true);
        cx.update_window(window, |_, window, cx| {
            window.render_frame(cx);
            window.click("participation-owned-enrollment", cx);
            let current = root.read(cx).current.as_ref().unwrap();
            assert_eq!(current.route.id, expected_route);
            assert_eq!(current.params.get("slug").map(String::as_str), Some("beta"));
        })
        .unwrap();
        // R10：「我的报名 → 查看」必须走 tab 生命周期，而不是只 navigate。
        root.update(cx, |root, _| {
            assert!(
                root.state.tabs.iter().any(|tab| tab.path == expected_path),
                "跨台查看必须插入目标台 tab（{expected_path}）"
            );
        });
        let alpha = workspace_state::entry("ws-alpha").expect("源台状态已落盘");
        assert_eq!(
            alpha.active_tab, None,
            "源台停在无 tab 的个人页，切换前也要先把源台状态落盘"
        );
        let beta = workspace_state::entry("ws-beta").expect("目标台状态已落盘");
        assert!(
            beta.tabs.iter().any(|tab| tab.path == expected_path),
            "目标 tab 必须持久化到目标台"
        );
    }
}

#[gpui_kit::test]
fn run_from_an_event_enrollment_opens_the_owning_workspace(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    // course=false：这条报名是活动报名（course_id 为空），run 来自配套课程。
    let (window, root) = open_personal_page(cx, PersonalPage::Learning, false, "confirmed", true);
    root.update(cx, |root, cx| {
        root.learning_runs = vec![MyLearningRunRow {
            run_id: "run-paired".into(),
            enrollment_id: "owned-enrollment".into(),
            course_id: "paired-course".into(),
            target_title: Some("Paired course".into()),
            status: "active".into(),
            stale_revision: false,
            progress: LearningProgress {
                mastered_required: 0,
                total_required: 2,
                complete: false,
            },
            next_action: None,
        }];
        cx.notify();
    });
    cx.update_window(window, |_, window, cx| {
        window.render_frame(cx);
        let row = window.within("learning-run-run-paired");
        assert!(
            row.try_find_by_label("Workspace · Beta").is_some(),
            "the run resolves its workspace through the event enrollment"
        );
        window.click("learning-run-run-paired", cx);
    })
    .unwrap();
    root.update(cx, |root, _| {
        let current = root.current.as_ref().expect("learning route");
        assert_eq!(current.route.id, "courses.learning");
        assert_eq!(current.params.get("slug").map(String::as_str), Some("beta"));
        assert_eq!(
            current.params.get("id").map(String::as_str),
            Some("paired-course")
        );
    });
}

#[gpui_kit::test]
fn learning_home_prefers_runs_and_hides_rows_without_one(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    let (window, root) = open_personal_page(cx, PersonalPage::Learning, true, "confirmed", true);
    root.update(cx, |root, cx| {
        root.learning_runs = vec![MyLearningRunRow {
            run_id: "run-1".into(),
            enrollment_id: "owned-enrollment".into(),
            course_id: "c-1".into(),
            target_title: Some("Beta offering".into()),
            status: "active".into(),
            stale_revision: true,
            progress: LearningProgress {
                mastered_required: 2,
                total_required: 4,
                complete: false,
            },
            next_action: Some(LearningNextAction {
                kind: "review".into(),
                objective_id: "obj-1".into(),
                reason: "due".into(),
            }),
        }];
        root.enrollments_rows.push(MyEnrollmentRow {
            id: "confirmed-without-run".into(),
            workspace_id: "ws-alpha".into(),
            status: "confirmed".into(),
            target_title: Some("Alpha course".into()),
            starts_at: None,
            event_id: None,
            course_id: Some("c-9".into()),
            payment_mode: None,
            check_in_code: None,
        });
        root.enrollments_rows.push(MyEnrollmentRow {
            id: "awaiting-payment".into(),
            workspace_id: "ws-alpha".into(),
            status: "payment_pending".into(),
            target_title: Some("Unpaid course".into()),
            starts_at: None,
            event_id: None,
            course_id: Some("c-8".into()),
            payment_mode: Some("paid".into()),
            check_in_code: None,
        });
        cx.notify();
    });
    cx.update_window(window, |_, window, cx| {
        window.render_frame(cx);
        assert!(window.find_by_label("Mastered 2/4 required").visible());
        assert!(window.find_by_label("Review due").visible());
        assert!(window
            .find_by_label("Course updated; progress stays on the older revision")
            .visible());
        assert!(
            window.try_find("learning-run-run-1").is_some(),
            "the run row is the primary entry"
        );
        assert!(
            window
                .try_find("learning-home-confirmed-without-run")
                .is_some(),
            "a confirmed enrollment without a run stays as fallback"
        );
        assert!(
            window.try_find("learning-home-awaiting-payment").is_none(),
            "unpaid courses belong to My enrollments, not the learning page"
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn inaccessible_owner_keeps_learning_on_the_public_route(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    let (window, root) = open_personal_page(cx, PersonalPage::Learning, true, "confirmed", false);
    cx.update_window(window, |_, window, cx| {
        window.render_frame(cx);
        window.click("learning-home-owned-enrollment", cx);
        let current = root.read(cx).current.as_ref().unwrap();
        assert_eq!(current.route.id, "courses.public_learning");
        assert_eq!(current.params.get("slug"), None);
        assert_eq!(root.read(cx).workspaces.current_id(), Some("ws-alpha"));
    })
    .unwrap();
}
