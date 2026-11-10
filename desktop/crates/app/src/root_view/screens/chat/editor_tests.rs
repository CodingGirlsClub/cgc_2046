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
use std::sync::{Arc, Mutex};

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
        // 可访问名称必须是语义化的，而不是可见符号 "×"。
        assert_eq!(
            window.find("chat-agent-call-remove").label(),
            Some("Remove learning action")
        );

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

/// 共用宿主：in-process ACP host 捕获 PromptRequest；窗口挂在
/// `/w/alpha/courses/crs-000/learn`，page context 由路由刷新生成。
fn open_acp_auto_send_window(
    cx: &mut TestAppContext,
) -> (
    gpui_kit::AnyWindowHandle,
    Entity<AcpComposerProbe>,
    Arc<Mutex<Vec<String>>>,
) {
    use crate::root_view::state::PaneTab;
    use agent_client_protocol::schema::v1::{
        AgentCapabilities, ContentBlock, InitializeRequest, InitializeResponse, NewSessionRequest,
        NewSessionResponse, PromptRequest, PromptResponse, StopReason,
    };
    use agent_client_protocol::{on_receive_request, Agent};
    use cgc_courses::catalog::{CoursesApi, FakeCoursesApi};
    use cgc_platform::acp::connection::{AcpHost, AcpHostConfig};
    use cgc_platform::workspace::WorkspaceSummary;
    use std::time::{Duration, Instant};

    let captured = Arc::new(Mutex::new(Vec::<String>::new()));
    let received = captured.clone();
    let (handle, probe) = cx.update(|cx| {
        let server = Agent
            .builder()
            .on_receive_request(
                async |_: InitializeRequest, responder, _| {
                    responder.respond(
                        InitializeResponse::new(1u16.into())
                            .agent_capabilities(AgentCapabilities::new()),
                    )
                },
                on_receive_request!(),
            )
            .on_receive_request(
                async |_: NewSessionRequest, responder, _| {
                    responder.respond(NewSessionResponse::new("acp-auto-send-test"))
                },
                on_receive_request!(),
            )
            .on_receive_request(
                async move |request: PromptRequest, responder, _| {
                    let text = request
                        .prompt
                        .iter()
                        .filter_map(|block| match block {
                            ContentBlock::Text(text) => Some(text.text.as_str()),
                            _ => None,
                        })
                        .collect::<Vec<_>>()
                        .join("\n");
                    received.lock().unwrap().push(text);
                    responder.respond(PromptResponse::new(StopReason::EndTurn))
                },
                on_receive_request!(),
            );
        let host = AcpHost::start_in_process(AcpHostConfig::new("", std::env::temp_dir()), server)
            .expect("in-process acp host");
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds {
                    origin: Default::default(),
                    size: size(px(420.0), px(600.0)),
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
                    root.state.session_checked = true;
                    root.state.chat.agent = "codex".into();
                    root.state.workspaces.adopt(vec![WorkspaceSummary {
                        id: "ws-alpha".into(),
                        slug: "alpha".into(),
                        name: "Alpha".into(),
                        my_role_names: vec![],
                        member_count: None,
                        can_access: true,
                    }]);
                    let content = FakeCoursesApi::with_seed(1)
                        .get_course_content(None, "crs-000")
                        .expect("fake course content");
                    root.state.content.adopt(content);
                    let path = "/w/alpha/courses/crs-000/learn";
                    let tab = PaneTab::page(path, "Course");
                    root.state.active_tab = Some(tab.id.clone());
                    root.state.tabs.push(tab);
                    root.navigate(path);
                    let generation = root.state.chat.session.attach(host);
                    let deadline = Instant::now() + Duration::from_secs(5);
                    while !root.state.chat.session.can_submit()
                        || root.state.chat.session.session_id.is_none()
                    {
                        assert!(Instant::now() < deadline, "acp host did not become ready");
                        if let Some(event) = root
                            .state
                            .chat
                            .session
                            .host
                            .as_ref()
                            .unwrap()
                            .recv_timeout(Duration::from_millis(20))
                        {
                            root.state.chat.session.ingest_external(generation, &event);
                        }
                    }
                    root
                });
                root.update(cx, |root, cx| root.initialize_chat_input(window, cx));
                cx.new(|_| AcpComposerProbe { root })
            },
        )
        .unwrap()
    });
    (handle, probe, captured)
}

/// AutoSend 回归：ACP 侧 `send_chat_agent_call` 也必须先 `freeze_page` 再构造
/// Submission。若未来把 context 改回 `None`，`PageContextState::refresh` 会原样
/// 返回裸 prompt，MCP 丢失 workspace/course 标识（此前线上症状）；此测试断言
/// in-process ACP host 收到的最终 prompt 仍带 workspace_id 与页面正文。
#[gpui_kit::test]
fn acp_auto_send_sends_page_context(cx: &mut TestAppContext) {
    use crate::agent_call::{AgentCall, LearningTarget};
    use cgc_courses::content::{AgentActionSpec, AgentIntent};
    use std::time::{Duration, Instant};

    cx.update(gpui_kit::init);
    let (handle, probe, captured) = open_acp_auto_send_window(cx);
    cx.update_window(handle, |_, window, cx| {
        let root = probe.read(cx).root.clone();
        root.update(cx, |root, cx| {
            let call = AgentCall::from_action(
                &AgentActionSpec {
                    id: "a-hint".into(),
                    label: "Hint".into(),
                    intent: AgentIntent::Hint,
                    primary: false,
                },
                LearningTarget::Objective {
                    course_id: "crs-000".into(),
                    revision: None,
                    issue_id: "issue-1".into(),
                    objective_id: "obj-1".into(),
                },
            );
            assert!(root.send_chat_agent_call(call, "automatic hint".into(), cx));
        });
        window.render_frame(cx);
    })
    .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        cx.run_until_parked();
        if !captured.lock().unwrap().is_empty() {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "auto-send prompt did not reach the acp host"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let prompts = captured.lock().unwrap();
    assert_eq!(
        prompts.len(),
        1,
        "auto-send must deliver exactly one prompt"
    );
    let prompt = &prompts[0];
    assert!(
        prompt.contains("workspace_id=ws-alpha"),
        "auto-send prompt lost the workspace identifier: {prompt}"
    );
    assert!(
        prompt.contains("<active_tab_body>"),
        "auto-send prompt lost the page body: {prompt}"
    );
    assert!(
        prompt.contains("的课程正文"),
        "auto-send prompt lost the fake course body text: {prompt}"
    );
}

/// AutoSend 在 Agent 忙碌/未就绪时退化为预填（FillOnly 行为）：动作保留为
/// pending chip，不自动发送，由用户空闲后确认。ACP 轨没有队列泵，不为该
/// 场景引入排队（见 ADR-0029 §7）。
#[gpui_kit::test]
fn acp_auto_send_busy_falls_back_to_pending(cx: &mut TestAppContext) {
    use crate::agent_call::{AgentCall, DeliveryMode, LearningTarget};
    use cgc_courses::content::{AgentActionSpec, AgentIntent};
    use std::time::{Duration, Instant};

    cx.update(gpui_kit::init);
    // 隔离 preferences 文件：本测试要显式开 AutoSend，不读写开发者真实配置。
    let directory =
        std::env::temp_dir().join(format!("cgc-acp-auto-send-busy-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&directory).expect("isolated data directory");
    let previous_data_dir = std::env::var_os("CGC_DATA_DIR");
    std::env::set_var("CGC_DATA_DIR", &directory);
    crate::preferences::update(|prefs| {
        prefs.course_action_delivery = DeliveryMode::AutoSend;
    });

    let (handle, probe, captured) = open_acp_auto_send_window(cx);
    // 先发一条普通消息让 session 进入 busy；不 drain TurnEnd，保持忙碌。
    cx.update_window(handle, |_, _window, cx| {
        let root = probe.read(cx).root.clone();
        root.update(cx, |root, cx| {
            assert!(root.send_chat_text("first question".into(), cx));
            assert!(root.chat.session.is_busy(), "session must be busy");
        });
    })
    .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        cx.run_until_parked();
        if !captured.lock().unwrap().is_empty() {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "first prompt did not reach the acp host"
        );
        std::thread::sleep(Duration::from_millis(20));
    }

    cx.update_window(handle, |_, window, cx| {
        let root = probe.read(cx).root.clone();
        root.update(cx, |root, cx| {
            let call = AgentCall::from_action(
                &AgentActionSpec {
                    id: "a-hint".into(),
                    label: "Hint".into(),
                    intent: AgentIntent::Hint,
                    primary: false,
                },
                LearningTarget::Objective {
                    course_id: "crs-000".into(),
                    revision: None,
                    issue_id: "issue-1".into(),
                    objective_id: "obj-1".into(),
                },
            );
            root.apply_agent_call(call, "automatic hint".into(), "Hint".into(), window, cx);
        });
        window.render_frame(cx);
        // 退化：pending 保留、prompt 预填、给出明确提示；不自动发送。
        assert!(
            root.read(cx).chat.pending_agent_call.is_some(),
            "busy auto-send must fall back to a pending action"
        );
        let input = root.read(cx).chat_input.clone().expect("chat input");
        assert_eq!(input.read(cx).value(), "automatic hint");
        let notice = root
            .read(cx)
            .pane_notice
            .clone()
            .expect("busy fallback must surface a notice");
        assert!(
            notice.contains("busy"),
            "notice must explain the fallback: {notice}"
        );
    })
    .unwrap();
    cx.run_until_parked();
    assert_eq!(
        captured.lock().unwrap().len(),
        1,
        "busy auto-send must not send automatically"
    );

    match previous_data_dir {
        Some(value) => std::env::set_var("CGC_DATA_DIR", value),
        None => std::env::remove_var("CGC_DATA_DIR"),
    }
    let _ = std::fs::remove_dir_all(&directory);
}
