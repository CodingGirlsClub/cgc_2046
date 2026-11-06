//! issue #1238：后台不可达时，GraphQL 失败必须落进 `app.log`。
//!
//! 走生产链路：真实文件 logger（`cgc_platform::logging`，含脱敏） + 真实 HTTP
//! 客户端打一个已关闭的端口。用户双击 `.app` 启动时 stderr 不可见，这是唯一取证口。

use std::time::{SystemTime, UNIX_EPOCH};

use cgc_platform::api::GraphqlClient;
use cgc_platform::logging;
use cgc_platform::workspace::{HttpWorkspaceApi, WorkspaceApi};

fn closed_port() -> u16 {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind probe port");
    let port = listener.local_addr().expect("probe addr").port();
    drop(listener);
    port
}

#[test]
fn unreachable_backend_writes_a_diagnosable_line_to_app_log() {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock")
        .as_nanos();
    let data_root = std::env::temp_dir().join(format!(
        "cgc-api-failure-log-{}-{stamp}",
        std::process::id()
    ));
    std::fs::create_dir_all(&data_root).expect("step 1: temp data root");
    let log_path = logging::init(&data_root).expect("step 1: file logger");

    let endpoint = format!("http://127.0.0.1:{}/api/graphql", closed_port());
    let token = "opaque-session-token-abc123";
    let api = HttpWorkspaceApi::new(GraphqlClient::new(endpoint.clone()));
    api.list_workspaces(Some(token))
        .expect_err("step 2: closed port must fail");

    let logged = std::fs::read_to_string(&log_path).expect("step 3: read app.log");
    assert!(
        logged.contains("MeWorkspaces"),
        "step 3: log must name the operation:\n{logged}"
    );
    assert!(
        logged.contains(&endpoint),
        "step 3: log must name the endpoint:\n{logged}"
    );
    assert!(
        logged.contains("WARN"),
        "step 3: failure is a warning, not silence:\n{logged}"
    );
    assert!(
        !logged.contains(token),
        "step 4: the bearer token must never reach app.log:\n{logged}"
    );

    let _ = std::fs::remove_dir_all(&data_root);
}
