use super::auth::{send_auth_required, RequestFailure};
use super::runner::with_timeout;
use super::*;
use agent_client_protocol::schema::v1::{
    ListSessionsRequest, ResumeSessionRequest, SessionConfigOption, SessionId,
};
use agent_client_protocol::{Agent, ConnectionTo};
use std::sync::mpsc::SyncSender;

pub(super) fn session_method_unsupported(failure: &RequestFailure) -> bool {
    failure.code == Some(-32601)
        || (failure.code.is_none()
            && failure
                .message
                .to_ascii_lowercase()
                .contains("method not found"))
}

/// 恢复既有会话（`session/resume`，不回放历史通知）。
pub(super) async fn resume_session(
    connection: &ConnectionTo<Agent>,
    config: &AcpHostConfig,
    session_id: &str,
) -> Result<(SessionId, Vec<SessionConfigOption>), RequestFailure> {
    let request =
        ResumeSessionRequest::new(SessionId::new(session_id.to_string()), config.cwd.clone())
            .mcp_servers(config.mcp_servers.clone());
    let response = with_timeout(
        connection.send_request(request).block_task(),
        INIT_TIMEOUT,
        "session/resume",
    )
    .await?;
    Ok((
        SessionId::new(session_id.to_string()),
        response.config_options.unwrap_or_default(),
    ))
}

pub(super) async fn send_sessions(
    connection: &ConnectionTo<Agent>,
    events: &SyncSender<HostEvent>,
    cwd: &std::path::Path,
) {
    let request = ListSessionsRequest::new().cwd(cwd.to_path_buf());
    match with_timeout(
        connection.send_request(request).block_task(),
        INIT_TIMEOUT,
        "session/list",
    )
    .await
    {
        Ok(response) => send_event(
            events,
            HostEvent::Sessions {
                sessions: response
                    .sessions
                    .into_iter()
                    .map(|session| SessionSummary {
                        session_id: session.session_id.to_string(),
                        title: session.title,
                        updated_at: session.updated_at,
                    })
                    .collect(),
            },
        ),
        Err(failure) => {
            if !send_auth_required(&failure, events) {
                // session/list 只是历史辅助数据；失败不能让主对话进入 Failed。
                log::warn!("session/list failed: {}", failure);
                send_event(
                    events,
                    HostEvent::Sessions {
                        sessions: Vec::new(),
                    },
                );
            }
        }
    }
}
