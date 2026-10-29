//! Story 5.1 的 ACP tracer spike（不进入生产路径）。
//!
//! 用真实本机 agent 验证：stdio 启动 → initialize → session/new → prompt →
//! 流式 session/update 通知到达 → 回合结束。用法：
//! `cargo run -p cgc-platform --example acp_probe -- "omp acp" "你好，回复一句话"`

use std::path::PathBuf;
use std::str::FromStr;

use agent_client_protocol::schema::v1::{
    ContentBlock, InitializeRequest, NewSessionRequest, PromptRequest, SessionNotification,
    SessionUpdate, TextContent,
};
use agent_client_protocol::schema::ProtocolVersion;
use agent_client_protocol::{on_receive_notification, AcpAgent, Agent, Client, ConnectionTo};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let command = args.next().unwrap_or_else(|| "omp acp".to_string());
    let prompt = args
        .next()
        .unwrap_or_else(|| "用一句话介绍你自己".to_string());
    let cwd = std::env::var_os("CGC_ACP_CWD")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));

    let agent = AcpAgent::from_str(&command)?;
    eprintln!("[probe] spawn agent: {command}");

    futures::executor::block_on(async {
        Client
            .builder()
            .name("cgc-desktop-probe")
            .on_receive_notification(
                async move |notification: SessionNotification, _cx| {
                    match &notification.update {
                        SessionUpdate::AgentMessageChunk(chunk) => {
                            if let ContentBlock::Text(text) = &chunk.content {
                                print!("{}", text.text);
                            }
                        }
                        SessionUpdate::ToolCall(call) => {
                            eprintln!("\n[tool] {} ({:?})", call.title, call.kind);
                        }
                        _ => {}
                    }
                    Ok(())
                },
                on_receive_notification!(),
            )
            .connect_with(agent, async move |connection: ConnectionTo<Agent>| {
                let init = connection
                    .send_request(InitializeRequest::new(ProtocolVersion::V1))
                    .block_task()
                    .await?;
                let agent_info = init.agent_info;
                eprintln!(
                    "[probe] initialized: {}",
                    agent_info
                        .as_ref()
                        .map(|info| format!("{} {}", info.name, info.version))
                        .unwrap_or_else(|| "unknown".to_string())
                );

                let session = connection
                    .send_request(NewSessionRequest::new(cwd))
                    .block_task()
                    .await?;
                // 不打印 session_id（CodeQL cleartext-logging）：probe 只需要知道会话已建立。
                eprintln!("[probe] session created");

                let response = connection
                    .send_request(PromptRequest::new(
                        session.session_id,
                        vec![ContentBlock::Text(TextContent::new(prompt))],
                    ))
                    .block_task()
                    .await?;
                eprintln!("\n[probe] turn done: {:?}", response.stop_reason);
                Ok(())
            })
            .await
    })?;

    Ok(())
}
