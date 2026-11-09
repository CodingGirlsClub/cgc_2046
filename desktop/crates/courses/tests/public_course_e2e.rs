use cgc_courses::catalog::{learning_context, CoursesApi, HttpCoursesApi};
use cgc_platform::api::GraphqlClient;
use serde_json::{json, Value};
use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
};

fn request_body(stream: &mut TcpStream) -> Value {
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(5)))
        .unwrap();
    let mut bytes = Vec::new();
    let mut buffer = [0; 4096];
    let header_end = loop {
        let count = stream.read(&mut buffer).unwrap();
        assert_ne!(count, 0, "complete request headers");
        bytes.extend_from_slice(&buffer[..count]);
        if let Some(end) = bytes.windows(4).position(|part| part == b"\r\n\r\n") {
            break end + 4;
        }
    };
    let length = String::from_utf8_lossy(&bytes[..header_end])
        .lines()
        .find_map(|line| {
            let (name, value) = line.split_once(':')?;
            name.eq_ignore_ascii_case("content-length")
                .then(|| value.trim().parse::<usize>().unwrap())
        })
        .expect("request body length");
    while bytes.len() < header_end + length {
        let count = stream.read(&mut buffer).unwrap();
        assert_ne!(count, 0, "complete request body");
        bytes.extend_from_slice(&buffer[..count]);
    }
    serde_json::from_slice(&bytes[header_end..header_end + length]).unwrap()
}

fn public_course_server(
    enrollment: Result<bool, ()>,
) -> (HttpCoursesApi, std::thread::JoinHandle<()>) {
    let enrolled = enrollment == Ok(true);
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = std::thread::spawn(move || {
        for _ in 0..3 {
            let (mut stream, _) = listener.accept().unwrap();
            let request = request_body(&mut stream);
            let query = request["query"].as_str().unwrap();
            let forbidden = query.contains("query GetCourse(") && query.contains("workspaceId");
            let failed_enrollment = enrollment.is_err() && query.contains("query MyEnrollment(");
            let response = if forbidden {
                json!({"errors":[{"message":"forbidden field","code":"forbidden_field"}]})
            } else if failed_enrollment {
                json!({"errors":[{"message":"enrollment temporarily unavailable","code":"unavailable"}]})
            } else if query.contains("query GetCourse(") {
                json!({"data":{"getCourse":{
                    "id":"course-public", "title":"Public course", "status":"open",
                    "visibility":"public", "enrollmentPolicy":"open", "pricingEnabled":false,
                    "availablePriceTiers":[]
                }}})
            } else if query.contains("query MyEnrollment(") {
                let mut row = if enrolled { json!({"id":"enrollment-own","status":"confirmed"}) } else { Value::Null };
                if enrolled && query.contains("workspaceId") {
                    row["workspaceId"] = json!("workspace-beta");
                }
                json!({"data":{"myEnrollment":row}})
            } else if query.contains("query CourseLearning(") {
                let mut row = if enrolled { json!({"courseId":"course-public", "title":"Public course", "revisionNumber":3}) } else { Value::Null };
                if enrolled && query.contains("workspaceId") {
                    row["workspaceId"] = json!("workspace-beta");
                }
                json!({"data":{"courseLearningDetail":row}})
            } else {
                panic!("unexpected course operation");
            }.to_string();
            write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{response}", response.len()).unwrap();
            if forbidden || failed_enrollment {
                break;
            }
        }
    });
    (
        HttpCoursesApi::new(GraphqlClient::new(format!("http://{address}/api/graphql"))),
        server,
    )
}

#[test]
fn public_course_detail_is_readable_without_workspace_membership() {
    let (api, server) = public_course_server(Ok(false));
    let result = api.get_course(None, "course-public");
    server.join().unwrap();
    let detail = result.expect("public detail must not request protected workspace attributes");
    assert_eq!(detail.title, "Public course");
    assert_eq!(detail.enrollment_status, None);
    assert_eq!(detail.workspace_id, None);
}

#[test]
fn enrolled_nonmember_learning_gets_ownership_from_its_authorized_projection() {
    let (api, server) = public_course_server(Ok(true));
    let result = api.get_course(Some("test-session"), "course-public");
    server.join().unwrap();
    let detail = result.expect("public detail remains readable for enrolled nonmembers");
    assert_eq!(detail.enrollment_status.as_deref(), Some("confirmed"));
    let context =
        learning_context(Some("learner".into()), &detail).expect("authorized learning context");
    assert_eq!(context.workspace_id, "workspace-beta");
    assert_eq!(context.course_id, "course-public");
    assert_eq!(context.course_revision_id, "3");
}

#[test]
fn failed_enrollment_lookup_remains_an_error_instead_of_unenrolled() {
    let (api, server) = public_course_server(Err(()));
    let result = api.get_course(Some("test-session"), "course-public");
    server.join().unwrap();
    assert!(
        matches!(result, Err(cgc_courses::catalog::CoursesError::Server(message))
        if message == "enrollment temporarily unavailable")
    );
}
