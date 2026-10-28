//! 传输层背压：慢消费者不能把整段模型输出无限堆进内存。
//!
//! 做法：本地 SSE 服务端发大量 chunk，客户端只读 1 个事件后停住；
//! 有界通道时 worker 很快被挡住 → 服务端写入量远小于总字节数；
//! 无界通道时 worker 会把整段响应吞进内存 → 服务端几乎能写完全部。
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use cgc_agent_provider::{
    CompletionEvent, Model, ModelLimits, OpenAiCompatibleConfig, OpenAiCompatibleProvider,
    Provider, ProviderId, Request,
};
use futures::StreamExt;

const CHUNK_BYTES: usize = 8 * 1024;
const CHUNKS: usize = 1024;

fn model() -> Model {
    Model::new(
        ProviderId::new("sse"),
        "SSE",
        "m1",
        "m1",
        ModelLimits::new(64_000, 1_000),
    )
}

/// 极简 SSE 服务端：记录实际写给 socket 的字节数。
fn spawn_sse(total_chunks: usize) -> (String, Arc<AtomicUsize>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let address = listener.local_addr().expect("addr");
    let written = Arc::new(AtomicUsize::new(0));
    let counter = Arc::clone(&written);
    std::thread::spawn(move || {
        let Ok((mut socket, _)) = listener.accept() else {
            return;
        };
        let mut buffer = [0u8; 4096];
        let _ = socket.read(&mut buffer);
        let headers =
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n";
        let _ = socket.write_all(headers.as_bytes());
        let _ = counter.fetch_add(headers.len(), Ordering::Relaxed);
        let chunk = format!("\"content\":\"{}\"", "x".repeat(CHUNK_BYTES));
        for _ in 0..total_chunks {
            let frame = format!("data: {{\"choices\":[{{\"delta\":{{{chunk}}}}}]}}\n\n");
            if socket.write_all(frame.as_bytes()).is_err() {
                break;
            }
            let _ = counter.fetch_add(frame.len(), Ordering::Relaxed);
        }
        let done = "data: [DONE]\n\n";
        let _ = socket.write_all(done.as_bytes());
        let _ = counter.fetch_add(done.len(), Ordering::Relaxed);
        // 保持连接片刻：客户端要读到 [DONE] 才收尾，立刻关闭会让底层 read 报 EINVAL。
        std::thread::sleep(Duration::from_millis(300));
    });
    (format!("http://{address}"), written)
}

#[test]
fn a_stalled_consumer_backpressures_the_provider_worker() {
    let (base_url, written) = spawn_sse(CHUNKS);
    let provider = OpenAiCompatibleProvider::new(OpenAiCompatibleConfig::new(
        base_url,
        "test-key",
        vec![model()],
    ));
    let mut stream = futures::executor::block_on(provider.stream(&model(), Request::new(vec![])))
        .expect("stream");

    // 只读第一个事件，然后停住，模拟卡顿的 UI。
    let first = futures::executor::block_on(stream.next());
    assert!(
        matches!(first, Some(Ok(CompletionEvent::Text(_)))),
        "首块应可读"
    );
    std::thread::sleep(Duration::from_millis(1500));

    let stalled = written.load(Ordering::Relaxed);
    let total = CHUNKS * (CHUNK_BYTES + 64);
    assert!(
        stalled < total / 2,
        "慢消费者时 worker 必须被背压挡住：已写 {stalled} / 总计约 {total}"
    );

    // 恢复读取：背压只限流，不丢内容。
    let first_text = match first {
        Some(Ok(CompletionEvent::Text(text))) => text,
        _ => unreachable!(),
    };
    let mut text = first_text;
    for event in futures::executor::block_on(stream.collect::<Vec<_>>()) {
        match event {
            Ok(CompletionEvent::Text(chunk)) => text.push_str(&chunk),
            Ok(CompletionEvent::Stop(_)) => {}
            other => panic!("未预期事件: {other:?}"),
        }
    }
    assert_eq!(text.len(), CHUNKS * CHUNK_BYTES, "背压不得丢任何 delta");
}
