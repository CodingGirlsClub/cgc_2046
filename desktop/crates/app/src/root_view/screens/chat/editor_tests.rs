use super::panel::render_chat_panel;
use crate::conversation_session::ConnectionPhase;
use crate::i18n::Language;
use crate::root_view::{screens::ScreenContext, RootView};
use cgc_platform::acp::connection::{ConfigOptionCategory, ConfigOptionView};
use cgc_platform::session::{FakeAuthApi, MemoryStore, SessionService};
use gpui_kit::test::{TestQueryExt, TestSupportExt, TestWindowExt};
use gpui_kit::{
    div, px, size, AppContext, Bounds, Context, Entity, InteractiveElement, IntoElement,
    ParentElement, Render, Styled, TestAppContext, Window, WindowBounds, WindowOptions,
};

struct AcpComposerProbe {
    root: Entity<RootView>,
}

impl Render for AcpComposerProbe {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let panel = self.root.update(cx, |root, cx| {
            let palette = crate::theme::palette(gpui_kit::component::ThemeMode::Light);
            render_chat_panel(
                &mut ScreenContext::new(&mut root.state),
                Language::En,
                &palette,
                cx,
            )
        });
        div()
            .id("acp-composer-probe")
            .test_support()
            .size_full()
            .child(panel)
    }
}

#[gpui_kit::test]
fn acp_composer_uses_shared_editor_growth_and_preserves_draft(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    let (handle, probe) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds {
                    origin: Default::default(),
                    size: size(px(360.0), px(500.0)),
                })),
                ..Default::default()
            },
            cx,
            |window, cx| {
                let root = cx.new(|_| {
                    let mut root = RootView::with_session(
                        crate::registration::build_registry().unwrap(),
                        Language::En,
                        crate::theme::ThemePreference::Light,
                        SessionService::new(
                            Box::new(FakeAuthApi::demo()),
                            Box::new(MemoryStore::default()),
                        ),
                    );
                    root.state.chat.agent = "codex".into();
                    root.state.chat.session.phase = ConnectionPhase::Ready;
                    root
                });
                root.update(cx, |root, cx| root.initialize_chat_input(window, cx));
                cx.new(|_| AcpComposerProbe { root })
            },
        )
        .unwrap()
    });
    cx.update_window(handle, |_, window, cx| {
        let root = probe.read(cx).root.clone();
        let input = root.read(cx).chat_input.clone().unwrap();
        crate::composer_context::ui_tests::assert_shared_editor_growth(&input, window, cx);
        let send = window.find_by_label("Send");
        assert_eq!(send.bounds().size, size(px(24.0), px(24.0)));
        root.update(cx, |root, cx| {
            root.state.chat.input = "/test".into();
            root.state.chat.session.commands = vec![cgc_platform::acp::connection::CommandView {
                name: "test".into(),
                description: "Test command".into(),
                requires_argument: false,
            }];
            cx.notify();
        });
        input.update(cx, |state, cx| state.set_value("/test", window, cx));
        window.render_frame(cx);
        let menu = window.find("chat-slash-popup");
        let editor = &window.find_all_by_role(gpui_kit::Role::MultilineTextInput)[0];
        assert!(menu.visible());
        assert!(menu.bounds().bottom() <= editor.bounds().top());
    })
    .unwrap();
    for (width, height) in [(260.0, 500.0), (380.0, 340.0), (260.0, 340.0)] {
        cx.simulate_window_resize(handle, size(px(width), px(height)));
        cx.update_window(handle, |_, window, cx| {
            let root = probe.read(cx).root.clone();
            root.update(cx, |root, cx| {
                root.state.chat.input.clear();
                cx.notify();
            });
            let input = root.read(cx).chat_input.clone().unwrap();
            input.update(cx, |state, cx| state.set_value("", window, cx));
            crate::composer_context::ui_tests::assert_shared_editor_growth(&input, window, cx);
            assert!(window.find_by_label("Send").visible());
        })
        .unwrap();
    }
}

#[gpui_kit::test]
fn acp_composer_renders_pending_agent_call_chip(cx: &mut TestAppContext) {
    use crate::agent_call::{AgentCall, LearningTarget, PendingAgentCall};
    use cgc_courses::content::{AgentActionSpec, AgentIntent};

    cx.update(gpui_kit::init);
    let (handle, probe) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds {
                    origin: Default::default(),
                    size: size(px(360.0), px(500.0)),
                })),
                ..Default::default()
            },
            cx,
            |window, cx| {
                let root = cx.new(|_| {
                    let mut root = RootView::with_session(
                        crate::registration::build_registry().unwrap(),
                        Language::En,
                        crate::theme::ThemePreference::Light,
                        SessionService::new(
                            Box::new(FakeAuthApi::demo()),
                            Box::new(MemoryStore::default()),
                        ),
                    );
                    root.state.chat.agent = "codex".into();
                    root.state.chat.session.phase = ConnectionPhase::Ready;
                    root
                });
                root.update(cx, |root, cx| root.initialize_chat_input(window, cx));
                cx.new(|_| AcpComposerProbe { root })
            },
        )
        .unwrap()
    });
    cx.update_window(handle, |_, window, cx| {
        let root = probe.read(cx).root.clone();
        let call = AgentCall::from_action(
            &AgentActionSpec {
                id: "a-hint".into(),
                label: "Hint".into(),
                intent: AgentIntent::Hint,
                primary: false,
            },
            LearningTarget::Objective {
                course_id: "crs-1".into(),
                revision: None,
                issue_id: "issue-1".into(),
                objective_id: "obj-1".into(),
            },
        );
        root.update(cx, |root, cx| {
            root.state.chat.pending_agent_call =
                Some(PendingAgentCall::new(call, "Hint", "Give me a hint"));
            cx.notify();
        });
        window.render_frame(cx);
        assert!(window.try_find("chat-agent-call-chip").is_some());
        assert!(window.try_find("chat-agent-call-remove").is_some());

        window.click("chat-agent-call-remove", cx);
        window.render_frame(cx);
        assert!(window.try_find("chat-agent-call-chip").is_none());
        assert!(root.read(cx).state.chat.pending_agent_call.is_none());
    })
    .unwrap();
}

#[gpui_kit::test]
fn acp_composer_keeps_send_and_stop_right_aligned_with_wrapped_configs(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    let (handle, probe) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds {
                    origin: Default::default(),
                    size: size(px(458.0), px(500.0)),
                })),
                ..Default::default()
            },
            cx,
            |window, cx| {
                let root = cx.new(|_| {
                    let mut root = RootView::with_session(
                        crate::registration::build_registry().unwrap(),
                        Language::En,
                        crate::theme::ThemePreference::Light,
                        SessionService::new(
                            Box::new(FakeAuthApi::demo()),
                            Box::new(MemoryStore::default()),
                        ),
                    );
                    root.state.native_chat_mode = false;
                    root.state.chat.agent = "codex".into();
                    root.state.chat.session.phase = ConnectionPhase::Ready;
                    root.state.chat.session.thread.capabilities =
                        cgc_agent_ui::conversation::ThreadCapabilities::acp();
                    root
                });
                root.update(cx, |root, cx| root.initialize_chat_input(window, cx));
                cx.new(|_| AcpComposerProbe { root })
            },
        )
        .unwrap()
    });
    let model = "M".repeat(64);
    let effort = "W".repeat(64);
    let configs: Vec<_> = [
        ("model", ConfigOptionCategory::Model, model.clone()),
        ("effort", ConfigOptionCategory::ThoughtLevel, effort.clone()),
    ]
    .into_iter()
    .map(|(id, category, current)| ConfigOptionView {
        id: id.into(),
        name: id.into(),
        category,
        values: vec![(current.clone(), current.clone())],
        current,
    })
    .collect();
    for (width, height) in [
        (458.0, 500.0),
        (380.0, 340.0),
        (260.0, 340.0),
        (560.0, 500.0),
    ] {
        cx.simulate_window_resize(handle, size(px(width), px(height)));
        for show_usage in [true, false] {
            cx.update_window(handle, |_, window, cx| {
                let root = probe.read(cx).root.clone();
                root.update(cx, |root, cx| {
                    root.state.chat.session.configs.clear();
                    root.state.chat.session.thread.status = cgc_agent_ui::conversation::ThreadStatus::Idle;
                    root.state.chat.session.thread.usage.used = 26_000;
                    root.state.chat.session.thread.usage.size = if show_usage { 1_000_000 } else { 0 };
                    cx.notify();
                });
                window.render_frame(cx);
                let expected_right = window.find_by_label("Send").bounds().right();
                root.update(cx, |root, cx| {
                    root.state.chat.session.configs = configs.clone();
                    cx.notify();
                });
                for (status, action) in [
                    (cgc_agent_ui::conversation::ThreadStatus::Idle, "Send"),
                    (cgc_agent_ui::conversation::ThreadStatus::Generating, "Stop Generation"),
                ] {
                    root.update(cx, |root, cx| {
                        root.state.chat.session.thread.status = status;
                        cx.notify();
                    });
                    window.render_frame(cx);
                    let send = window.find_by_label(action);
                    let bounds = send.bounds();
                    println!("ACP {width}x{height}, usage={show_usage}, {action}: {bounds:?}, right={expected_right:?}");
                    assert!(send.visible());
                    assert!(window.find_by_label(&model).visible());
                    assert!(window.find_by_label(&effort).visible());
                    assert!(
                        (bounds.right() - expected_right).as_f32().abs() <= 1.0,
                        "{action} must stay at the composer right edge after config wrapping"
                    );
                }
            })
            .unwrap();
        }
    }
}

struct AgentHeaderProbe {
    root: Entity<RootView>,
    language: Language,
}

impl Render for AgentHeaderProbe {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let panel = self.root.update(cx, |root, cx| {
            super::agent_panel::render_agent_panel(
                &mut ScreenContext::new(&mut root.state),
                self.language,
                &crate::theme::palette(gpui_kit::component::ThemeMode::Light),
                window,
                cx,
            )
        });
        div()
            .id("agent-header-probe")
            .test_support()
            .size_full()
            .child(panel)
    }
}

#[gpui_kit::test]
fn new_chat_button_has_a_localized_name_in_both_agent_modes(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    for native in [false, true] {
        for (language, expected) in [(Language::En, "New chat"), (Language::Zh, "新对话")] {
            let (handle, _) = cx.update(|cx| {
                gpui_kit::open_window(
                    WindowOptions {
                        window_bounds: Some(WindowBounds::Windowed(Bounds {
                            origin: Default::default(),
                            size: size(px(420.0), px(500.0)),
                        })),
                        ..Default::default()
                    },
                    cx,
                    |window, cx| {
                        let root = cx.new(|_| {
                            let mut root = RootView::with_session(
                                crate::registration::build_registry().unwrap(),
                                language,
                                crate::theme::ThemePreference::Light,
                                SessionService::new(
                                    Box::new(FakeAuthApi::demo()),
                                    Box::new(MemoryStore::default()),
                                ),
                            );
                            root.state.native_chat_mode = native;
                            root.state.chat.agent = "codex".into();
                            root
                        });
                        root.update(cx, |root, cx| root.initialize_chat_input(window, cx));
                        cx.new(|_| AgentHeaderProbe { root, language })
                    },
                )
                .unwrap()
            });
            cx.update_window(handle, |_, window, cx| {
                window.render_frame(cx);
                let button = window.find("agent-panel-new-trigger");
                assert!(button.visible());
                assert_eq!(button.role(), Some(gpui_kit::Role::Button));
                assert_eq!(button.label(), Some(expected), "native={native}");
            })
            .unwrap();
        }
    }
}
