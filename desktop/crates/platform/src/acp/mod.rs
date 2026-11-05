//! ACP 协议与线程抽象（Zed `acp_thread` 的角色）：连接、会话、权限/elicitation 桥、内容分片。

use std::time::Duration;

pub mod connection;
pub mod permission;
mod process;
pub mod session;
fn sleep(duration: Duration) -> impl std::future::Future<Output = ()> {
    let (sender, receiver) = futures::channel::oneshot::channel();
    std::thread::spawn(move || {
        std::thread::sleep(duration);
        let _ = sender.send(());
    });
    async move {
        let _ = receiver.await;
    }
}
