use super::*;
use cgc_agent_tools::{AgentState, ToolContext};
use futures::executor::block_on;
use std::sync::{Arc, Mutex};

fn host() -> NativePanelHost {
    NativePanelHost::new(Arc::new(Mutex::new(AgentState::default())), None)
}

fn lease(epoch: u64) -> LearningHostLease {
    LearningHostLease {
        token: "synthetic-lease".into(),
        token_id: "synthetic-id".into(),
        epoch,
    }
}

fn spawn_mcp_mock(responses: Vec<&'static str>) -> (String, std::sync::mpsc::Receiver<String>) {
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::mpsc;
    use std::time::Duration;
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().expect("addr");
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        for body in responses {
            let Ok((mut stream, _)) = listener.accept() else {
                break;
            };
            let mut buffer = [0u8; 4096];
            let mut request = Vec::new();
            let mut content_length = 0usize;
            let mut header_end = None;
            while let Ok(read) = stream.read(&mut buffer) {
                if read == 0 {
                    break;
                }
                request.extend_from_slice(&buffer[..read]);
                if header_end.is_none() {
                    if let Some(position) = request.windows(4).position(|w| w == b"\r\n\r\n") {
                        header_end = Some(position + 4);
                        let headers = String::from_utf8_lossy(&request[..position]).to_string();
                        content_length = headers
                            .lines()
                            .find_map(|line| {
                                let (name, value) = line.split_once(':')?;
                                name.eq_ignore_ascii_case("content-length")
                                    .then(|| value.trim().parse::<usize>().ok())
                                    .flatten()
                            })
                            .unwrap_or(0);
                        if content_length == 0 {
                            let _ = stream.set_read_timeout(Some(Duration::from_millis(200)));
                        }
                    }
                }
                if let Some(end) = header_end {
                    if content_length > 0 && request.len() >= end + content_length {
                        break;
                    }
                }
            }
            let _ = sender.send(String::from_utf8_lossy(&request).to_string());
            let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
            let _ = stream.write_all(response.as_bytes());
            let _ = stream.flush();
        }
    });
    (format!("http://{addr}/mcp"), receiver)
}

fn init_body() -> &'static str {
    r#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"cgc"}}}"#
}

fn tools_body() -> &'static str {
    r#"{"jsonrpc":"2.0","id":2,"result":{"tools":[
            {"name":"get_course_revision","inputSchema":{"type":"object"}},
            {"name":"get_learning_state","inputSchema":{"type":"object"}},
            {"name":"get_role_playbook","inputSchema":{"type":"object"}},
            {"name":"get_enrollment_summary","inputSchema":{"type":"object"}},
            {"name":"delete_everything","inputSchema":{"type":"object"}}
        ]}}"#
}

fn context(endpoint: &str, epoch: u64) -> McpContext {
    let api_url = format!("{}/api/graphql", endpoint.trim_end_matches("/mcp"));
    McpContext::for_lease(lease(epoch), epoch, Some(&api_url), Some("workspace-one")).unwrap()
}

#[test]
fn authorization_removal_revokes_captured_clients_without_inventing_server_tools() {
    let (endpoint, requests) = spawn_mcp_mock(vec![
        init_body(),
        tools_body(),
        r#"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"authorized learning state"}]}}"#,
    ]);
    let mut host = host();
    assert!(host.mcp_context().is_none());
    let context = context(&endpoint, 7);
    host.set_mcp_context(Some(context));
    let tools = host.mcp_context().unwrap().discover_tools().unwrap();
    let tool = tools
        .iter()
        .find(|tool| tool.name() == "mcp_cgc-2046-learning_get_learning_state")
        .cloned()
        .unwrap();
    assert_eq!(
        tools.len(),
        4,
        "only this fixture's authorized subset is exposed"
    );
    assert!(!tools
        .iter()
        .any(|tool| tool.name().ends_with("get_course_content")));
    assert!(!tools
        .iter()
        .any(|tool| tool.name().ends_with("delete_everything")));
    let result = block_on(tool.run(serde_json::json!({}), ToolContext::new("/tmp"))).unwrap();
    assert_eq!(result.content, "authorized learning state");
    for _ in 0..2 {
        requests.recv().unwrap();
    }
    assert!(requests.recv().unwrap().contains("workspace-one"));

    host.set_mcp_context(None);

    assert!(host.mcp_context().is_none());
    assert!(matches!(
        tool.approval(&serde_json::json!({})),
        cgc_agent_tools::Approval::Deny(_)
    ));
    assert!(
        block_on(tool.run(serde_json::json!({}), ToolContext::new("/tmp")))
            .unwrap()
            .is_error
    );
}

#[test]
fn reinstalling_the_same_authority_does_not_revoke_its_captured_tools() {
    let (endpoint, _) = spawn_mcp_mock(vec![
        init_body(),
        tools_body(),
        r#"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"still authorized"}]}}"#,
    ]);
    let context = context(&endpoint, 8);
    let mut host = host();
    host.set_mcp_context(Some(context.clone()));
    let tools = host.mcp_context().unwrap().discover_tools().unwrap();
    host.set_mcp_context(Some(context));
    let tool = tools
        .iter()
        .find(|tool| tool.name().ends_with("get_learning_state"))
        .unwrap();
    let result = block_on(tool.run(serde_json::json!({}), ToolContext::new("/tmp"))).unwrap();
    assert!(!result.is_error);
    assert_eq!(result.content, "still authorized");
}

#[test]
fn stale_or_empty_leases_never_become_platform_authority() {
    assert!(
        McpContext::for_lease(lease(1), 2, Some("http://127.0.0.1:1/api/graphql"), None).is_none()
    );
    let mut empty = lease(2);
    empty.token.clear();
    assert!(
        McpContext::for_lease(empty, 2, Some("http://127.0.0.1:1/api/graphql"), None).is_none()
    );
}
