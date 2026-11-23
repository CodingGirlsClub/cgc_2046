use std::path::PathBuf;

use cgc_agent_checkpoint::{CheckpointStorageSummary, ObjectStoreStats, PrunedRef, ReclaimReport};

use super::CheckpointSettingsState;
use crate::native_runtime::{NativeRuntimeError, WorkspaceCheckpointStorage};

#[test]
fn state_transitions_format_summary_and_cleanup_feedback() {
    let mut state = CheckpointSettingsState::for_runtime(true);
    state.loading = true;
    assert_eq!(state.status_line().0, "正在统计检查点仓库占用…");

    let repo_a = PathBuf::from("/tmp/cgc-alpha-workspace");
    state.apply_summary(
        Ok(Some(WorkspaceCheckpointStorage {
            repo: repo_a.clone(),
            summary: CheckpointStorageSummary {
                stats: ObjectStoreStats {
                    loose_bytes: 2 * 1024 * 1024,
                    pack_bytes: 512 * 1024,
                    ..Default::default()
                },
                total_refs: 12,
                limit_bytes: 500 * 1024 * 1024,
            },
        })),
        true,
    );
    assert!(!state.loading);
    assert_eq!(state.repo.as_ref(), Some(&repo_a));
    let (line, over) = state.status_line();
    assert!(
        !over
            && line.contains("cgc-alpha-workspace")
            && line.contains("2.5 MiB / 500.0 MiB")
            && line.contains("共 12 个检查点"),
        "line: {line}"
    );
    assert_eq!(state.button_label(), "清理全部历史检查点");

    state.armed = true;
    assert_eq!(state.button_label(), "再次点击确认清理");

    assert!(!state.apply_cleanup(Ok(ReclaimReport {
        pruned: vec![PrunedRef {
            thread_id: "t1".into(),
            seq: 1,
            ref_name: "refs/cgc/checkpoints/t1/1".into(),
        }],
        remaining_refs: 1,
        stats_after: ObjectStoreStats {
            loose_bytes: 192 * 1024,
            ..Default::default()
        },
        within_budget: true,
        limit_bytes: 500 * 1024 * 1024,
    })));
    assert!(!state.armed && !state.cleaning);
    assert_eq!(state.summary.unwrap().total_refs, 1);
    let notice = state.notice.as_deref().unwrap();
    assert!(notice.contains("已清理 1 个历史检查点") && notice.contains("保留当前对话最新 1 条"));

    // 工作区切换拒绝清理时：重置确认与旧仓库缓存、保留错误提示并返回需要刷新信号。
    state.armed = true;
    assert!(state.apply_cleanup(Err(NativeRuntimeError::WorkspaceChanged)));
    assert!(!state.armed && !state.cleaning);
    assert!(state.repo.is_none());
    assert!(state.summary.is_none());
    assert!(state.notice.is_none());
    assert!(state
        .error
        .as_deref()
        .is_some_and(|message| message.contains("当前工作区已切换")));

    // `clear_error = false` 的后续自动刷新完成后，仍应保留错误提示并更新到新仓库摘要。
    let repo_b = PathBuf::from("/tmp/cgc-beta-workspace");
    state.apply_summary(
        Ok(Some(WorkspaceCheckpointStorage {
            repo: repo_b.clone(),
            summary: CheckpointStorageSummary {
                stats: ObjectStoreStats::default(),
                total_refs: 3,
                limit_bytes: 500 * 1024 * 1024,
            },
        })),
        false,
    );
    assert_eq!(state.repo.as_ref(), Some(&repo_b));
    assert!(state
        .error
        .as_deref()
        .is_some_and(|message| message.contains("当前工作区已切换")));
}

#[cfg(cgc_ui_tests)]
mod ui_tests {
    use std::path::PathBuf;
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;

    use cgc_agent_checkpoint::CheckpointManager;
    use cgc_agent_core::{SelectedModel, Thread};
    use cgc_agent_provider::{EchoProvider, Model, ModelLimits, ProviderId};
    use cgc_agent_store::SessionStore;
    use cgc_agent_tools::{ToolContext, ToolRegistry};
    use cgc_platform::session::FakeAuthApi;
    use gpui_kit::test::TestWindowExt;
    use gpui_kit::{
        px, size, AppContext, Bounds, Entity, TestAppContext, VisualTestContext, WeakEntity,
        WindowBounds, WindowOptions,
    };

    use crate::i18n::Language;
    use crate::native_runtime::{NativeRuntimeConfig, NativeRuntimeHandle};
    use crate::settings_window::SettingsWindowView;

    fn seed_repo_with_checkpoints(
        root: &std::path::Path,
        runtime: &NativeRuntimeHandle,
        scope_key: &str,
        old_count: u64,
        current_count: u64,
    ) -> (CheckpointManager, String) {
        std::fs::create_dir_all(root).unwrap();
        let manager = CheckpointManager::initialize(root).unwrap();
        for seq in 1..=old_count {
            std::fs::write(root.join("a.txt"), format!("old-{seq}\n")).unwrap();
            manager.snapshot("old-thread", seq).unwrap();
        }
        let scope = crate::agent_scope::AgentScope {
            key: scope_key.into(),
            root: root.to_path_buf(),
        };
        let active_thread_id = futures::executor::block_on(runtime.switch_scope(scope))
            .expect("switch scope")
            .thread
            .id
            .clone();
        for seq in 1..=current_count {
            std::fs::write(root.join("a.txt"), format!("cur-{seq}\n")).unwrap();
            manager.snapshot(&active_thread_id, seq).unwrap();
        }
        (manager, active_thread_id)
    }

    fn spawn_test_runtime(root: &std::path::Path) -> NativeRuntimeHandle {
        let model = Model::new(
            ProviderId::new("test"),
            "Test",
            "m1",
            "m1",
            ModelLimits::new(8_000, 1_000),
        );
        let thread = Thread::new(
            "ui-thread",
            SelectedModel::new(model.provider_id.clone(), model.id.clone()),
        );
        NativeRuntimeHandle::spawn(
            thread,
            None,
            NativeRuntimeConfig {
                provider: Arc::new(EchoProvider::new(model.clone())),
                model,
                registry: Arc::new(ToolRegistry::new()),
                context: ToolContext::new(root),
                context_size: 8_000,
                auto_approve: false,
            },
            Some(SessionStore::open_in_memory().unwrap()),
        )
    }

    fn open_settings_ai(
        cx: &mut TestAppContext,
        runtime: NativeRuntimeHandle,
    ) -> (VisualTestContext, Entity<SettingsWindowView>) {
        cx.update(gpui_kit::init);
        let bounds = cx.update(|cx| Bounds::centered(None, size(px(620.0), px(900.0)), cx));
        let options = WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(bounds)),
            ..Default::default()
        };
        let (handle, settings) = cx.update(|cx| {
            gpui_kit::open_window(options, cx, |_, cx| {
                cx.new(|cx| {
                    let mut view = SettingsWindowView::new(
                        Language::Zh,
                        None,
                        "cp-ui-user".into(),
                        Some("Checkpoint UI".into()),
                        String::new(),
                        Arc::new(FakeAuthApi::demo()),
                        Arc::new(AtomicBool::new(false)),
                        Some(runtime),
                        WeakEntity::new_invalid(),
                        cx,
                    );
                    view.open_ai(cx);
                    view
                })
            })
            .expect("settings window")
        });
        (VisualTestContext::from_window(handle, cx), settings)
    }

    fn wait_for(
        visual: &mut VisualTestContext,
        attempts: usize,
        delay_ms: u64,
        mut pred: impl FnMut(&mut VisualTestContext) -> bool,
    ) {
        for _ in 0..attempts {
            visual.run_until_parked();
            if pred(visual) {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(delay_ms));
        }
    }

    #[gpui_kit::test]
    fn settings_ai_page_displays_checkpoint_storage_and_purges_history_on_double_confirm(
        cx: &mut TestAppContext,
    ) {
        cx.executor().allow_parking();
        let root: PathBuf =
            std::env::temp_dir().join(format!("cgc-settings-cp-ui-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let runtime = spawn_test_runtime(&root);
        let (manager, active_thread_id) =
            seed_repo_with_checkpoints(&root, &runtime, "cp-ui", 2, 2);

        let (mut visual, settings) = open_settings_ai(cx, runtime);
        wait_for(&mut visual, 40, 10, |visual| {
            visual.update(|_, cx| {
                settings
                    .read(cx)
                    .checkpoint_storage_summary_for_test()
                    .is_some()
            })
        });
        visual.update(|window, cx| {
            window.render_frame(cx);
            assert!(window.find("settings-clear-checkpoint-history").visible());
            assert!(window.find("settings-refresh-checkpoint-storage").visible());
            let summary = settings
                .read(cx)
                .checkpoint_storage_summary_for_test()
                .expect("loaded summary");
            assert_eq!(summary.total_refs, 4);
        });

        visual.update(|_, cx| settings.update(cx, |view, cx| view.trigger_checkpoint_cleanup(cx)));
        assert_eq!(manager.storage_summary().unwrap().total_refs, 4);

        visual.update(|_, cx| settings.update(cx, |view, cx| view.trigger_checkpoint_cleanup(cx)));
        wait_for(&mut visual, 60, 15, |visual| {
            visual.update(|_, cx| {
                settings
                    .read(cx)
                    .checkpoint_storage_notice_for_test()
                    .is_some()
            })
        });

        visual.update(|_, cx| {
            let view = settings.read(cx);
            let notice = view.checkpoint_storage_notice_for_test().unwrap();
            assert!(notice.contains("已清理 3 个历史检查点"), "notice: {notice}");
            let summary = view.checkpoint_storage_summary_for_test().unwrap();
            assert_eq!(summary.total_refs, 1);
        });
        assert_eq!(manager.storage_summary().unwrap().total_refs, 1);
        assert!(manager.list("old-thread").unwrap().is_empty());
        assert_eq!(manager.list(&active_thread_id).unwrap()[0].seq, 2);
        let _ = std::fs::remove_dir_all(root);
    }

    #[gpui_kit::test]
    fn settings_ai_page_rejects_armed_cleanup_after_scope_switch_and_refreshes(
        cx: &mut TestAppContext,
    ) {
        cx.executor().allow_parking();
        let root_a: PathBuf =
            std::env::temp_dir().join(format!("cgc-settings-cp-a-{}", uuid::Uuid::new_v4()));
        let root_b: PathBuf =
            std::env::temp_dir().join(format!("cgc-settings-cp-b-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root_a).unwrap();
        let runtime = spawn_test_runtime(&root_a);
        let (manager_a, _) = seed_repo_with_checkpoints(&root_a, &runtime, "scope-a", 2, 2);
        let (mut visual, settings) = open_settings_ai(cx, runtime.clone());
        wait_for(&mut visual, 40, 10, |visual| {
            visual.update(|_, cx| {
                settings
                    .read(cx)
                    .checkpoint_storage_summary_for_test()
                    .is_some()
            })
        });

        // 在工作区 A 进入二次确认（armed）状态。
        visual.update(|_, cx| settings.update(cx, |view, cx| view.trigger_checkpoint_cleanup(cx)));
        visual.update(|_, cx| assert!(settings.read(cx).checkpoint_storage_armed_for_test()));

        // 主窗口切换到工作区 B，但 Settings 窗口仍保持打开。
        let (manager_b, thread_b) = seed_repo_with_checkpoints(&root_b, &runtime, "scope-b", 1, 2);

        // 在 Settings 窗口点击确认清理：必须拒绝误清 B，给出切换提示并自动刷新为 B 的统计。
        visual.update(|_, cx| settings.update(cx, |view, cx| view.trigger_checkpoint_cleanup(cx)));
        wait_for(&mut visual, 60, 15, |visual| {
            visual.update(|_, cx| {
                let view = settings.read(cx);
                view.checkpoint_storage_error_for_test().is_some()
                    && view
                        .checkpoint_storage_summary_for_test()
                        .is_some_and(|summary| summary.total_refs == 3)
            })
        });

        visual.update(|_, cx| {
            let view = settings.read(cx);
            let error = view.checkpoint_storage_error_for_test().unwrap();
            assert!(error.contains("当前工作区已切换"), "error: {error}");
            assert!(!view.checkpoint_storage_armed_for_test());
            assert_eq!(
                view.checkpoint_storage_summary_for_test()
                    .unwrap()
                    .total_refs,
                3
            );
        });
        assert_eq!(manager_a.storage_summary().unwrap().total_refs, 4);
        assert_eq!(manager_b.storage_summary().unwrap().total_refs, 3);

        // 用户看到刷新后的 B 信息并重新二次确认后，仅清理 B，A 依然完好。
        visual.update(|_, cx| settings.update(cx, |view, cx| view.trigger_checkpoint_cleanup(cx)));
        visual.update(|_, cx| settings.update(cx, |view, cx| view.trigger_checkpoint_cleanup(cx)));
        wait_for(&mut visual, 60, 15, |visual| {
            visual.update(|_, cx| {
                settings
                    .read(cx)
                    .checkpoint_storage_notice_for_test()
                    .is_some()
            })
        });
        assert_eq!(manager_b.storage_summary().unwrap().total_refs, 1);
        assert!(manager_b.list("old-thread").unwrap().is_empty());
        assert_eq!(manager_b.list(&thread_b).unwrap()[0].seq, 2);
        assert_eq!(manager_a.storage_summary().unwrap().total_refs, 4);

        let _ = std::fs::remove_dir_all(root_a);
        let _ = std::fs::remove_dir_all(root_b);
    }
}
