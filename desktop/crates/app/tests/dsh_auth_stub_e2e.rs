//! P3 stub e2e：session/new 的 -32000 auth_required 必须映射成结构化 AuthRequired，
//! 并保留 adapter 广告的 authMethods。真实 adapter 版本见 `dsh_auth_e2e.rs`。

use std::sync::Arc;
use std::time::{Duration, Instant};

use agent_client_protocol::schema::v1::{
    AgentCapabilities, InitializeRequest, InitializeResponse, NewSessionRequest,
};
use agent_client_protocol::schema::ProtocolVersion;
use agent_client_protocol::{on_receive_request, Agent};
use cgc_platform::acp::connection::{AcpHost, AcpHostConfig, HostEvent};

#[test]
fn auth_required_keeps_methods_and_does_not_log_key() {
    let mcp_seen = Arc::new(std::sync::Mutex::new(Vec::new()));
    let agent = Agent
        .builder()
        .name("stub-auth")
        .on_receive_request(
            async |_request: InitializeRequest, responder, _cx| {
                responder.respond(
                    InitializeResponse::new(ProtocolVersion::V1)
                        .agent_capabilities(AgentCapabilities::new()),
                )
            },
            on_receive_request!(),
        )
        .on_receive_request(
            async move |request: NewSessionRequest, responder, _cx| {
                *mcp_seen.lock().expect("mcp seen") = request.mcp_servers.clone();
                let error = agent_client_protocol::Error::auth_required().data(serde_json::json!({
                    "authMethods": [
                        {"id": "api-key", "name": "DeepSeek API Key", "description": "paste a key"},
                        {"id": "terminal", "name": "dsh-acp login", "type": "terminal"}
                    ]
                }));
                responder.respond_with_error(error)
            },
            on_receive_request!(),
        );
    let cwd = std::env::temp_dir().join(format!("cgc-dsh-auth-stub-{}", std::process::id()));
    std::fs::create_dir_all(&cwd).expect("cwd");
    let host = AcpHost::start_in_process(AcpHostConfig::new("", cwd), agent).expect("start host");
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut seen = None;
    while Instant::now() < deadline {
        let Some(event) = host.recv_timeout(Duration::from_millis(100)) else {
            continue;
        };
        match event {
            HostEvent::AuthRequired {
                message,
                auth_methods,
            } => {
                seen = Some((message, auth_methods));
                break;
            }
            HostEvent::Error { message } => panic!("expected AuthRequired, got Error: {message}"),
            HostEvent::Exited => break,
            _ => {}
        }
    }
    host.shutdown();
    let (message, methods) = seen.expect("AuthRequired event");
    assert!(!message.contains("sk-"));
    assert_eq!(methods.len(), 2);
    assert_eq!(methods[0].id, "api-key");
    assert_eq!(methods[0].name, "DeepSeek API Key");
    assert_eq!(methods[1].kind, "terminal");
}
