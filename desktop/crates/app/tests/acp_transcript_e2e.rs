//! ACP transcript 本地库 e2e（Stage 3.3）：fake ACP agent 跑一轮 → 经共享模型
//! 序列化落 conversations.db → 重载历史 → 离线打开内容 → 标题/override → 删除/清空。

use std::time::{Duration, Instant};

use agent_client_protocol::schema::v1::{
    AgentCapabilities, ContentBlock, ContentChunk, InitializeRequest, InitializeResponse,
    NewSessionRequest, NewSessionResponse, PromptRequest, PromptResponse, SessionId,
    SessionInfoUpdate, SessionNotification, SessionUpdate, StopReason, TextContent,
};
use agent_client_protocol::schema::ProtocolVersion;
use agent_client_protocol::{on_receive_request, Agent, Client, ConnectTo};
use cgc_agent_store::{ConversationStore, SidebarThread, CONVERSATIONS_DB};
use cgc_agent_ui::conversation::{ConversationThread, Entry};
use cgc_desktop_app::acp_history::{
    merge_history, resume_decision, save_transcript, session_id_from_thread_id, ResumeDecision,
    RESUMED_WITHOUT_HISTORY,
};
use cgc_desktop_app::agent_ingest::apply_thread_event;
use cgc_platform::acp::connection::{AcpHost, AcpHostConfig, HostEvent};

fn temp_dir(tag: &str) -> std::path::PathBuf {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let serial = COUNTER.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!(
        "cgc-acp-transcript-{}-{tag}-{serial}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("dir");
    dir
}

const STUB_SESSION: &str = "stub-transcript-session";

fn stub_agent() -> impl ConnectTo<Client> + 'static {
    Agent
        .builder()
        .name("stub-acp")
        .on_receive_request(
            async |_req: InitializeRequest, responder, _cx| {
                responder.respond(
                    InitializeResponse::new(ProtocolVersion::V1)
                        .agent_capabilities(AgentCapabilities::new()),
                )
            },
            on_receive_request!(),
        )
        .on_receive_request(
            async |_req: NewSessionRequest, responder, _cx| {
                responder.respond(NewSessionResponse::new(SessionId::new(STUB_SESSION)))
            },
            on_receive_request!(),
        )
        .on_receive_request(
            async |_req: PromptRequest, responder, cx| {
                let connection = cx.clone();
                cx.spawn(async move {
                    let session = SessionId::new(STUB_SESSION);
                    connection.send_notification(SessionNotification::new(
                        session.clone(),
                        SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(
                            TextContent::new("hi from acp"),
                        ))),
                    ))?;
                    // agent 生成标题（ACP SessionInfoUpdate → HostEvent::TitleUpdated）
                    connection.send_notification(SessionNotification::new(
                        session,
                        SessionUpdate::SessionInfoUpdate(
                            SessionInfoUpdate::new().title("ACP 生成标题".to_string()),
                        ),
                    ))?;
                    responder.respond(PromptResponse::new(StopReason::EndTurn))
                })?;
                Ok(())
            },
            on_receive_request!(),
        )
}

fn wait_ready(host: &AcpHost) -> (String, Vec<HostEvent>) {
    let mut events = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if let Some(event) = host.recv_timeout(Duration::from_millis(50)) {
            let session_id = match &event {
                HostEvent::Ready { session_id, .. } => Some(session_id.clone()),
                _ => None,
            };
            events.push(event);
            if let Some(session_id) = session_id {
                return (session_id, events);
            }
        }
    }
    panic!("host not ready");
}

/// 跑一轮并把共享会话模型（同一份 ingestion）跑出来。
fn run_turn(host: &AcpHost) -> ConversationThread {
    assert!(host.prompt("hello"));
    let mut thread = ConversationThread::new("acp");
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        let Some(event) = host.recv_timeout(Duration::from_millis(50)) else {
            continue;
        };
        let turn_end = matches!(event, HostEvent::TurnEnd { .. });
        apply_thread_event(&mut thread, &event);
        if turn_end {
            return thread;
        }
    }
    panic!("turn did not finish");
}

#[test]
fn acp_session_saved_reloaded_opened_and_deleted_with_titles() {
    let host = AcpHost::start_in_process(AcpHostConfig::new("", temp_dir("host")), stub_agent())
        .expect("start host");
    let (session_id, _events) = wait_ready(&host);
    assert_eq!(session_id, STUB_SESSION);
    let mut thread = run_turn(&host);
    // 首条用户消息由客户端在发 prompt 时落行（真实 UI 会调用 apply_user_turn），
    // 这里补上以验证 fallback 标题。
    cgc_desktop_app::agent_ingest::apply_user_turn(&mut thread, "hello");
    host.shutdown();

    // ---- 保存：内容 + metadata（session_id 取 ACP session id，agent_id 取外部 agent） ----
    let dir = temp_dir("store");
    let mut store = ConversationStore::open(dir.join(CONVERSATIONS_DB)).expect("store");
    let now = cgc_agent_store::now_utc_rfc3339();
    let sidebar = save_transcript(&mut store, &thread, &session_id, "omp", None, &now)
        .expect("save transcript");
    assert_eq!(sidebar.thread_id, "acp-stub-transcript-session");
    assert_eq!(sidebar.session_id.as_deref(), Some(STUB_SESSION));
    assert_eq!(sidebar.agent_id.as_deref(), Some("omp"));
    assert_eq!(
        sidebar.title.as_deref(),
        Some("ACP 生成标题"),
        "TitleUpdated 写入生成标题"
    );
    assert_eq!(
        store.load_content(&sidebar.thread_id).expect("load"),
        Some(thread.clone()),
        "重启后可按本地内容离线恢复（序列化无损）"
    );

    // ---- 用户重命名 override 优先；后续生成标题更新不覆盖 ----
    store
        .set_title_override(&sidebar.thread_id, Some("用户重命名"))
        .expect("override");
    let mut updated = thread.clone();
    updated.title = Some("新的生成标题".to_string());
    let now2 = cgc_agent_store::now_utc_rfc3339();
    let sidebar = save_transcript(
        &mut store,
        &updated,
        &session_id,
        "omp",
        Some("用户重命名"),
        &now2,
    )
    .expect("save again");
    assert_eq!(sidebar.title.as_deref(), Some("新的生成标题"));
    assert_eq!(
        sidebar.display_title(),
        Some("用户重命名"),
        "列表展示 override 优先"
    );

    // ---- 重载历史（统一列表：native 空 + ACP 一条） ----
    let listed = store.list_sidebar(20).expect("list");
    let merged = merge_history(Vec::new(), listed.clone());
    assert_eq!(merged.len(), 1);
    assert_eq!(merged[0].title.as_deref(), Some("用户重命名"));
    assert_eq!(merged[0].agent_label(), "omp");
    assert_eq!(
        session_id_from_thread_id(&merged[0].thread_id),
        Some(STUB_SESSION)
    );

    // ---- 打开：离线内容可读（不依赖 agent 在线） ----
    let reopened = store.load_content(&sidebar.thread_id).expect("reload");
    assert!(reopened.is_some());
    assert!(reopened.as_ref().is_some_and(|thread| thread
        .entries
        .iter()
        .any(|entry| matches!(entry, Entry::Assistant { .. }))));

    // ---- resume 降级判定（协议层可恢复性由 agent 决定） ----
    assert_eq!(
        resume_decision(true, true, false),
        ResumeDecision::KeepLocalRecord
    );
    assert!(!RESUMED_WITHOUT_HISTORY.is_empty());

    // ---- 删除 + 清空 ----
    assert!(store.delete_thread(&sidebar.thread_id).expect("delete"));
    assert!(store.list_sidebar(20).expect("list").is_empty());
    for (id, at) in [
        ("acp-a", "2026-10-26T12:00:00Z"),
        ("acp-b", "2026-10-26T12:01:00Z"),
    ] {
        let meta = SidebarThread {
            thread_id: id.to_string(),
            agent_id: Some("codex".to_string()),
            session_id: Some(id.trim_start_matches("acp-").to_string()),
            title: Some("t".to_string()),
            title_override: None,
            created_at: at.to_string(),
            updated_at: at.to_string(),
            archived: false,
        };
        store.save_thread(&thread, &meta).expect("save");
    }
    assert_eq!(store.clear_all().expect("clear"), 2);
    assert!(store.list_sidebar(20).expect("list").is_empty());
    let _ = std::fs::remove_dir_all(&dir);
}
