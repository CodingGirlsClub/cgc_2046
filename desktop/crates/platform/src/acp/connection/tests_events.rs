use super::events::*;

#[test]
fn available_commands_map_to_command_views() {
    let commands = command_views(vec![
        agent_client_protocol::schema::v1::AvailableCommand::new(
            "compact",
            "Compact the conversation",
        ),
        agent_client_protocol::schema::v1::AvailableCommand::new(
            "review",
            "Review the current diff",
        )
        .input(
            agent_client_protocol::schema::v1::AvailableCommandInput::Unstructured(
                agent_client_protocol::schema::v1::UnstructuredCommandInput::new("file to review"),
            ),
        ),
    ]);
    assert_eq!(commands.len(), 2);
    assert_eq!(commands[0].name, "compact");
    assert!(!commands[0].requires_argument);
    assert_eq!(commands[1].name, "review");
    assert!(commands[1].requires_argument);
}

#[test]
fn config_categories_map_from_acp_and_preserve_unknown() {
    assert_eq!(
        config_category(&Some(
            agent_client_protocol::schema::v1::SessionConfigOptionCategory::Mode
        )),
        super::ConfigOptionCategory::Mode
    );
    assert_eq!(
        config_category(&Some(
            agent_client_protocol::schema::v1::SessionConfigOptionCategory::Model
        )),
        super::ConfigOptionCategory::Model
    );
    assert_eq!(
        config_category(&Some(
            agent_client_protocol::schema::v1::SessionConfigOptionCategory::ModelConfig
        )),
        super::ConfigOptionCategory::ModelConfig
    );
    assert_eq!(
        config_category(&Some(
            agent_client_protocol::schema::v1::SessionConfigOptionCategory::ThoughtLevel
        )),
        super::ConfigOptionCategory::ThoughtLevel
    );
    assert_eq!(
        config_category(&Some(
            agent_client_protocol::schema::v1::SessionConfigOptionCategory::Other(
                "custom".to_string()
            )
        )),
        super::ConfigOptionCategory::Other
    );
    assert_eq!(config_category(&None), super::ConfigOptionCategory::Other);
}
