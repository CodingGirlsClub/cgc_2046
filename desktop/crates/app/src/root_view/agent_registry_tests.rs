//! Agent Registry：DSH Desktop 检测信息在 Ready 状态展示，不阻断安装/启动。

use super::RootView;
use crate::i18n::Language;
use crate::theme::ThemePreference;
use cgc_platform::agent::detect::{AgentStatus, DetectedAgent};
use cgc_platform::agent::dsh_runtime::{RuntimeProbe, RuntimeSource};
use cgc_platform::registry::manifest::Registry;
use cgc_platform::session::{FakeAuthApi, MemoryStore, SessionService};
use gpui_kit::test::{TestQueryExt, TestWindowExt};
use gpui_kit::{
    div, px, size, AppContext, Bounds, Context, Entity, IntoElement, ParentElement, Render, Styled,
    TestAppContext, Window, WindowBounds, WindowOptions,
};

struct AgentRegistryProbe {
    root: Entity<RootView>,
}

impl Render for AgentRegistryProbe {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let registry = self.root.update(cx, |root, cx| {
            let language = root.language;
            let palette = crate::theme::palette(gpui_kit::component::ThemeMode::Light);
            let mut context = crate::root_view::screens::ScreenContext::new(&mut root.state);
            crate::root_view::screens::render_agent_registry(&mut context, language, &palette, cx)
        });
        div().size(px(900.0)).flex().flex_col().child(registry)
    }
}

fn rows_with_runtime(
    rows: impl IntoIterator<Item = (&'static str, AgentStatus, RuntimeProbe)>,
) -> Vec<DetectedAgent> {
    let registry = Registry::builtin().expect("builtin registry");
    rows.into_iter()
        .map(|(id, status, runtime)| DetectedAgent {
            entry: registry.get(id).expect("registry entry").clone(),
            status,
            runtime,
        })
        .collect()
}

fn open_registry_with(
    cx: &mut TestAppContext,
    language: Language,
    rows: Vec<DetectedAgent>,
    configure: impl FnOnce(&mut RootView) + 'static,
) -> gpui_kit::AnyWindowHandle {
    let mut configure = Some(configure);
    cx.update(gpui_kit::init);
    cx.update(|cx| {
        let (handle, _probe) = gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(900.), px(640.)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                let root = cx.new(|_| {
                    let mut root = RootView::with_session_from(
                        crate::registration::build_registry().expect("routes"),
                        language,
                        ThemePreference::Light,
                        SessionService::new(
                            Box::new(FakeAuthApi::demo()),
                            Box::new(MemoryStore::default()),
                        ),
                        "/agents",
                    );
                    root.state.agent_registry_rows = rows;
                    if let Some(configure) = configure.take() {
                        configure(&mut root);
                    }
                    root
                });
                cx.new(|_| AgentRegistryProbe { root })
            },
        )
        .expect("registry probe window");
        handle
    })
}

fn open_registry(
    cx: &mut TestAppContext,
    language: Language,
    rows: Vec<DetectedAgent>,
) -> gpui_kit::AnyWindowHandle {
    open_registry_with(cx, language, rows, |_| {})
}

fn detected_desktop(desktop: &str, bundled: &str) -> RuntimeProbe {
    RuntimeProbe {
        found: true,
        version: Some(desktop.to_string()),
        source: RuntimeSource::DshDesktop,
        path: Some("/Applications/DSH Desktop.app/Contents/Resources/runtime/cli/bin/dsh".into()),
        bundled_version: Some(bundled.to_string()),
    }
}

fn bundled_only(bundled: &str) -> RuntimeProbe {
    RuntimeProbe {
        found: false,
        version: None,
        source: RuntimeSource::Missing,
        path: None,
        bundled_version: Some(bundled.to_string()),
    }
}

#[gpui_kit::test]
fn ready_with_dsh_desktop_shows_versions_without_changing_install_state(cx: &mut TestAppContext) {
    let rows = rows_with_runtime([(
        "deepseek",
        AgentStatus::Ready {
            version: "0.4.41".to_string(),
        },
        detected_desktop("0.2.2-rc.1", "0.2.1-rc.5"),
    )]);
    let handle = open_registry(cx, Language::Zh, rows);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(
            window
                .try_find_by_label("检测到 DSH Desktop 0.2.2-rc.1；本次使用内置运行时 0.2.1-rc.5")
                .is_some(),
            "Ready + 检测到 Desktop 时必须同时展示 Desktop 版本与内置运行时版本"
        );
        assert_ne!(
            window.find("agent-install-deepseek").disabled(),
            Some(true),
            "已就绪的 DSH 仍须提供可用的重新安装入口"
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn ready_without_dsh_desktop_keeps_the_download_optional(cx: &mut TestAppContext) {
    let rows = rows_with_runtime([(
        "deepseek",
        AgentStatus::Ready {
            version: "0.4.41".to_string(),
        },
        bundled_only("0.2.1-rc.5"),
    )]);
    let handle = open_registry(cx, Language::Zh, rows);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(
            window.try_find_by_label("下载 DSH Desktop").is_some(),
            "未检测到 Desktop 时保留可选下载入口"
        );
        assert_ne!(
            window.find("agent-install-deepseek").disabled(),
            Some(true),
            "standalone 已就绪时也须允许重新安装或迁移到本地 profile"
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn existing_install_states_keep_the_install_button_enabled(cx: &mut TestAppContext) {
    let rows = rows_with_runtime([
        ("codex", AgentStatus::Missing, RuntimeProbe::missing()),
        (
            "claude_code",
            AgentStatus::Outdated {
                found: "0.90.0".to_string(),
                required: "0.94.0".to_string(),
            },
            RuntimeProbe::missing(),
        ),
        (
            "deepseek",
            AgentStatus::NodeUnavailable {
                required: "24.0.0".to_string(),
                found: None,
            },
            RuntimeProbe::missing(),
        ),
    ]);
    let handle = open_registry(cx, Language::En, rows);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        for id in ["codex", "claude_code", "deepseek"] {
            assert_ne!(
                window.find(format!("agent-install-{id}")).disabled(),
                Some(true),
                "existing states must keep install enabled for {id}"
            );
        }
        assert!(
            window
                .try_find_by_label(
                    "DSH Desktop not detected. No impact: the bundled runtime will be used."
                )
                .is_some(),
            "openma 条目即使未检测到 Desktop 也展示信息行"
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn dsh_resume_preserves_title_and_expires_legacy_approval(cx: &mut TestAppContext) {
    use crate::root_view::ReplayState;
    use cgc_agent_ui::conversation::{ConversationThread, Entry, ThreadEvent, ThreadStatus};

    cx.update(|cx| {
        let root = cx.new(|_| {
            RootView::with_session_from(
                crate::registration::build_registry().unwrap(),
                Language::Zh,
                ThemePreference::Light,
                SessionService::new(
                    Box::new(FakeAuthApi::demo()),
                    Box::new(MemoryStore::default()),
                ),
                "/agents",
            )
        });
        root.update(cx, |root, cx| {
            root.chat.session.thread.title = Some("old title".into());
            root.chat
                .session
                .thread
                .apply(ThreadEvent::PermissionRequested {
                    request_id: "old-permission".into(),
                    title: "Run command?".into(),
                    tool: Some("run_command".into()),
                    tool_call_id: Some("old-tool".into()),
                    args: None,
                    options: Vec::new(),
                });
            assert!(root.chat.session.thread.pending_permission.is_some());
            root.chat.title_override = Some("user title".into());
            root.chat.restore_via_resume = true;
            root.chat.replay = Some(ReplayState {
                thread: ConversationThread {
                    title: Some("title received before Ready".into()),
                    ..Default::default()
                },
                saw_events: true,
                has_local_content: true,
            });

            root.finish_history_restore(cx);

            assert_eq!(
                root.chat.session.thread.title.as_deref(),
                Some("title received before Ready")
            );
            assert_eq!(root.chat.title_override.as_deref(), Some("user title"));
            assert_eq!(root.chat.session.thread.status, ThreadStatus::Idle);
            assert!(root.chat.session.thread.pending_permission.is_none());
            assert!(matches!(
                root.chat.session.thread.entries.as_slice(),
                [Entry::Notice { .. }]
            ));
            assert!(!root.chat.resumed_without_history);
        });
    });
}

#[gpui_kit::test]
fn auth_retry_preserves_history_target_until_ready(cx: &mut TestAppContext) {
    use crate::conversation_session::ConnectionPhase;
    use crate::native_panel_host::McpContext;
    use cgc_platform::mcp::credential::LearningHostLease;

    cx.update(|cx| {
        let root = cx.new(|_| {
            RootView::with_session_from(
                crate::registration::build_registry().unwrap(),
                Language::Zh,
                ThemePreference::Light,
                SessionService::new(
                    Box::new(FakeAuthApi::demo()),
                    Box::new(MemoryStore::default()),
                ),
                "/agents",
            )
        });
        root.update(cx, |root, cx| {
            let epoch = root.workspaces.epoch();
            root.agent_mcp = McpContext::for_lease(
                LearningHostLease {
                    token: "synthetic-test-lease".into(),
                    token_id: "synthetic-test-id".into(),
                    epoch,
                },
                epoch,
                Some("http://127.0.0.1:1/api/graphql"),
                None,
            );
            // 未注册条目在 launch 前失败；测试不启动真实 agent 或访问后端。
            root.chat.selected_agent = Some("unregistered-test-agent".into());
            root.chat.restore_id = Some("history-session".into());
            for _ in 0..2 {
                root.chat.session.phase = ConnectionPhase::AuthRequired {
                    message: "credential required".into(),
                    auth_methods: Vec::new(),
                };
                root.start_chat(cx);
                assert_eq!(root.chat.session.phase, ConnectionPhase::Starting);
                assert_eq!(root.chat.restore_id.as_deref(), Some("history-session"));
            }
        });
    });
}

#[gpui_kit::test]
fn new_chat_discards_pending_history_restore(cx: &mut TestAppContext) {
    use crate::conversation_session::ConnectionPhase;

    cx.update(|cx| {
        let root = cx.new(|_| {
            RootView::with_session_from(
                crate::registration::build_registry().unwrap(),
                Language::Zh,
                ThemePreference::Light,
                SessionService::new(
                    Box::new(FakeAuthApi::demo()),
                    Box::new(MemoryStore::default()),
                ),
                "/agents",
            )
        });
        root.update(cx, |root, cx| {
            root.chat.selected_agent = Some("unregistered-test-agent".into());
            for phase in [
                ConnectionPhase::Starting,
                ConnectionPhase::AuthRequired {
                    message: "credential required".into(),
                    auth_methods: Vec::new(),
                },
            ] {
                root.chat.session.phase = phase;
                root.chat.restore_id = Some("pending-history-session".into());
                root.chat.restore_via_resume = true;
                root.chat.session.thread.title = Some("old history".into());

                root.new_chat(cx);

                assert!(
                    root.chat.restore_id.is_none(),
                    "new chat must discard the history target"
                );
                assert!(!root.chat.restore_via_resume);
                assert!(root.chat.session.thread.title.is_none());
            }
        });
    });
}

#[gpui_kit::test]
fn install_waits_for_the_same_agent_uninstall(cx: &mut TestAppContext) {
    cx.update(|cx| {
        let root = cx.new(|_| {
            RootView::with_session_from(
                crate::registration::build_registry().unwrap(),
                Language::Zh,
                ThemePreference::Light,
                SessionService::new(
                    Box::new(FakeAuthApi::demo()),
                    Box::new(MemoryStore::default()),
                ),
                "/agents",
            )
        });
        root.update(cx, |root, cx| {
            let mut rows = rows_with_runtime([(
                "deepseek",
                AgentStatus::Ready {
                    version: "0.4.41".into(),
                },
                RuntimeProbe::missing(),
            )]);
            rows[0].entry.id = "concurrent-install-test".into();
            rows[0].entry.distribution = cgc_platform::registry::manifest::Distribution::Native {
                command: "/cgc-nonexistent-test-agent".into(),
            };
            root.agent_registry_rows = rows;
            root.agent_uninstalling = Some("concurrent-install-test".into());

            root.install_agent("concurrent-install-test", cx);

            assert!(
                root.agent_installing.is_none(),
                "install must wait for uninstall"
            );
        });
    });
}

#[gpui_kit::test]
fn dsh_install_and_uninstall_buttons_mutually_disable_each_other(cx: &mut TestAppContext) {
    let rows = rows_with_runtime([(
        "deepseek",
        AgentStatus::Ready {
            version: "0.4.41".to_string(),
        },
        bundled_only("0.2.1-rc.5"),
    )]);
    let handle = open_registry_with(cx, Language::Zh, rows.clone(), |root| {
        root.state.agent_installing = Some("deepseek".into());
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(
            window.find("agent-install-deepseek").disabled(),
            Some(true),
            "安装中必须禁用安装按钮"
        );
        assert_eq!(
            window.find("agent-uninstall-deepseek").disabled(),
            Some(true),
            "安装中必须禁用卸载按钮"
        );
    })
    .unwrap();

    let handle = open_registry_with(cx, Language::Zh, rows, |root| {
        root.state.agent_uninstalling = Some("deepseek".into());
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(
            window.find("agent-install-deepseek").disabled(),
            Some(true),
            "卸载中必须禁用安装按钮"
        );
        assert_eq!(
            window.find("agent-uninstall-deepseek").disabled(),
            Some(true),
            "卸载中必须禁用卸载按钮"
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn dsh_share_local_toggle_warns_about_multi_account_isolation_in_both_states(
    cx: &mut TestAppContext,
) {
    use crate::i18n::{translate, Key};

    let rows = rows_with_runtime([(
        "deepseek",
        AgentStatus::Ready {
            version: "0.4.41".to_string(),
        },
        bundled_only("0.2.1-rc.5"),
    )]);

    for (language, shared) in [
        (Language::Zh, false),
        (Language::Zh, true),
        (Language::En, false),
        (Language::En, true),
    ] {
        let key = if shared {
            Key::AgentRegistryDshShareLocalOn
        } else {
            Key::AgentRegistryDshShareLocalHint
        };
        let expected = translate(language, key);
        match language {
            Language::Zh => {
                assert!(
                    expected.contains("多账号")
                        && expected.contains("多工作台")
                        && expected.contains("不再隔离"),
                    "中文提示缺少多账号/多工作台不隔离警示：{expected}"
                );
            }
            Language::En => {
                let lower = expected.to_lowercase();
                assert!(
                    lower.contains("accounts")
                        && lower.contains("workspaces")
                        && lower.contains("no longer isolated"),
                    "英文提示缺少多账号/多工作台不隔离警示：{expected}"
                );
            }
        }

        let handle = open_registry_with(cx, language, rows.clone(), move |root| {
            root.state.dsh_share_local_home = shared;
        });
        cx.update_window(handle, |_, window, cx| {
            window.render_frame(cx);
            let _ = window.find("agent-dsh-share-hint-deepseek");
            assert!(
                window.try_find_by_label(expected).is_some(),
                "共享开关提示应带 status/aria_label 且匹配预期译文：{expected}"
            );
        })
        .unwrap();
    }
}
