use super::{body, start_request, AnthropicCompatibleConfig};
use crate::{Content, Message, Model, ModelLimits, ProviderId, Request};
use std::{
    io::{BufRead, BufReader, Read},
    net::TcpListener,
    sync::{mpsc, Arc},
    thread,
    time::Duration,
};

#[test]
fn dropping_a_blocked_upload_stops_worker_before_peer_resumes() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let (ready_tx, ready_rx) = mpsc::channel();
    let (resume_tx, resume_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let (socket, _) = listener.accept().unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(3)))
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
        ready_tx.send(length.unwrap()).unwrap();
        resume_rx.recv_timeout(Duration::from_secs(8)).unwrap();
        let mut buffer = [0; 65536];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(_) => {}
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::ConnectionAborted
                    ) =>
                {
                    break
                }
                Err(error) => panic!("cancelled connection did not close: {error}"),
            }
        }
    });
    let model = Model::new(
        ProviderId::new("test"),
        "Test",
        "model",
        "Model",
        ModelLimits::new(32000, 4096),
    );
    let mut message = Message::user("synthetic upload");
    message.content.push(Content::Image {
        mime_type: "image/png".into(),
        data: "A".repeat(32 * 1024 * 1024),
    });
    let body = body::build_body(&model, &Request::new(vec![message])).unwrap();
    let config = Arc::new(AnthropicCompatibleConfig::new(
        format!("http://{address}"),
        "test-key",
        vec![model],
    ));
    let (stream, worker) = start_request(config, body).unwrap();
    assert!(ready_rx.recv_timeout(Duration::from_secs(5)).unwrap() > 32 * 1024 * 1024);
    thread::sleep(Duration::from_millis(500));
    drop(stream);
    let (finished_tx, finished_rx) = mpsc::channel();
    let monitor = thread::spawn(move || {
        let _ = finished_tx.send(worker.join());
    });
    let stopped_while_peer_paused = finished_rx.recv_timeout(Duration::from_secs(2));
    resume_tx.send(()).unwrap();
    server.join().unwrap();
    monitor.join().unwrap();
    assert!(
        stopped_while_peer_paused.is_ok(),
        "dropping the stream must stop the blocked worker while the server is still not reading"
    );
    stopped_while_peer_paused.unwrap().unwrap();
}
