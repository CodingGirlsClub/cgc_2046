use super::*;
use crate::{Agent, SelectedModel};
use cgc_agent_provider::{FakeProvider, ModelId, ModelLimits, ProviderId};

#[test]
fn every_summary_and_completion_stays_within_the_estimated_window() {
    let model = Model::new(
        ProviderId::new("fake"),
        "Fake",
        "small",
        "small",
        ModelLimits::new(800, 100),
    );
    let provider = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model.clone()]);
    let mut thread = Thread::new(
        "bounded-summary",
        SelectedModel::new(ProviderId::new("fake"), ModelId::new("small")),
    );
    for index in 0..20 {
        thread.push_user(format!("question {index}: {}", "x".repeat(300)));
        thread.push_assistant(format!("answer {index}: {}", "y".repeat(300)), vec![], None);
    }
    let mut agent = Agent::new(thread, Some("Teach ownership.".into()));
    futures::executor::block_on(agent.prompt(&provider, &model, "continue")).unwrap();

    for request in provider.requests() {
        let estimated = PROTOCOL_RESERVE
            + request.max_output_tokens.unwrap() as usize
            + request.tools.iter().map(schema_tokens).sum::<usize>()
            + request
                .messages
                .iter()
                .flat_map(|message| &message.content)
                .map(|content| match content {
                    Content::Text(text) => text_tokens(text),
                    _ => panic!("fixture should contain only text"),
                })
                .sum::<usize>();
        assert!(
            estimated <= model.limits.context_window as usize,
            "actual submitted request exceeds its estimated window: {estimated}"
        );
    }
    assert!(agent.thread().entries.iter().any(|entry| matches!(
        entry,
        Entry::Compaction {
            covered_until: Some(_),
            ..
        }
    )));
}

#[test]
fn assemble_applies_temperature_to_the_request() {
    let model = Model::new(
        ProviderId::new("fake"),
        "Fake",
        "small",
        "small",
        ModelLimits::new(800, 100),
    );
    let hot = assemble(
        vec![Message::user("hi")],
        vec![],
        &model,
        None,
        Some(0.2),
        None,
    );
    assert_eq!(hot.temperature, Some(0.2));
    let default = assemble(vec![Message::user("hi")], vec![], &model, None, None, None);
    assert_eq!(default.temperature, None);
}

#[test]
fn agent_sends_configured_temperature_with_turn_requests() {
    let model = Model::new(
        ProviderId::new("fake"),
        "Fake",
        "small",
        "small",
        ModelLimits::new(800, 100),
    );
    let provider = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model.clone()]);
    let mut thread = Thread::new(
        "temperature-turn",
        SelectedModel::new(ProviderId::new("fake"), ModelId::new("small")),
    );
    thread.push_user("hi");
    let mut agent = Agent::new(thread, None);
    agent.set_temperature(Some(0.35));
    futures::executor::block_on(agent.prompt(&provider, &model, "continue")).unwrap();
    let requests = provider.requests();
    assert_eq!(requests[0].temperature, Some(0.35));
}
