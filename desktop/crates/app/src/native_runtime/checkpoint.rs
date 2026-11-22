use cgc_agent_checkpoint::{
    CheckpointError, GcMode, ObjectStoreStats, PrunedRef, ReclaimReport, DEFAULT_PRESSURE_KEEP_REFS,
};

use super::worker::{Job, Owner};
use super::*;

const CHECKPOINT_GC_COOLDOWN: std::time::Duration = std::time::Duration::from_secs(10 * 60);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum CheckpointGcRequest {
    Auto,
    ReclaimForBudget,
}

#[derive(Debug)]
pub(super) enum CheckpointGcOutcome {
    Auto {
        result: Result<ObjectStoreStats, CheckpointError>,
    },
    Reclaim {
        result: Result<ReclaimReport, CheckpointError>,
    },
}

impl Owner {
    pub(super) fn reload_checkpoints(&mut self) {
        match self
            .store
            .as_ref()
            .map(|store| store.list_checkpoints(&self.frozen.id))
        {
            Some(Ok(records)) => {
                self.checkpoints =
                    Arc::new(crate::native_view_model::checkpoints_from_records(&records))
            }
            Some(Err(error)) => self.notice(format!("读取检查点失败：{error}")),
            None => self.checkpoints = Arc::new(Vec::new()),
        }
    }

    pub(super) fn refresh_changes(&mut self) {
        let result = match (&self.checkpoint_manager, self.checkpoints.last()) {
            (Some(manager), Some((_, checkpoint))) => manager.changed_files(checkpoint),
            _ => {
                self.changes = Arc::new(Vec::new());
                return;
            }
        };
        match result {
            Ok(changes) => self.changes = Arc::new(changes),
            Err(error) => self.notice(format!("读取检查点变更失败：{error}")),
        }
    }

    pub(super) fn capture_checkpoint(&mut self, thread_id: &str, ordinal: usize) {
        if self.checkpoint_budget_exceeded {
            self.queue_checkpoint_gc(CheckpointGcRequest::ReclaimForBudget);
            return;
        }
        let Some(manager) = &self.checkpoint_manager else {
            if !self.checkpoint_notice_reported {
                self.checkpoint_notice_reported = true;
                self.notice("当前工作区没有可用的 Git 检查点，本轮文件改动无法回滚。".into());
            }
            return;
        };
        match manager.snapshot_with_report(thread_id, ordinal as u64) {
            Ok(report) => {
                if let Some(store) = &mut self.store {
                    if let Err(error) = store.save_thread(&self.frozen).and_then(|()| {
                        store.save_checkpoint(
                            &report.checkpoint,
                            ordinal as i64,
                            crate::native_context::now_secs(),
                        )
                    }) {
                        self.notice(format!("检查点映射尚未保存：{error}"));
                    }
                }
                let checkpoints = Arc::make_mut(&mut self.checkpoints);
                checkpoints.retain(|(existing, _)| *existing != ordinal);
                checkpoints.push((ordinal, report.checkpoint));
                checkpoints.sort_by_key(|(ordinal, _)| *ordinal);
                self.apply_pruned_refs(&report.pruned, false);
                self.checkpoint_budget_exceeded = false;
                self.checkpoint_budget_notice_reported = false;
                self.checkpoint_unrecoverable_notice_reported = false;
                if report.needs_gc {
                    self.queue_checkpoint_gc(CheckpointGcRequest::Auto);
                }
            }
            Err(CheckpointError::BudgetExceeded {
                used_bytes,
                limit_bytes,
            }) => {
                self.checkpoint_budget_exceeded = true;
                if !self.checkpoint_budget_notice_reported {
                    self.checkpoint_budget_notice_reported = true;
                    self.notice(format!(
                        "检查点对象库已超过容量上限（{} / {}），已暂停本轮快照并触发后台清理。",
                        format_bytes(used_bytes),
                        format_bytes(limit_bytes),
                    ));
                }
                self.queue_checkpoint_gc(CheckpointGcRequest::ReclaimForBudget);
            }
            Err(error) => self.notice(format!("本轮未创建检查点：{error}（文件改动无法回滚）")),
        }
    }

    pub(super) fn apply_pruned_refs(&mut self, pruned: &[PrunedRef], same_repo: bool) {
        if pruned.is_empty() {
            return;
        }
        let current_thread_id = self.frozen.id.clone();
        for item in pruned {
            if let Some(store) = &mut self.store {
                if let Err(error) = store.mark_checkpoint_invalid(&item.thread_id, item.seq as i64)
                {
                    log::warn!(target: "native", "mark pruned checkpoint invalid failed: {error}");
                }
            }
            if item.thread_id == current_thread_id {
                let target_ordinal = item.seq as usize;
                Arc::make_mut(&mut self.checkpoints)
                    .retain(|(ordinal, _)| *ordinal != target_ordinal);
            }
        }
        if same_repo {
            self.refresh_changes();
            self.publish(RuntimeChange::Checkpoint);
        }
    }

    pub(super) fn invalidate_checkpoints(&mut self, from: usize) -> Result<(), NativeRuntimeError> {
        if let Some(store) = &mut self.store {
            for (ordinal, _) in self
                .checkpoints
                .iter()
                .filter(|(ordinal, _)| *ordinal >= from)
            {
                store
                    .mark_checkpoint_invalid(&self.frozen.id, *ordinal as i64)
                    .map_err(|error| NativeRuntimeError::Storage(error.to_string()))?;
            }
        }
        Arc::make_mut(&mut self.checkpoints).retain(|(ordinal, _)| *ordinal < from);
        if let Some(manager) = &self.checkpoint_manager {
            match manager.delete_refs_from(&self.frozen.id, from as u64) {
                Ok(deleted) if !deleted.is_empty() => {
                    self.queue_checkpoint_gc(CheckpointGcRequest::Auto);
                    self.maybe_start_checkpoint_gc();
                }
                Ok(_) => {}
                Err(error) => self.notice(format!("清理 Git 检查点引用失败：{error}")),
            }
        }
        Ok(())
    }

    pub(super) fn queue_checkpoint_gc(&mut self, request: CheckpointGcRequest) {
        self.checkpoint_gc_pending = Some(match (self.checkpoint_gc_pending, request) {
            (Some(CheckpointGcRequest::ReclaimForBudget), _)
            | (_, CheckpointGcRequest::ReclaimForBudget) => CheckpointGcRequest::ReclaimForBudget,
            _ => CheckpointGcRequest::Auto,
        });
    }

    pub(super) fn maybe_start_checkpoint_gc(&mut self) {
        if self.active.is_some() || self.checkpoint_gc_running {
            return;
        }
        let Some(request) = self.checkpoint_gc_pending else {
            return;
        };
        let cooldown_applies = matches!(request, CheckpointGcRequest::Auto)
            || (matches!(request, CheckpointGcRequest::ReclaimForBudget)
                && self.checkpoint_unrecoverable_notice_reported);
        if cooldown_applies
            && self
                .last_checkpoint_gc_at
                .is_some_and(|last| last.elapsed() < CHECKPOINT_GC_COOLDOWN)
        {
            return;
        }
        let Some(manager) = self.checkpoint_manager.clone() else {
            self.checkpoint_gc_pending = None;
            return;
        };
        self.checkpoint_gc_pending = None;
        self.checkpoint_gc_running = true;
        let current_thread_id = self.frozen.id.clone();
        let repo = manager.repo().to_path_buf();
        let (sender, receiver) = oneshot::channel();
        let spawned = std::thread::Builder::new()
            .name("cgc-checkpoint-gc".into())
            .spawn(move || {
                let outcome = match request {
                    CheckpointGcRequest::Auto => CheckpointGcOutcome::Auto {
                        result: manager.run_gc(GcMode::Auto),
                    },
                    CheckpointGcRequest::ReclaimForBudget => CheckpointGcOutcome::Reclaim {
                        result: manager
                            .reclaim_for_budget(&current_thread_id, DEFAULT_PRESSURE_KEEP_REFS),
                    },
                };
                let _ = sender.send(outcome);
            });
        if let Err(error) = spawned {
            log::warn!(target: "native", "failed to spawn checkpoint gc thread: {error}");
            self.checkpoint_gc_running = false;
            self.checkpoint_gc_pending = Some(request);
            return;
        }
        self.jobs.push(Box::pin(async move {
            let outcome = match receiver.await {
                Ok(outcome) => outcome,
                Err(_) => match request {
                    CheckpointGcRequest::Auto => CheckpointGcOutcome::Auto {
                        result: Err(CheckpointError::Io("checkpoint gc worker cancelled".into())),
                    },
                    CheckpointGcRequest::ReclaimForBudget => CheckpointGcOutcome::Reclaim {
                        result: Err(CheckpointError::Io(
                            "checkpoint reclaim worker cancelled".into(),
                        )),
                    },
                },
            };
            Job::CheckpointGc {
                repo,
                request,
                outcome,
            }
        }));
    }

    pub(super) fn checkpoint_gc_completed(
        &mut self,
        repo: PathBuf,
        _request: CheckpointGcRequest,
        outcome: CheckpointGcOutcome,
    ) {
        self.checkpoint_gc_running = false;
        let same_repo = self
            .checkpoint_manager
            .as_ref()
            .is_some_and(|manager| manager.repo() == repo);
        if same_repo {
            self.last_checkpoint_gc_at = Some(std::time::Instant::now());
        }
        match outcome {
            CheckpointGcOutcome::Auto { result: Err(error) } if same_repo => {
                log::warn!(target: "native", "background checkpoint gc failed: {error}");
            }
            CheckpointGcOutcome::Auto { .. } => {}
            CheckpointGcOutcome::Reclaim {
                result: Ok(reclaim),
            } => {
                // SQLite 会话库跨 scope 共享：即便 GC 期间切了 scope 也必须标记已删 ref 为 invalid。
                self.apply_pruned_refs(&reclaim.pruned, same_repo);
                if same_repo {
                    if reclaim.within_budget {
                        self.checkpoint_budget_exceeded = false;
                        self.checkpoint_budget_notice_reported = false;
                        self.checkpoint_unrecoverable_notice_reported = false;
                    } else {
                        self.checkpoint_budget_exceeded = true;
                        if !self.checkpoint_unrecoverable_notice_reported {
                            self.checkpoint_unrecoverable_notice_reported = true;
                            self.notice(format!(
                                "检查点对象库清理后仍超过容量上限（{} / {}），已暂停新检查点；不会删除你的 Git 分支或提交。",
                                format_bytes(reclaim.stats_after.total_bytes()),
                                format_bytes(reclaim.limit_bytes),
                            ));
                        }
                    }
                }
            }
            CheckpointGcOutcome::Reclaim { result: Err(error) } => {
                self.apply_pruned_refs(error.pruned_refs(), same_repo);
                if same_repo {
                    log::warn!(target: "native", "background checkpoint reclaim failed: {error}");
                }
            }
        }
        self.maybe_start_checkpoint_gc();
    }

    pub(super) fn rewind(
        &mut self,
        ordinal: usize,
        restore_files: bool,
    ) -> Result<Arc<NativeRuntimeSnapshot>, NativeRuntimeError> {
        self.idle()?;
        let agent = self.agent.as_ref().ok_or(NativeRuntimeError::Closed)?;
        let index =
            crate::native_view_model::thread_user_entry_index(&agent.thread().entries, ordinal)
                .ok_or_else(|| NativeRuntimeError::Checkpoint("消息已不在当前会话中".into()))?;
        if restore_files {
            let checkpoint = self
                .checkpoints
                .iter()
                .find(|(candidate, _)| *candidate == ordinal)
                .map(|(_, checkpoint)| checkpoint.clone())
                .ok_or_else(|| NativeRuntimeError::Checkpoint("该消息没有可恢复的检查点".into()))?;
            let manager = self.checkpoint_manager.as_ref().ok_or_else(|| {
                NativeRuntimeError::Checkpoint("当前工作区没有 Git 检查点".into())
            })?;
            if !manager
                .is_valid(&checkpoint)
                .map_err(|error| NativeRuntimeError::Checkpoint(error.to_string()))?
            {
                if let Some(store) = &mut self.store {
                    store
                        .mark_checkpoint_invalid(&self.frozen.id, ordinal as i64)
                        .map_err(|error| NativeRuntimeError::Storage(error.to_string()))?;
                }
                self.reload_checkpoints();
                return Err(NativeRuntimeError::Checkpoint(
                    "检查点已失效（工作区 HEAD 已变化）".into(),
                ));
            }
            manager
                .restore(&checkpoint)
                .map_err(|error| NativeRuntimeError::Checkpoint(error.to_string()))?;
        }
        self.agent
            .as_mut()
            .ok_or(NativeRuntimeError::Closed)?
            .thread_mut()
            .entries
            .truncate(index);
        if let Some(agent) = &mut self.agent {
            agent
                .thread_mut()
                .user_drafts
                .truncate(ordinal.saturating_sub(1));
        }
        self.invalidate_checkpoints(ordinal)?;
        self.prepared = None;
        self.generation = self.generation.wrapping_add(1);
        self.cancel_title();
        self.persist();
        self.freeze();
        self.refresh_changes();
        self.publish(RuntimeChange::Rewound);
        Ok(self.snapshot())
    }

    pub(super) fn checkpoint(
        &mut self,
        action: CheckpointAction,
    ) -> Result<Arc<NativeRuntimeSnapshot>, NativeRuntimeError> {
        self.idle()?;
        match action {
            CheckpointAction::KeepAll => Arc::make_mut(&mut self.changes).clear(),
            CheckpointAction::KeepFile(path) => {
                Arc::make_mut(&mut self.changes).retain(|change| change.path != path)
            }
            action => {
                let checkpoint = self
                    .checkpoints
                    .last()
                    .map(|(_, checkpoint)| checkpoint)
                    .ok_or_else(|| NativeRuntimeError::Checkpoint("没有可用的检查点".into()))?;
                let manager = self.checkpoint_manager.as_ref().ok_or_else(|| {
                    NativeRuntimeError::Checkpoint("当前工作区没有 Git 检查点".into())
                })?;
                if !manager
                    .is_valid(checkpoint)
                    .map_err(|error| NativeRuntimeError::Checkpoint(error.to_string()))?
                {
                    return Err(NativeRuntimeError::Checkpoint(
                        "检查点已失效（工作区 HEAD 已变化）".into(),
                    ));
                }
                match action {
                    CheckpointAction::RestoreAll => manager.restore(checkpoint),
                    CheckpointAction::RestoreFile(path) => manager.restore_file(checkpoint, &path),
                    _ => unreachable!("keep actions handled above"),
                }
                .map_err(|error| NativeRuntimeError::Checkpoint(error.to_string()))?;
                self.refresh_changes();
            }
        }
        self.publish(RuntimeChange::Checkpoint);
        Ok(self.snapshot())
    }

    pub(super) fn inspect_checkpoint_storage(
        &self,
        reply: Reply<Option<CheckpointStorageSummary>>,
    ) {
        let Some(manager) = self.checkpoint_manager.clone() else {
            let _ = reply.send(Ok(None));
            return;
        };
        let _ = std::thread::Builder::new()
            .name("cgc-checkpoint-stats".into())
            .spawn(move || {
                let result = manager
                    .storage_summary()
                    .map(Some)
                    .map_err(|error| NativeRuntimeError::Checkpoint(error.to_string()));
                let _ = reply.send(result);
            });
    }

    pub(super) fn start_manual_checkpoint_cleanup(&mut self, reply: Reply<ReclaimReport>) {
        if self.active.is_some() || self.checkpoint_gc_running {
            let _ = reply.send(Err(NativeRuntimeError::Busy));
            return;
        }
        let Some(manager) = self.checkpoint_manager.clone() else {
            let _ = reply.send(Err(NativeRuntimeError::Checkpoint(
                "当前工作区没有可用的 Git 检查点".into(),
            )));
            return;
        };
        self.checkpoint_gc_running = true;
        self.checkpoint_gc_pending = None;
        let current_thread_id = self.frozen.id.clone();
        let repo = manager.repo().to_path_buf();
        let (sender, receiver) = oneshot::channel();
        let spawned = std::thread::Builder::new()
            .name("cgc-checkpoint-purge".into())
            .spawn(move || {
                let result = manager.purge_history_checkpoints(Some(&current_thread_id), 1);
                let _ = sender.send(result);
            });
        if let Err(error) = spawned {
            self.checkpoint_gc_running = false;
            let _ = reply.send(Err(NativeRuntimeError::Checkpoint(error.to_string())));
            return;
        }
        self.jobs.push(Box::pin(async move {
            let result = match receiver.await {
                Ok(result) => result,
                Err(_) => Err(CheckpointError::Io(
                    "manual checkpoint purge cancelled".into(),
                )),
            };
            Job::ManualCheckpointCleanup {
                repo,
                reply,
                result,
            }
        }));
    }

    pub(super) fn manual_checkpoint_cleanup_completed(
        &mut self,
        repo: PathBuf,
        reply: Reply<ReclaimReport>,
        result: Result<ReclaimReport, CheckpointError>,
    ) {
        self.checkpoint_gc_running = false;
        let same_repo = self
            .checkpoint_manager
            .as_ref()
            .is_some_and(|manager| manager.repo() == repo);
        let mapped = match result {
            Ok(report) => {
                self.apply_pruned_refs(&report.pruned, false);
                if same_repo {
                    self.last_checkpoint_gc_at = Some(std::time::Instant::now());
                    self.checkpoint_budget_exceeded = !report.within_budget;
                    if report.within_budget {
                        self.checkpoint_budget_notice_reported = false;
                        self.checkpoint_unrecoverable_notice_reported = false;
                    }
                    self.refresh_changes();
                    self.publish(RuntimeChange::Checkpoint);
                }
                Ok(report)
            }
            Err(error) => {
                self.apply_pruned_refs(error.pruned_refs(), same_repo);
                Err(NativeRuntimeError::Checkpoint(error.to_string()))
            }
        };
        let _ = reply.send(mapped);
        self.maybe_start_checkpoint_gc();
    }
}

pub(crate) fn format_bytes(bytes: u64) -> String {
    const KIB: f64 = 1024.0;
    const MIB: f64 = 1024.0 * 1024.0;
    if bytes as f64 >= MIB {
        format!("{:.1} MiB", bytes as f64 / MIB)
    } else if bytes as f64 >= KIB {
        format!("{:.1} KiB", bytes as f64 / KIB)
    } else {
        format!("{bytes} B")
    }
}
