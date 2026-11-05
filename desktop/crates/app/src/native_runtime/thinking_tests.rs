use cgc_agent_core::{Agent, AutoApprover, SelectedModel, Thread};
use cgc_agent_provider::{
    CompletionEvent, Content, FakeProvider, Model, ModelLimits, ProviderId, StopReason,
};
use cgc_agent_store::SessionStore;
use cgc_agent_tools::{ToolContext, ToolRegistry};
use futures::executor::block_on;

#[test]
fn reopening_sqlite_keeps_valid_reasoning_and_remembers_invalidated_signatures() {
    let root = std::env::temp_dir().join(format!("cgc-thinking-store-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&root).unwrap();
    let path = root.join("threads.db");
    let model = Model::new(
        ProviderId::new("test"),
        "Test",
        "m",
        "Model",
        ModelLimits::new(32000, 4096),
    );
    let provider = FakeProvider::new(model.provider_id.clone(), "Test", vec![model.clone()]);
    provider.push_script(vec![
        Ok(CompletionEvent::ContentBlock(Content::Thinking {
            text: "reasoning".into(),
            signature: "original prefix".into(),
        })),
        Ok(CompletionEvent::ContentBlock(Content::Text(
            "original answer".into(),
        ))),
        Ok(CompletionEvent::Text("original answer".into())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    for _ in 0..3 {
        provider.push_script(vec![
            Ok(CompletionEvent::Text("continued".into())),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
        ]);
    }
    let mut agent = Agent::new(
        Thread::new(
            "reasoning",
            SelectedModel::new(model.provider_id.clone(), model.id.clone()),
        ),
        Some("system".into()),
    );
    block_on(agent.prompt(&provider, &model, "first question")).unwrap();
    let mut store = SessionStore::open(&path).unwrap();
    store.save_thread(agent.thread()).unwrap();
    drop(store);
    let mut store = SessionStore::open(&path).unwrap();
    let mut agent = Agent::new(
        store.load_thread("reasoning").unwrap().unwrap(),
        Some("system".into()),
    );
    block_on(agent.prompt(&provider, &model, "same prefix after reopening")).unwrap();
    block_on(agent.prompt_with_tools(
        &provider,
        &model,
        "change tools",
        &ToolRegistry::with_read_tools(),
        &ToolContext::new(&root),
        &AutoApprover,
    ))
    .unwrap();
    store.save_thread(agent.thread()).unwrap();
    drop(store);
    let store = SessionStore::open(&path).unwrap();
    let mut agent = Agent::new(
        store.load_thread("reasoning").unwrap().unwrap(),
        Some("system".into()),
    );
    block_on(agent.prompt(&provider, &model, "original tools after reopening again")).unwrap();
    let requests = provider.requests();
    assert!(
        requests[1]
            .messages
            .iter()
            .flat_map(|message| &message.content)
            .any(Content::is_thinking),
        "SQLite restoration must preserve valid signed history"
    );
    for request in &requests[2..] {
        assert!(
            !request
                .messages
                .iter()
                .flat_map(|message| &message.content)
                .any(Content::is_thinking),
            "an invalidated signature must not return after reopening"
        );
        assert!(request
            .messages
            .iter()
            .any(|message| message.text() == "original answer"));
    }
    assert!(
        agent
            .thread()
            .messages()
            .iter()
            .flat_map(|message| &message.content)
            .any(Content::is_thinking),
        "the persisted original blocks stay intact"
    );
    drop(store);
    std::fs::remove_dir_all(root).unwrap();
}
