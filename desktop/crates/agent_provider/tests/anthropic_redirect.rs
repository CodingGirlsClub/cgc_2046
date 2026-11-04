use cgc_agent_provider::{
    AnthropicCompatibleConfig, AnthropicCompatibleProvider, Message, Model, ModelLimits, Provider,
    ProviderId, Request,
};
use futures::StreamExt;
use std::{
    io::{BufRead, BufReader, Read, Write},
    net::{TcpListener, TcpStream},
    sync::mpsc,
    thread,
    time::Duration,
};

fn read_request(socket: TcpStream) -> (TcpStream, String) {
    socket
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut reader = BufReader::new(socket);
    let mut headers = String::new();
    loop {
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        if line == "\r\n" {
            break;
        }
        assert!(!line.is_empty(), "request ended before headers");
        headers.push_str(&line);
    }
    let length = headers
        .lines()
        .find_map(|line| {
            line.to_ascii_lowercase()
                .strip_prefix("content-length:")
                .map(|value| value.trim().parse::<u64>().unwrap())
        })
        .unwrap_or(0);
    assert_eq!(
        std::io::copy(&mut reader.by_ref().take(length), &mut std::io::sink()).unwrap(),
        length
    );
    (reader.into_inner(), headers)
}

#[test]
fn redirect_cannot_send_provider_key_to_another_origin() {
    let origin = TcpListener::bind("127.0.0.1:0").unwrap();
    let target = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin_address = origin.local_addr().unwrap();
    let target_address = target.local_addr().unwrap();
    target.set_nonblocking(true).unwrap();
    let (stop, stopped) = mpsc::channel();
    let origin_task = thread::spawn(move || {
        let (socket, _) = origin.accept().unwrap();
        let (mut socket, headers) = read_request(socket);
        write!(socket, "HTTP/1.1 302 Found\r\nLocation: http://localhost:{}/collect\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", target_address.port()).unwrap();
        headers
    });
    let target_task = thread::spawn(move || loop {
        match target.accept() {
            Ok((socket, _)) => {
                let (mut socket, headers) = read_request(socket);
                let frames = concat!(
                    "data: {\"type\":\"message_start\",\"message\":{\"usage\":{}}}\n\n",
                    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n",
                    "data: {\"type\":\"message_stop\"}\n\n"
                );
                write!(socket, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{frames}", frames.len()).unwrap();
                break Some(headers);
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                match stopped.recv_timeout(Duration::from_millis(10)) {
                    Err(mpsc::RecvTimeoutError::Timeout) => {}
                    _ => break None,
                }
            }
            Err(error) => panic!("accept redirect: {error}"),
        }
    });
    let model = Model::new(
        ProviderId::new("review"),
        "Review",
        "review",
        "Review",
        ModelLimits::new(8_000, 1_000),
    );
    let provider = AnthropicCompatibleProvider::new(AnthropicCompatibleConfig::new(
        format!("http://{origin_address}"),
        "synthetic-review-key",
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
    let _ = stop.send(());
    let original_headers = origin_task.join().unwrap();
    let redirected_headers = target_task.join().unwrap();
    assert!(original_headers.to_ascii_lowercase().lines().any(|line| {
        line.strip_prefix("x-api-key:")
            .is_some_and(|value| value.trim() == "synthetic-review-key")
    }));
    assert!(
        redirected_headers.is_none(),
        "request reached an unauthorized origin"
    );
    assert!(
        events.iter().any(Result::is_err),
        "redirect must be reported as a failed request"
    );
}
