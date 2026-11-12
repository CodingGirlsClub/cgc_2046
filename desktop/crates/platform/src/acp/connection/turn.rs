use super::super::sleep;
use super::auth::{send_auth_required, RequestFailure};
use super::runner::idle_expired;
use super::*;
use agent_client_protocol::schema::v1::{
    CancelNotification, ContentBlock, PromptRequest, SessionId, StopReason, TextContent,
};
use agent_client_protocol::Agent;
use agent_client_protocol::ConnectionTo;
use futures::channel::mpsc::UnboundedReceiver;
use futures::StreamExt;
use std::ops::ControlFlow;
use std::sync::atomic::Ordering;

pub(super) async fn run_turn(
    connection: &ConnectionTo<Agent>,
    command_rx: &mut UnboundedReceiver<HostCommand>,
    events: &SyncSender<HostEvent>,
    session_id: SessionId,
    text: String,
    activity: Arc<AtomicU64>,
) -> ControlFlow<()> {
    let prompt = connection
        .send_request(PromptRequest::new(
            session_id.clone(),
            vec![ContentBlock::Text(TextContent::new(text))],
        ))
        .block_task();
    futures::pin_mut!(prompt);
    // 超时按“活跃阶段”计算：只要 agent 仍在推进（任何 session/update），
    // 就重新计满一轮预算；等待用户审批或长工具执行不会把整轮判成超时。
    let mut seen_activity = activity.load(Ordering::Relaxed);
    let mut last_activity_at = std::time::Instant::now();

    loop {
        let command = command_rx.next();
        futures::pin_mut!(command);
        // 先轮询命令（Stop 优先于同时到达的 prompt 响应），否则用户点停止时
        // 若 agent 恰好同刻收尾，TurnEnd 会被误报成 cancelled=false。
        let command_or_prompt = futures::future::select(command, prompt.as_mut());
        futures::pin_mut!(command_or_prompt);
        let idle = sleep(TURN_TIMEOUT.saturating_sub(last_activity_at.elapsed()));
        futures::pin_mut!(idle);
        match futures::future::select(command_or_prompt, idle).await {
            futures::future::Either::Left((
                futures::future::Either::Right((result, _command)),
                _,
            )) => {
                match result {
                    Ok(response) => {
                        let stop_reason = format!("{:?}", response.stop_reason);
                        send_event(
                            events,
                            HostEvent::TurnEnd {
                                cancelled: response.stop_reason == StopReason::Cancelled,
                                stop_reason,
                            },
                        )
                    }
                    Err(error) => {
                        let failure = RequestFailure::from_error("turn", error);
                        if !send_auth_required(&failure, events) {
                            send_event(
                                events,
                                HostEvent::Error {
                                    message: failure.into_message(),
                                },
                            );
                        }
                    }
                }
                break;
            }
            futures::future::Either::Left((
                futures::future::Either::Left((command, _prompt)),
                _,
            )) => match command {
                Some(HostCommand::Stop) => {
                    // 先发 cancel，再等 prompt 响应一个宽限期：in-process native
                    // server 会立刻回 `stopReason: cancelled`，等它回来再收尾
                    // 才不会和 agent 交还状态竞争；外部 agent 不响应也不会卡住。
                    let _ =
                        connection.send_notification(CancelNotification::new(session_id.clone()));
                    let grace = sleep(CANCEL_GRACE);
                    futures::pin_mut!(grace);
                    match futures::future::select(prompt.as_mut(), grace).await {
                        futures::future::Either::Left((Ok(response), _)) => send_event(
                            events,
                            HostEvent::TurnEnd {
                                cancelled: true,
                                stop_reason: format!("{:?}", response.stop_reason),
                            },
                        ),
                        futures::future::Either::Left((Err(_), _)) => send_event(
                            events,
                            HostEvent::TurnEnd {
                                cancelled: true,
                                stop_reason: "cancelled".to_string(),
                            },
                        ),
                        futures::future::Either::Right(_) => {
                            send_event(events, HostEvent::Error {
                                message: "Agent did not confirm cancellation; reconnect before sending another message".into(),
                            });
                            return ControlFlow::Break(());
                        }
                    }
                    break;
                }
                Some(HostCommand::Shutdown) | None => {
                    send_event(
                        events,
                        HostEvent::TurnEnd {
                            cancelled: true,
                            stop_reason: "shutdown".to_string(),
                        },
                    );
                    // Shutdown 已被 turn 消费，必须同时退出外层连接循环。
                    return ControlFlow::Break(());
                }
                Some(HostCommand::Prompt(_))
                | Some(HostCommand::ListSessions)
                | Some(HostCommand::SetConfig { .. }) => {}
            },
            futures::future::Either::Right(_) => {
                let current = activity.load(Ordering::Relaxed);
                if !idle_expired(seen_activity, current) {
                    // 期间有真实进展：重新计一轮空闲预算，而不是把整轮判死。
                    seen_activity = current;
                    last_activity_at = std::time::Instant::now();
                    continue;
                }
                send_event(
                    events,
                    HostEvent::Error {
                        message: "turn timeout".to_string(),
                    },
                );
                break;
            }
        }
    }
    ControlFlow::Continue(())
}
