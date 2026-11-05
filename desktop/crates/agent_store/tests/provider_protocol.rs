use cgc_agent_provider::{ProviderProtocol, ThinkingMode};
use cgc_agent_store::ProviderPrefs;
use serde_json::json;

#[test]
fn pre_protocol_configuration_keeps_models_and_key_presence() {
    let old = json!({"id":"custom","name":"Existing","base_url":"https://example.test/v1","models":["model"],"has_key":true,"builtin":false,"model_params":[{"id":"model","context_window":64000,"max_output_tokens":8000,"supports_thinking":false,"enabled":true,"supports_tools":true,"supports_images":false,"reasoning_efforts":[]}]});
    let prefs: ProviderPrefs = serde_json::from_value(old).unwrap();
    assert_eq!(prefs.protocol, ProviderProtocol::OpenAiCompatible);
    assert_eq!(
        prefs.model_config("model").thinking_mode,
        ThinkingMode::Disabled
    );
    assert_eq!(prefs.models, vec!["model"]);
    assert!(prefs.has_key);
}

#[test]
fn anthropic_model_configuration_survives_editing_and_serialization() {
    let prefs: ProviderPrefs = serde_json::from_value(json!({"id":"custom","name":"Anthropic","protocol":"anthropic_compatible","base_url":"https://example.test","models":["model"],"has_key":true,"builtin":false,"model_params":[{"id":"model","context_window":64000,"max_output_tokens":8000,"supports_thinking":true,"enabled":true,"supports_tools":true,"supports_images":true,"reasoning_efforts":[],"thinking_mode":{"type":"budget","budget_tokens":2048}}]})).unwrap();
    let lines = cgc_agent_store::model_lines::format_model_lines(&prefs);
    let (_, models) = cgc_agent_store::model_lines::parse_model_lines(&lines);
    assert_eq!(
        models[0].thinking_mode,
        ThinkingMode::Budget {
            budget_tokens: 2048
        }
    );
    let restored: ProviderPrefs =
        serde_json::from_str(&serde_json::to_string(&prefs).unwrap()).unwrap();
    assert_eq!(restored.protocol, ProviderProtocol::AnthropicCompatible);
    assert_eq!(
        restored.model_config("model").thinking_mode,
        models[0].thinking_mode
    );
}

#[test]
fn adaptive_effort_capabilities_survive_model_line_editing() {
    let model = cgc_agent_store::ModelPrefs {
        supports_thinking: true,
        thinking_mode: ThinkingMode::Adaptive,
        reasoning_efforts: vec!["low".into(), "high".into()],
        ..cgc_agent_store::ModelPrefs::new("model")
    };
    let prefs = ProviderPrefs {
        id: "custom".into(),
        name: "Custom".into(),
        protocol: ProviderProtocol::AnthropicCompatible,
        base_url: "https://example.test".into(),
        models: vec!["model".into()],
        has_key: false,
        builtin: false,
        model_params: vec![model],
    };
    let (_, edited) = cgc_agent_store::model_lines::parse_model_lines(
        &cgc_agent_store::model_lines::format_model_lines(&prefs),
    );
    assert_eq!(
        edited, prefs.model_params,
        "editing must preserve the exact declared effort capabilities"
    );
    let (_, unspecified) = cgc_agent_store::model_lines::parse_model_lines(
        "model | 64000 | 8000 | true | true | true | false | adaptive",
    );
    assert!(
        unspecified[0].reasoning_efforts.is_empty(),
        "Adaptive alone does not declare any effort levels"
    );
}
