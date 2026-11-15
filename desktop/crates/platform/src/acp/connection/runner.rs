use super::super::sleep;
use super::auth::{send_auth_required, RequestFailure};
use super::events::{config_option_views, host_event_from_update, permission_option_views};
use super::sessions::{resume_session, send_sessions, session_method_unsupported};
use super::turn::run_turn;
use super::*;
use agent_client_protocol::schema::v1::{
    InitializeRequest, LoadSessionRequest, NewSessionRequest, PermissionOptionKind,
    RequestPermissionOutcome, RequestPermissionRequest, RequestPermissionResponse,
    SelectedPermissionOutcome, SessionConfigId, SessionConfigOptionValue, SessionConfigValueId,
    SessionId, SessionNotification, SetSessionConfigOptionRequest,
};
use agent_client_protocol::schema::ProtocolVersion;
use agent_client_protocol::{
    on_receive_notification, on_receive_request, AcpAgent, Agent, Client, ConnectionTo,
    DynConnectTo,
};
use futures::channel::mpsc::UnboundedReceiver;
use futures::StreamExt;
use std::str::FromStr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::SyncSender;
use std::time::Duration;

pub(super) fn run_thread(
    config: AcpHostConfig,
    transport: HostTransport,
    command_rx: UnboundedReceiver<HostCommand>,
    events: SyncSender<HostEvent>,
    pending_permissions: PendingPermissions,
) {
    let result = futures::executor::block_on(run_connection(
        config,
        transport,
        command_rx,
        events.clone(),
        pending_permissions,
    ));
    if let Err(message) = result {
        send_event(&events, HostEvent::Error { message });
    }
    send_event(&events, HostEvent::Exited);
}

fn send_event(events: &SyncSender<HostEvent>, event: HostEvent) {
    // 有界通道：满了就阻塞后台线程（背压），不静默丢弃增量。
    let _ = events.send(event);
}

async fn run_connection(
    config: AcpHostConfig,
    transport: HostTransport,
    mut command_rx: UnboundedReceiver<HostCommand>,
    events: SyncSender<HostEvent>,
    pending_permissions: PendingPermissions,
) -> Result<(), String> {
    let (finished_tx, finished_rx) = futures::channel::oneshot::channel();
    let supervised = matches!(transport, HostTransport::Subprocess);
    let finished_rx = supervised.then_some(finished_rx);
    let agent: DynConnectTo<Client> = match transport {
        HostTransport::Subprocess => {
            let parsed = AcpAgent::from_str(&config.command)
                .map_err(|error| format!("agent launch: {error}"))?
                .into_config();
            let mut env = config.env.clone();
            env.extend(parsed.environment().clone());
            DynConnectTo::new(crate::acp::process::ManagedProcess {
                plan: LaunchPlan {
                    program: parsed.command().to_path_buf(),
                    args: parsed.arguments().to_vec(),
                    env,
                    cwd: config.cwd.clone(),
                },
                completion: Some(finished_tx),
            })
        }
        HostTransport::InProcess(agent) => agent,
    };
    let events_for_notifications = events.clone();
    let activity = Arc::new(AtomicU64::new(0));
    let activity_for_notifications = Arc::clone(&activity);
    let events_for_permissions = events.clone();
    let pending_for_permissions = Arc::clone(&pending_permissions);

    let result = Client
        .builder()
        .name("cgc-desktop")
        .on_receive_notification(
            async move |notification: SessionNotification, _cx| {
                let _ = activity_for_notifications.fetch_add(1, Ordering::Relaxed);
                if let Some(event) = host_event_from_update(notification.update) {
                    send_event(&events_for_notifications, event);
                }
                Ok(())
            },
            on_receive_notification!(),
        )
        .on_receive_request(
            async move |request: RequestPermissionRequest, responder, _connection| {
                let counter = PERMISSION_COUNTER.fetch_add(1, Ordering::Relaxed);
                let request_id = format!("perm-{counter}");
                let title = request
                    .tool_call
                    .fields
                    .title
                    .clone()
                    .or_else(|| request.options.first().map(|option| option.name.clone()))
                    .unwrap_or_else(|| "tool approval".to_string());
                let allow_option = request
                    .options
                    .iter()
                    .find(|option| {
                        matches!(
                            option.kind,
                            PermissionOptionKind::AllowOnce | PermissionOptionKind::AllowAlways
                        )
                    })
                    .map(|option| option.option_id.0.to_string());
                let (sender, receiver) = futures::channel::oneshot::channel();
                pending_for_permissions
                    .lock()
                    .expect("pending permissions")
                    .insert(
                        request_id.clone(),
                        PendingPermission {
                            sender,
                            allow_option: allow_option.clone(),
                        },
                    );
                send_event(
                    &events_for_permissions,
                    HostEvent::PermissionRequested {
                        request_id,
                        title,
                        tool_call_id: Some(request.tool_call.tool_call_id.0.to_string()),
                        tool_name: request.tool_call.fields.name.clone(),
                        args: request.tool_call.fields.raw_input.as_ref().map(json_text),
                        options: permission_option_views(&request.options),
                    },
                );
                let timeout = sleep(Duration::from_secs(300));
                futures::pin_mut!(receiver, timeout);
                let choice = match futures::future::select(receiver, timeout).await {
                    futures::future::Either::Left((decision, _)) => decision.unwrap_or(None),
                    futures::future::Either::Right(_) => None,
                };
                let outcome = match choice {
                    Some(option_id) => RequestPermissionOutcome::Selected(
                        SelectedPermissionOutcome::new(option_id),
                    ),
                    None => RequestPermissionOutcome::Cancelled,
                };
                let _ = responder.respond(RequestPermissionResponse::new(outcome));
                Ok(())
            },
            on_receive_request!(),
        )
        .connect_with(agent, async move |connection: ConnectionTo<Agent>| {
            let inner: Result<(), String> = async {
                let init = match with_timeout(
                    connection
                        .send_request(InitializeRequest::new(ProtocolVersion::V1))
                        .block_task(),
                    INIT_TIMEOUT,
                    "initialize",
                )
                .await
                {
                    Ok(init) => init,
                    Err(failure) => {
                        if send_auth_required(&failure, &events) {
                            return Ok(());
                        }
                        return Err(failure.into_message());
                    }
                };
                let agent_name = init
                    .agent_info
                    .as_ref()
                    .map(|info| info.name.clone())
                    .unwrap_or_else(|| config.agent_name.clone());
                let version = init
                    .agent_info
                    .as_ref()
                    .map(|info| info.version.clone())
                    .unwrap_or_default();

                let (session_id, config_options) = if let Some(load_id) = &config.load_session {
                    let request = LoadSessionRequest::new(
                        SessionId::new(load_id.clone()),
                        config.cwd.clone(),
                    )
                    .mcp_servers(config.mcp_servers.clone());
                    match with_timeout(
                        connection.send_request(request).block_task(),
                        INIT_TIMEOUT,
                        "session/load",
                    )
                    .await
                    {
                        Ok(response) => (
                            SessionId::new(load_id.clone()),
                            response.config_options.unwrap_or_default(),
                        ),
                        // 旧 agent 未实现 session/load（-32601）时自动改走
                        // session/resume（同一 session id / cwd）。
                        Err(failure) if session_method_unsupported(&failure) => {
                            match resume_session(&connection, &config, load_id).await {
                                Ok(session) => session,
                                Err(failure) => {
                                    if send_auth_required(&failure, &events) {
                                        return Ok(());
                                    }
                                    return Err(failure.into_message());
                                }
                            }
                        }
                        Err(failure) => {
                            if send_auth_required(&failure, &events) {
                                return Ok(());
                            }
                            return Err(failure.into_message());
                        }
                    }
                } else if let Some(resume_id) = &config.resume_session {
                    match resume_session(&connection, &config, resume_id).await {
                        Ok(session) => session,
                        Err(failure) => {
                            if send_auth_required(&failure, &events) {
                                return Ok(());
                            }
                            return Err(failure.into_message());
                        }
                    }
                } else {
                    let session_request = NewSessionRequest::new(config.cwd.clone())
                        .mcp_servers(config.mcp_servers.clone());
                    let session = match with_timeout(
                        connection.send_request(session_request).block_task(),
                        INIT_TIMEOUT,
                        "session/new",
                    )
                    .await
                    {
                        Ok(session) => session,
                        Err(failure) => {
                            if send_auth_required(&failure, &events) {
                                return Ok(());
                            }
                            return Err(failure.into_message());
                        }
                    };
                    (
                        session.session_id.clone(),
                        session.config_options.unwrap_or_default(),
                    )
                };
                send_event(
                    &events,
                    HostEvent::Ready {
                        agent_name,
                        version,
                        session_id: session_id.to_string(),
                    },
                );
                send_event(
                    &events,
                    HostEvent::ConfigOptions {
                        options: config_option_views(&config_options),
                    },
                );
                if config.list_sessions_after_ready {
                    send_sessions(&connection, &events, &config.cwd).await;
                }

                let mut finished = finished_rx.map(Box::pin);
                loop {
                    let next = match finished.as_mut() {
                        Some(finished) => {
                            let command = command_rx.next();
                            futures::pin_mut!(command);
                            match futures::future::select(finished.as_mut(), command).await {
                                futures::future::Either::Left((finished, _)) => {
                                    return match finished {
                                        Ok(result) => result,
                                        Err(_) => Ok(()),
                                    };
                                }
                                futures::future::Either::Right((command, _)) => command,
                            }
                        }
                        None => command_rx.next().await,
                    };
                    let Some(command) = next else { break };
                    match command {
                        HostCommand::Prompt(text) => {
                            if run_turn(
                                &connection,
                                &mut command_rx,
                                &events,
                                session_id.clone(),
                                text,
                                Arc::clone(&activity),
                                Arc::clone(&pending_permissions),
                            )
                            .await
                            .is_break()
                            {
                                return Ok(());
                            }
                        }
                        HostCommand::Stop => {}
                        HostCommand::ListSessions => {
                            send_sessions(&connection, &events, &config.cwd).await;
                        }
                        HostCommand::SetConfig { config_id, value } => {
                            let request = SetSessionConfigOptionRequest::new(
                                session_id.clone(),
                                SessionConfigId::new(config_id),
                                SessionConfigOptionValue::ValueId {
                                    value: SessionConfigValueId::new(value),
                                },
                            );
                            match with_timeout(
                                connection.send_request(request).block_task(),
                                INIT_TIMEOUT,
                                "session/set_config_option",
                            )
                            .await
                            {
                                Ok(response) => send_event(
                                    &events,
                                    HostEvent::ConfigOptions {
                                        options: config_option_views(&response.config_options),
                                    },
                                ),
                                Err(failure) => {
                                    if !send_auth_required(&failure, &events) {
                                        send_event(
                                            &events,
                                            HostEvent::Error {
                                                message: failure.into_message(),
                                            },
                                        );
                                    }
                                }
                            }
                        }
                        HostCommand::Shutdown => return Ok(()),
                    }
                }
                Ok(())
            }
            .await;
            inner.map_err(|message| agent_client_protocol::Error::internal_error().data(message))
        })
        .await;
    result.map_err(|error| format!("acp connection: {error}"))?;
    Ok(())
}

/// `session/load` 不可用（JSON-RPC -32601 method not found）时是否可降级到 `session/resume`。
pub(super) async fn with_timeout<F, T>(
    future: F,
    timeout: Duration,
    phase: &'static str,
) -> Result<T, RequestFailure>
where
    F: std::future::Future<Output = Result<T, agent_client_protocol::Error>>,
{
    let deadline = sleep(timeout);
    futures::pin_mut!(future, deadline);
    match futures::future::select(future, deadline).await {
        futures::future::Either::Left((result, _)) => {
            result.map_err(|error| RequestFailure::from_error(phase, error))
        }
        futures::future::Either::Right(_) => Err(RequestFailure::timeout(phase)),
    }
}

/// 空闲预算是否真的耗尽：期间只要有过新活动，或正在等用户审批，就应重新计时。
///
/// 审批等待不产生 session/update，但用户可能思考很久；把它算进“模型沉默”
/// 会把正常审批流程误杀（真实复现：60s 后报 `turn timeout`）。
pub(super) fn idle_expired(
    seen_activity: u64,
    current_activity: u64,
    permissions_pending: bool,
) -> bool {
    current_activity == seen_activity && !permissions_pending
}
