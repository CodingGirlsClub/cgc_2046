//! ACP host shutdown must leave the connection loop even while a prompt is pending.
use std::sync::mpsc;
use std::time::Duration;

use agent_client_protocol::schema::v1::{
    InitializeRequest, InitializeResponse, NewSessionRequest, NewSessionResponse, PromptRequest,
};
use agent_client_protocol::schema::ProtocolVersion;
use agent_client_protocol::{on_receive_request, Agent};
use cgc_platform::acp::connection::{AcpHost, AcpHostConfig, HostEvent};

#[test]
fn shutdown_during_a_pending_turn_joins_the_host_thread() {
    let (started_tx, started_rx) = mpsc::channel();
    let agent = Agent
        .builder()
        .on_receive_request(
            async |_request: InitializeRequest, responder, _cx| {
                responder.respond(InitializeResponse::new(ProtocolVersion::V1))
            },
            on_receive_request!(),
        )
        .on_receive_request(
            async |_request: NewSessionRequest, responder, _cx| {
                responder.respond(NewSessionResponse::new("shutdown-session"))
            },
            on_receive_request!(),
        )
        .on_receive_request(
            async move |_request: PromptRequest, responder, _cx| {
                started_tx.send(()).expect("signal pending prompt");
                // Keep the response pending so Shutdown must be handled inside run_turn.
                std::future::pending::<()>().await;
                drop(responder);
                Ok(())
            },
            on_receive_request!(),
        );
    let host = AcpHost::start_in_process(AcpHostConfig::new("", std::env::temp_dir()), agent)
        .expect("start host");
    assert!(matches!(
        host.recv_timeout(Duration::from_secs(5)),
        Some(HostEvent::Ready { .. })
    ));
    assert!(host.prompt("pending turn"));
    started_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("agent received prompt");

    let (finished_tx, finished_rx) = mpsc::channel();
    let shutdown = std::thread::spawn(move || {
        host.shutdown();
        finished_tx.send(()).expect("signal completed shutdown");
    });
    finished_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("Shutdown consumed by an active turn must also exit the connection loop");
    shutdown.join().expect("shutdown thread panicked");
}
