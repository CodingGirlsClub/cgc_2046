use super::{
    navigation_lifecycle_tests::root_window, offering_workspace_tests::read_graphql_request,
};
use cgc_courses::catalog::{CourseCatalogService, CourseDetailService, HttpCoursesApi};
use cgc_platform::api::GraphqlClient;
use gpui_kit::test::{TestQueryExt, TestWindowExt};
use gpui_kit::{AppContext, TestAppContext};
use serde_json::{json, Value};
use std::{
    io::Write,
    net::TcpListener,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
};

struct OwnershipServer {
    endpoint: String,
    stop: Arc<AtomicBool>,
    worker: Option<std::thread::JoinHandle<()>>,
}

impl OwnershipServer {
    fn new() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}/api/graphql", listener.local_addr().unwrap());
        listener.set_nonblocking(true).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let worker = std::thread::spawn(move || {
            while !stopped.load(Ordering::Relaxed) {
                let (mut stream, _) = match listener.accept() {
                    Ok(connection) => connection,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(std::time::Duration::from_millis(1));
                        continue;
                    }
                    Err(error) => panic!("HTTP fixture accept: {error}"),
                };
                stream.set_nonblocking(false).unwrap();
                let request = read_graphql_request(&mut stream);
                let query = request["query"].as_str().unwrap();
                let filters = &request["variables"]["filter"];
                let response = if query.contains("query CourseWorkspaces(") {
                    let allowed = filters["workspaceId"]["in"]
                        .as_array()
                        .is_some_and(|ids| ids.contains(&json!("ws-beta")));
                    let requested = filters["id"]["in"]
                        .as_array()
                        .is_some_and(|ids| ids.contains(&json!("crs-001")));
                    let rows = if allowed && requested {
                        vec![json!({"id":"crs-001","workspaceId":"ws-beta"})]
                    } else {
                        vec![]
                    };
                    json!({"data":{"listCourses":{"results":rows}}})
                } else if query.contains("query ListCourses(") {
                    if request["variables"]["includeWorkspaceId"] != false {
                        json!({"errors":[{"message":"forbidden field"}]})
                    } else {
                        json!({"data":{"listCourses":{"count":2,"endKeyset":null,"results":[
                            {"id":"crs-001","title":"Beta course","status":"open"},
                            {"id":"crs-unknown","title":"Other public course","status":"open"}
                        ]}}})
                    }
                } else if query.contains("query GetCourse(") {
                    json!({"data":{"getCourse":{
                        "id":"crs-001","title":"Beta course","status":"open","visibility":"public",
                        "enrollmentPolicy":"open","pricingEnabled":false,"availablePriceTiers":[]
                    }}})
                } else if query.contains("query MyEnrollment(") {
                    json!({"data":{"myEnrollment":Value::Null}})
                } else if query.contains("query CourseLearning(") {
                    json!({"data":{"courseLearningDetail":Value::Null}})
                } else {
                    panic!("unexpected ownership operation");
                }
                .to_string();
                write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{response}", response.len()).unwrap();
            }
        });
        Self {
            endpoint,
            stop,
            worker: Some(worker),
        }
    }

    fn api(&self) -> Arc<HttpCoursesApi> {
        Arc::new(HttpCoursesApi::new(GraphqlClient::new(
            self.endpoint.clone(),
        )))
    }
}

impl Drop for OwnershipServer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        let result = self.worker.take().unwrap().join();
        if !std::thread::panicking() {
            result.unwrap();
        }
    }
}

#[gpui_kit::test]
fn public_http_catalog_preserves_accessible_workspace_badges_without_exposing_other_owners(
    cx: &mut TestAppContext,
) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    let server = OwnershipServer::new();
    let (window, root) = root_window(cx, "/courses");
    root.update(cx, |root, cx| {
        root.courses = CourseCatalogService::new(server.api());
        root.start_courses_load(cx, true);
    });
    cx.run_until_parked();
    cx.update_window(window, |_, window, cx| {
        window.render_frame(cx);
        assert!(window
            .within("course-row-crs-001")
            .find_by_label("所属工作区 · Beta")
            .visible());
        let other = window.within("course-row-crs-unknown");
        assert!(other.try_find_by_label("所属工作区 · Alpha").is_none());
        assert!(other.try_find_by_label("所属工作区 · Beta").is_none());
    })
    .unwrap();
}

#[gpui_kit::test]
fn unregistered_member_can_open_the_owned_workspace_from_http_course_detail(
    cx: &mut TestAppContext,
) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    let server = OwnershipServer::new();
    let (window, root) = root_window(cx, "/courses/crs-001");
    root.update(cx, |root, cx| {
        root.course_detail = CourseDetailService::new(server.api());
        root.start_course_detail_load(cx, "crs-001".into());
    });
    cx.run_until_parked();
    cx.update_window(window, |_, window, cx| {
        window.render_frame(cx);
        assert!(window.find_by_label("所属工作区 · Beta").visible());
        window.click("course-open-workspace", cx);
    })
    .unwrap();
    cx.update_window(window, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(root.read(cx).workspaces.current_id(), Some("ws-beta"));
        assert_eq!(
            root.read(cx)
                .current_match()
                .unwrap()
                .params
                .get("id")
                .map(String::as_str),
            Some("crs-001")
        );
    })
    .unwrap();
}
