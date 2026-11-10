use super::NativeAgentView;
use crate::i18n::Language;
use crate::native_runtime::NativeRuntimeHandle;
use cgc_agent_core::{SelectedModel, Thread};
use cgc_agent_provider::{FakeProvider, Model, ModelId, ModelLimits, ProviderId};
use gpui_kit::component::input::TextareaState;
use gpui_kit::test::{TestQueryExt, TestSupportExt, TestWindowExt};
use gpui_kit::{
    div, px, size, App, AppContext, Bounds, Context, Entity, InteractiveElement, IntoElement,
    ParentElement, Render, Styled, TestAppContext, Window, WindowBounds, WindowOptions,
};
use std::sync::Arc;

struct NativeComposerProbe {
    view: Entity<NativeAgentView>,
}

impl NativeComposerProbe {
    fn new(window: &mut Window, cx: &mut App) -> Self {
        Self::with_history(window, cx, false)
    }

    fn with_history(window: &mut Window, cx: &mut App, with_history: bool) -> Self {
        let model = Model::new(
            ProviderId::new("fake"),
            "Test provider",
            "test-model",
            "Test model",
            ModelLimits::new(8_000, 1_000),
        )
        .with_capabilities(cgc_agent_provider::ModelCapabilities {
            tools: true,
            images: true,
            thinking: false,
        });
        let mut thread = Thread::new(
            "editor-test",
            SelectedModel::new(ProviderId::new("fake"), ModelId::new("test-model")),
        );
        if with_history {
            thread.push_user("a chat-only question");
        }
        let runtime = NativeRuntimeHandle::spawn(
            thread,
            None,
            crate::native_runtime::NativeRuntimeConfig {
                provider: Arc::new(FakeProvider::new(
                    ProviderId::new("fake"),
                    "Test provider",
                    vec![model.clone()],
                )),
                model,
                registry: Arc::new(cgc_agent_tools::ToolRegistry::new()),
                context: cgc_agent_tools::ToolContext::new(std::env::temp_dir()),
                context_size: 8_000,
                auto_approve: false,
            },
            None,
        );
        let snapshot = futures::executor::block_on(runtime.inspect()).unwrap();
        let view = cx.new(|cx| {
            NativeAgentView::new(
                window,
                cx,
                runtime,
                crate::page_context::PageContextState::default(),
                Language::En,
                None,
            )
        });
        view.update(cx, |view, _| {
            let mut provider = cgc_agent_store::ProviderPrefs {
                id: "fake".into(),
                name: "Test provider".into(),
                ..Default::default()
            };
            let mut model = cgc_agent_store::ModelPrefs::new("test-model");
            model.supports_images = true;
            provider.upsert_model(model);
            let snapshot = view.snapshot.as_ref().expect("runtime snapshot");
            view.snapshot = Some(Arc::new(crate::native_runtime::NativeRuntimeSnapshot {
                thread: snapshot.thread.clone(),
                model: snapshot.model.clone(),
                workspace: snapshot.workspace.clone(),
                phase: snapshot.phase,
                generation: snapshot.generation,
                revision: snapshot.revision,
                authorization_epoch: snapshot.authorization_epoch,
                mcp_unavailable_reason: snapshot.mcp_unavailable_reason.clone(),
                display_title: snapshot.display_title.clone(),
                title_generating: snapshot.title_generating,
                title_generation_error: snapshot.title_generation_error.clone(),
                schemas: snapshot.schemas.clone(),
                providers: Arc::new(vec![provider]),
                model_setup: snapshot.model_setup,
                thinking_enabled: snapshot.thinking_enabled,
                effort_index: snapshot.effort_index,
                approval_mode: snapshot.approval_mode,
                checkpoints: snapshot.checkpoints.clone(),
                changes: snapshot.changes.clone(),
                agent_state: snapshot.agent_state.clone(),
                persistence_available: snapshot.persistence_available,
            }));
        });
        if with_history {
            view.update(cx, |view, cx| {
                super::apply_thread_entries(
                    &mut view.state.session.thread,
                    &snapshot.thread.entries,
                );
                cx.notify();
            });
        }
        Self { view }
    }

    fn input(&self, cx: &App) -> Entity<TextareaState> {
        self.view.read(cx).input.clone()
    }
}

impl Render for NativeComposerProbe {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let composer = self.view.update(cx, |view, cx| {
            let draft = view.composer_draft(cx);
            view.render_composer(&draft, window, cx)
        });
        div()
            .id("native-composer-probe")
            .test_support()
            .size_full()
            .flex()
            .flex_col()
            .justify_end()
            .child(composer)
    }
}

#[gpui_kit::test]
fn checkpoint_operation_errors_stay_local_and_can_be_dismissed(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    let (handle, view) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds {
                    origin: Default::default(),
                    size: size(px(360.0), px(500.0)),
                })),
                ..Default::default()
            },
            cx,
            |window, cx| NativeComposerProbe::with_history(window, cx, true).view,
        )
        .unwrap()
    });
    for attempt in 1..=2 {
        view.update(cx, |view, cx| {
            view.command(
                std::future::ready(Err(crate::native_runtime::NativeRuntimeError::Checkpoint(
                    format!("test failure {attempt}"),
                ))),
                cx,
            );
        });
        cx.run_until_parked();
        cx.update_window(handle, |_, window, cx| {
            window.render_frame(cx);
            assert_eq!(window.find_all_by_label("Operation failed").len(), 1);
            assert!(window.find_by_label("Operation failed").visible());
            let view = view.read(cx);
            assert!(view
                .operation_error
                .as_ref()
                .is_some_and(|error| error.contains(&format!("test failure {attempt}"))));
            assert_eq!(view.state.session.thread.entries.len(), 1);
            assert!(matches!(
                &view.state.session.thread.entries[0],
                cgc_agent_ui::conversation::Entry::User { .. }
            ));
            assert!(view.metadata().checkpoints.is_empty());
            assert!(window
                .find_by_label("Rewind to before this message")
                .visible());
        })
        .unwrap();
    }
    for width in [260.0, 360.0] {
        cx.simulate_window_resize(handle, size(px(width), px(340.0)));
        cx.update_window(handle, |_, window, cx| {
            window.render_frame(cx);
            let error = window.find_by_label("Operation failed");
            assert!(error.visible());
            assert!(error.bounds().right() <= px(width));
            assert!(window.find_by_label("Dismiss error").visible());
        })
        .unwrap();
    }
    cx.update_window(handle, |_, window, cx| {
        window.click("native-dismiss-operation-error", cx);
        window.render_frame(cx);
        assert!(window.try_find_by_label("Operation failed").is_none());
        assert!(view.read(cx).operation_error.is_none());
        assert_eq!(view.read(cx).state.session.thread.entries.len(), 1);
    })
    .unwrap();
    let (sender, receiver) = futures::channel::oneshot::channel();
    view.update(cx, |view, cx| {
        view.command(async move { receiver.await.unwrap() }, cx);
        let snapshot = view.snapshot.as_ref().unwrap().clone();
        view.command(std::future::ready(Ok(snapshot)), cx);
    });
    sender
        .send(Err(crate::native_runtime::NativeRuntimeError::Checkpoint(
            "outdated failure".into(),
        )))
        .unwrap_or_else(|_| panic!("Operation receiver closed"));
    cx.run_until_parked();
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(
            window.try_find_by_label("Operation failed").is_none(),
            "An older failure must not replace a newer successful operation"
        );
        assert!(view.read(cx).operation_error.is_none());
    })
    .unwrap();
}

#[gpui_kit::test]
fn native_composer_uses_shared_editor_growth_and_preserves_draft(cx: &mut TestAppContext) {
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
            |window, cx| cx.new(|cx| NativeComposerProbe::new(window, cx)),
        )
        .unwrap()
    });
    cx.update_window(handle, |_, window, cx| {
        let input = probe.read(cx).input(cx);
        crate::composer_context::ui_tests::assert_shared_editor_growth(&input, window, cx);
        let send = window.find_by_label("发送");
        assert_eq!(send.bounds().size, size(px(24.0), px(24.0)));
        input.update(cx, |state, cx| state.set_value("/clear", window, cx));
        probe.update(cx, |_, cx| cx.notify());
        window.render_frame(cx);
        let menu = window.find("native-slash-popup");
        let editor = &window.find_all_by_role(gpui_kit::Role::MultilineTextInput)[0];
        assert!(menu.visible());
        assert!(menu.bounds().bottom() <= editor.bounds().top());
    })
    .unwrap();
    for (width, height) in [(260.0, 500.0), (380.0, 340.0), (260.0, 340.0)] {
        cx.simulate_window_resize(handle, size(px(width), px(height)));
        cx.update_window(handle, |_, window, cx| {
            let input = probe.read(cx).input(cx);
            input.update(cx, |state, cx| state.set_value("", window, cx));
            probe.update(cx, |_, cx| cx.notify());
            crate::composer_context::ui_tests::assert_shared_editor_growth(&input, window, cx);
            assert!(window.find_by_label("发送").visible());
        })
        .unwrap();
    }
}

#[gpui_kit::test]
fn native_composer_shows_and_removes_pending_agent_call(cx: &mut TestAppContext) {
    use cgc_courses::content::{AgentActionSpec, AgentIntent};

    cx.update(gpui_kit::init);
    let (handle, probe) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds {
                    origin: Default::default(),
                    size: size(px(420.0), px(600.0)),
                })),
                ..Default::default()
            },
            cx,
            |window, cx| cx.new(|cx| NativeComposerProbe::new(window, cx)),
        )
        .unwrap()
    });
    let call = crate::agent_call::AgentCall::from_action(
        &AgentActionSpec {
            id: "a-answer".into(),
            label: "Answer".into(),
            intent: AgentIntent::Answer,
            primary: true,
        },
        crate::agent_call::LearningTarget::Objective {
            course_id: "crs-1".into(),
            revision: Some(1),
            issue_id: "issue-1".into(),
            objective_id: "obj-1".into(),
        },
    );
    cx.update_window(handle, |_, window, cx| {
        let view = probe.read(cx).view.clone();
        view.update(cx, |view, cx| {
            view.compose_agent_call(
                call,
                "Please ask me a question".into(),
                "Answer".into(),
                window,
                cx,
            );
        });
        window.render_frame(cx);
        assert!(window.try_find("native-agent-call-chip").is_some());
        assert!(window.try_find("native-agent-call-remove").is_some());
        // 可访问名称必须是语义化的，而不是可见符号 "×"。
        assert_eq!(
            window.find("native-agent-call-remove").label(),
            Some("Remove learning action")
        );
        assert_eq!(
            view.read(cx).input.read(cx).value(),
            "Please ask me a question"
        );
        view.update(cx, |view, cx| view.steer(window, cx));
        assert!(view.read(cx).pending_agent_call.is_some());
        assert_eq!(
            view.read(cx).input.read(cx).value(),
            "Please ask me a question"
        );
        assert!(view.read(cx).status.contains("队列"));

        window.click("native-agent-call-remove", cx);
        window.render_frame(cx);
        assert!(window.try_find("native-agent-call-chip").is_none());
        assert!(view.read(cx).pending_agent_call.is_none());
    })
    .unwrap();
}

#[gpui_kit::test]
fn native_auto_send_keeps_composer_draft(cx: &mut TestAppContext) {
    use crate::agent_call::{AgentCall, LearningTarget};
    use cgc_courses::content::{AgentActionSpec, AgentIntent};

    cx.update(gpui_kit::init);
    let (handle, probe) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds {
                    origin: Default::default(),
                    size: size(px(420.0), px(600.0)),
                })),
                ..Default::default()
            },
            cx,
            |window, cx| cx.new(|cx| NativeComposerProbe::new(window, cx)),
        )
        .unwrap()
    });
    cx.update_window(handle, |_, window, cx| {
        let view = probe.read(cx).view.clone();
        let input = view.read(cx).input.clone();
        input.update(cx, |state, cx| state.set_value("draft answer", window, cx));
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
        view.update(cx, |view, cx| {
            assert!(view.send_agent_call(call, "automatic hint".into(), cx));
            assert_eq!(view.input.read(cx).value(), "draft answer");
            assert!(view.pending_agent_call.is_none());
        });
    })
    .unwrap();
}

/// AutoSend 回归：`send_agent_call` 必须先 `freeze_page` 再构造 Submission。
/// 若未来把 context 改回 `None`，page context 会整体丢失，MCP 拿不到
/// workspace/course 标识（此前线上症状）。session 保持 Idle，dispatch 不会
/// 跨线程发送；断言队列中 submission 已带完整 page context。发送链路
/// （send_with_context 注入正文）由 `conversation_session` envelope 测试覆盖。
#[gpui_kit::test]
fn native_auto_send_sends_page_context(cx: &mut TestAppContext) {
    use crate::agent_call::{AgentCall, LearningTarget};
    use crate::page_context::{CourseContext, PageBody, PageContext};
    use cgc_courses::content::{AgentActionSpec, AgentIntent};

    cx.update(gpui_kit::init);
    let (handle, probe) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds {
                    origin: Default::default(),
                    size: size(px(420.0), px(600.0)),
                })),
                ..Default::default()
            },
            cx,
            |window, cx| cx.new(|cx| NativeComposerProbe::new(window, cx)),
        )
        .unwrap()
    });
    cx.update_window(handle, |_, window, cx| {
        let view = probe.read(cx).view.clone();
        view.update(cx, |view, _| {
            view.page_context.set_current(Some(PageContext {
                workspace_id: Some("workspace-1".into()),
                tab_id: "course-tab".into(),
                route: "/courses/course-1/learn".into(),
                title: "Course".into(),
                version: "v1".into(),
                body: PageBody::Ready("complete course task body".into()),
                course: Some(CourseContext {
                    id: "course-1".into(),
                    title: "Course".into(),
                    revision: Some(1),
                    unit: None,
                }),
            }));
        });
        let call = AgentCall::from_action(
            &AgentActionSpec {
                id: "a-hint".into(),
                label: "Hint".into(),
                intent: AgentIntent::Hint,
                primary: false,
            },
            LearningTarget::Objective {
                course_id: "course-1".into(),
                revision: Some(1),
                issue_id: "issue-1".into(),
                objective_id: "obj-1".into(),
            },
        );
        view.update(cx, |view, cx| {
            assert!(view.send_agent_call(call, "automatic hint".into(), cx));
        });
    })
    .unwrap();
    let queued = cx.update(|cx| {
        let view = probe.read(cx).view.clone();
        let session = &view.read(cx).state.session;
        assert_eq!(
            session.queue.len(),
            1,
            "auto-send must queue one submission"
        );
        let submission = &session.queue[0];
        (
            submission.display.clone(),
            submission.prompt.clone(),
            submission
                .context
                .as_ref()
                .map(|context| context.page.clone()),
            submission.agent_call.is_some(),
        )
    });
    let (display, prompt, context_page, has_call) = queued;
    assert_eq!(display, "automatic hint", "display keeps the bare prompt");
    assert!(has_call, "queued submission carries the agent call");
    let context_page = context_page.expect("auto-send submission must freeze the page context");
    assert_eq!(
        context_page.workspace_id.as_deref(),
        Some("workspace-1"),
        "frozen context keeps the workspace identifier"
    );
    assert!(
        prompt.contains("workspace_id=workspace-1"),
        "auto-send prompt lost the workspace identifier: {prompt}"
    );
    assert!(
        prompt.contains("<active_tab_body>"),
        "auto-send prompt lost the page body: {prompt}"
    );
    assert!(
        prompt.contains("complete course task body"),
        "auto-send prompt lost the page body text: {prompt}"
    );
    assert!(
        prompt.contains("automatic hint"),
        "auto-send prompt lost the user prompt: {prompt}"
    );
}

#[path = "paste_tests.rs"]
mod paste_tests;
