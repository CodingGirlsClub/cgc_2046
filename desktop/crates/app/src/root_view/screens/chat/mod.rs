pub(super) mod agent_panel;
pub(super) mod dock;
pub(super) mod panel;
pub(crate) mod surface;

#[cfg(test)]
mod tests {
    use super::agent_panel::{content_kind, AgentPanelContent};

    #[test]
    fn external_agent_panel_is_available_on_every_center_tab() {
        assert_eq!(
            content_kind(false, Some("events.detail")),
            AgentPanelContent::External
        );
        assert_eq!(
            content_kind(false, Some("courses.catalog")),
            AgentPanelContent::External
        );
    }
}
