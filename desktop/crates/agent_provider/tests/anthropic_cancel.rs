use cgc_agent_provider::{
    AnthropicCompatibleConfig, AnthropicCompatibleProvider, CompletionEvent, Message, Model,
    ModelLimits, Provider, ProviderId, Request, StopReason,
};
use futures::StreamExt;
use std::{
    io::{BufRead, BufReader, Read, Write},
    net::{TcpListener, TcpStream},
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};

fn read_request(socket: TcpStream) -> TcpStream {
    socket
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut reader = BufReader::new(socket);
    let mut length = None;
    loop {
        let mut line = String::new();
        assert!(reader.read_line(&mut line).unwrap() > 0);
        if line == "\r\n" {
            break;
        }
        if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
            length = Some(value.trim().parse::<usize>().unwrap());
        }
    }
    let mut body = vec![0; length.unwrap()];
    reader.read_exact(&mut body).unwrap();
    reader.into_inner()
}

fn drop_stream_closes_connection(heartbeats: bool) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let (ready_tx, ready_rx) = mpsc::channel();
    let (closed_tx, closed_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let (socket, _) = listener.accept().unwrap();
        let mut socket = read_request(socket);
        socket
            .set_read_timeout(Some(Duration::from_millis(100)))
            .unwrap();
        socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"cancel-test\",\"usage\":{}}}\n\n").unwrap();
        if heartbeats {
            socket.write_all(b"data: {\"type\":\"ping\"}\n\n").unwrap();
        }
        ready_tx.send(()).unwrap();
        let started = Instant::now();
        let mut probe = [0; 1];
        let closed = loop {
            match socket.read(&mut probe) {
                Ok(0) => break true,
                Ok(_) => panic!("unexpected bytes after the request body"),
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
                    ) =>
                {
                    if started.elapsed() > Duration::from_secs(5) {
                        break false;
                    }
                    if heartbeats && socket.write_all(b"data: {\"type\":\"ping\"}\n\n").is_err() {
                        break true;
                    }
                }
                Err(_) => break true,
            }
        };
        let _ = closed_tx.send(closed);
    });
    let model = Model::new(
        ProviderId::new("test"),
        "Test",
        "model",
        "Model",
        ModelLimits::new(32000, 4096),
    );
    let provider = AnthropicCompatibleProvider::new(AnthropicCompatibleConfig::new(
        format!("http://{address}"),
        "test-key",
        vec![model.clone()],
    ));
    let mut stream = futures::executor::block_on(
        provider.stream(&model, Request::new(vec![Message::user("hello")])),
    )
    .unwrap();
    assert!(matches!(
        futures::executor::block_on(stream.next()),
        Some(Ok(CompletionEvent::StartMessage { .. }))
    ));
    ready_rx.recv_timeout(Duration::from_secs(2)).unwrap();
    drop(stream);
    assert!(closed_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("dropping the response stream must close a silent connection"));
    server.join().unwrap();
}

#[test]
fn dropping_stream_closes_a_silent_connection() {
    drop_stream_closes_connection(false);
}

#[test]
fn dropping_stream_closes_a_ping_only_connection() {
    drop_stream_closes_connection(true);
}

#[test]
fn a_live_stream_survives_a_quiet_period() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (socket, _) = listener.accept().unwrap();
        let mut socket = read_request(socket);
        socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"quiet-test\",\"usage\":{}}}\n\n").unwrap();
        socket
            .set_read_timeout(Some(Duration::from_millis(350)))
            .unwrap();
        let quiet = socket.read(&mut [0; 1]).unwrap_err();
        assert!(matches!(
            quiet.kind(),
            std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
        ));
        for frame in [
            serde_json::json!({"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}),
            serde_json::json!({"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"after the quiet period"}}),
            serde_json::json!({"type":"content_block_stop","index":0}),
            serde_json::json!({"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}),
            serde_json::json!({"type":"message_stop"}),
        ] {
            writeln!(socket, "data: {frame}\n").unwrap();
        }
    });
    let model = Model::new(
        ProviderId::new("test"),
        "Test",
        "model",
        "Model",
        ModelLimits::new(32000, 4096),
    );
    let provider = AnthropicCompatibleProvider::new(AnthropicCompatibleConfig::new(
        format!("http://{address}"),
        "test-key",
        vec![model.clone()],
    ));
    let events = futures::executor::block_on(async {
        provider
            .stream(&model, Request::new(vec![Message::user("hello")]))
            .await
            .unwrap()
            .collect::<Vec<_>>()
            .await
    });
    let events = events
        .into_iter()
        .collect::<Result<Vec<_>, _>>()
        .expect("a quiet period must not end a live response");
    assert!(events.iter().any(
        |event| matches!(event, CompletionEvent::Text(text) if text == "after the quiet period")
    ));
    assert_eq!(
        events.last(),
        Some(&CompletionEvent::Stop(StopReason::EndTurn))
    );
    server.join().unwrap();
}
