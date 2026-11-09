pub(in crate::root_view) use auth::{render_login_split, render_reset_login_card};
#[cfg(all(test, cgc_ui_tests))]
pub(in crate::root_view) use chat::agent_panel::header as render_agent_panel_header;
pub(in crate::root_view) use chat::dock::render_agent_panel;
pub(in crate::root_view) use context::ScreenContext;
pub(in crate::root_view) use courses::{
    detail::render_course_detail, learning::render_course_learning, list::render_courses_list,
};
#[cfg(all(test, cgc_ui_tests))]
pub(in crate::root_view) use events::detail::render_enrollment_area;
pub(in crate::root_view) use events::{detail::render_detail, list::render_events_list};
pub(in crate::root_view) use learning_home::render_learning_home;
pub(in crate::root_view) use offering_workspace::{render_workspace_badge, render_workspace_link};
pub(in crate::root_view) use participations::render_participations;
pub(in crate::root_view) use settings::render_settings;
pub(in crate::root_view) use workspace_overview::render_workspace_overview;

mod auth;

pub(in crate::root_view) use auth::sanitize_login_paste;
mod chat;
mod context;
mod courses;
mod events;
mod learning_home;
mod offering_workspace;
mod participations;
mod settings;
mod workspace_overview;

mod workspace;
pub(in crate::root_view) use workspace::agent_registry::render_agent_registry;
pub(in crate::root_view) use workspace::card::render_issue_card;
pub(in crate::root_view) use workspace::pane::{render_pane_notices, render_pane_tabs};
pub(in crate::root_view) use workspace::right_dock::render_right_dock;
