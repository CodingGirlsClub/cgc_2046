use super::worker::Owner;
use super::*;

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
        let Some(manager) = &self.checkpoint_manager else {
            if !self.checkpoint_notice_reported {
                self.checkpoint_notice_reported = true;
                self.notice("当前工作区没有可用的 Git 检查点，本轮文件改动无法回滚。".into());
            }
            return;
        };
        let result = manager.snapshot(thread_id, ordinal as u64);
        match result {
            Ok(checkpoint) => {
                if let Some(store) = &mut self.store {
                    if let Err(error) = store.save_thread(&self.frozen).and_then(|()| {
                        store.save_checkpoint(
                            &checkpoint,
                            ordinal as i64,
                            crate::native_context::now_secs(),
                        )
                    }) {
                        self.notice(format!("检查点映射尚未保存：{error}"));
                    }
                }
                let checkpoints = Arc::make_mut(&mut self.checkpoints);
                checkpoints.retain(|(existing, _)| *existing != ordinal);
                checkpoints.push((ordinal, checkpoint));
                checkpoints.sort_by_key(|(ordinal, _)| *ordinal);
            }
            Err(error) => self.notice(format!("本轮未创建检查点：{error}（文件改动无法回滚）")),
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
        Ok(())
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
        self.invalidate_checkpoints(ordinal)?;
        self.prepared = None;
        self.generation = self.generation.wrapping_add(1);
        self.title_serial = self.title_serial.wrapping_add(1);
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
}
