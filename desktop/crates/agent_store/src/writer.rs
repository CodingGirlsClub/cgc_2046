//! 单后台 writer：SQLite 连接只在 worker 线程创建与使用，UI 线程不阻塞。
//!
//! 语义（Plan 004）：
//! - 按 thread 合并尚未写入的快照，只保留最高 revision；
//! - `Clear` 会丢弃该 thread 的待写快照，旧内容不能复活；
//! - `flush` 是把此前已接受的写全部 commit 后才返回的栅栏。

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::mpsc::{sync_channel, Receiver, SyncSender};
use std::time::Duration;

use cgc_agent_core::Thread;

use crate::conversations::ConversationStore;
use crate::sessions::SessionStore;
use crate::snapshot::{SavedConversation, SnapshotSource};

/// 队列容量：满了就返回失败让调用方保留 dirty，而不是静默丢弃。
pub const MAILBOX_CAPACITY: usize = 64;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum StoreTarget {
    Acp,
    Native,
}

pub enum WriterCommand {
    Snapshot {
        target: StoreTarget,
        thread: Option<Box<Thread>>,
        snapshot: Box<SavedConversation>,
    },
    Clear {
        target: StoreTarget,
        thread_id: String,
    },
    Flush(SyncSender<Result<(), String>>),
}

pub struct StoreWriter {
    sender: SyncSender<Envelope>,
    next_seq: std::sync::atomic::AtomicU64,
}

/// 提交序号：`Clear` 按它作废「提交更早、但更晚才被 worker 处理」的快照。
struct Envelope {
    seq: u64,
    command: WriterCommand,
}

impl StoreWriter {
    /// 每个数据根一个 writer；两个库各自持有独立连接。
    pub fn spawn(conversations_db: PathBuf, threads_db: PathBuf) -> Self {
        let (sender, receiver) = sync_channel::<Envelope>(MAILBOX_CAPACITY);
        std::thread::Builder::new()
            .name("cgc-store-writer".into())
            .spawn(move || run(conversations_db, threads_db, receiver))
            .expect("start store writer");
        Self {
            sender,
            next_seq: std::sync::atomic::AtomicU64::new(1),
        }
    }

    /// 非阻塞提交；队列满时返回 `false`，调用方应保留 dirty 状态重试。
    pub fn submit(&self, command: WriterCommand) -> bool {
        let seq = self
            .next_seq
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        match self.sender.try_send(Envelope { seq, command }) {
            Ok(()) => true,
            Err(std::sync::mpsc::TrySendError::Full(_)) => false,
            Err(std::sync::mpsc::TrySendError::Disconnected(_)) => false,
        }
    }

    /// 等待此前已接受的全部写入 commit。
    pub fn flush(&self, timeout: Duration) -> Result<(), String> {
        let (reply, result) = sync_channel(1);
        if !self.submit(WriterCommand::Flush(reply)) {
            return Err("writer 队列已满，无法确认落盘".to_string());
        }
        result
            .recv_timeout(timeout)
            .map_err(|_| "writer 未在超时内完成落盘".to_string())?
    }
}

fn run(conversations_db: PathBuf, threads_db: PathBuf, receiver: Receiver<Envelope>) {
    let mut conversations: Option<ConversationStore> = None;
    let mut sessions: Option<SessionStore> = None;
    // 每个 thread 最近一次 Clear 的提交序号：序号更小的快照一律丢弃。
    let mut cleared: HashMap<(StoreTarget, String), u64> = HashMap::new();
    while let Ok(envelope) = receiver.recv() {
        let mut pending: HashMap<(StoreTarget, String), WriterCommand> = HashMap::new();
        let mut clears: Vec<(u64, StoreTarget, String)> = Vec::new();
        let mut flush: Option<SyncSender<Result<(), String>>> = None;
        let absorb = |seq: u64,
                      command: WriterCommand,
                      pending: &mut HashMap<(StoreTarget, String), WriterCommand>,
                      clears: &mut Vec<(u64, StoreTarget, String)>,
                      flush: &mut Option<SyncSender<Result<(), String>>>| {
            match command {
                WriterCommand::Snapshot {
                    target,
                    thread,
                    snapshot,
                } => {
                    let key = (target, snapshot.thread_id.clone());
                    let revision = snapshot.revision;
                    let replace = match pending.get(&key) {
                        Some(WriterCommand::Snapshot { snapshot, .. }) => {
                            revision >= snapshot.revision
                        }
                        _ => true,
                    };
                    if replace {
                        pending.insert(
                            key,
                            WriterCommand::Snapshot {
                                target,
                                thread,
                                snapshot,
                            },
                        );
                    }
                }
                WriterCommand::Clear { target, thread_id } => clears.push((seq, target, thread_id)),
                WriterCommand::Flush(reply) => *flush = Some(reply),
            }
        };
        absorb(
            envelope.seq,
            envelope.command,
            &mut pending,
            &mut clears,
            &mut flush,
        );
        // 合并窗口：把已排队但未阻塞的后续命令一起吸收，最多吸收到 flush 为止。
        while let Ok(next) = receiver.try_recv() {
            let stop = matches!(next.command, WriterCommand::Flush(_));
            absorb(
                next.seq,
                next.command,
                &mut pending,
                &mut clears,
                &mut flush,
            );
            if stop {
                break;
            }
        }

        let mut failure: Option<String> = None;
        for (seq, target, thread_id) in clears {
            // 清空先于同批快照生效：被清掉的 thread 的待写快照直接丢弃。
            pending.remove(&(target, thread_id.clone()));
            let slot = cleared.entry((target, thread_id.clone())).or_insert(0);
            *slot = (*slot).max(seq);
            let result = match target {
                StoreTarget::Acp => conversations_store(&mut conversations, &conversations_db)
                    .and_then(|store| {
                        store
                            .delete_thread(&thread_id)
                            .map(|_| ())
                            .map_err(|error| error.to_string())
                    }),
                StoreTarget::Native => {
                    sessions_store(&mut sessions, &threads_db).and_then(|store| {
                        store
                            .delete_thread(&thread_id)
                            .map(|_| ())
                            .map_err(|error| error.to_string())
                    })
                }
            };
            if let Err(error) = result {
                failure = Some(error);
            }
        }
        for (key, command) in pending {
            if let WriterCommand::Snapshot {
                target,
                thread,
                snapshot,
            } = command
            {
                if cleared
                    .get(&key)
                    .is_some_and(|clear_seq| *clear_seq > snapshot.revision)
                {
                    // 已被清空作废；不写回。
                    continue;
                }
                let result = match target {
                    StoreTarget::Acp => conversations_store(&mut conversations, &conversations_db)
                        .and_then(|store| {
                            store
                                .save_snapshot(&snapshot)
                                .map_err(|error| error.to_string())
                        }),
                    StoreTarget::Native => match thread {
                        Some(thread) => {
                            sessions_store(&mut sessions, &threads_db).and_then(|store| {
                                store
                                    .save_thread_with_snapshot(&thread, &snapshot)
                                    .map_err(|error| error.to_string())
                            })
                        }
                        None => Err("native 快照缺少执行线程".to_string()),
                    },
                };
                if let Err(error) = result {
                    failure = Some(error);
                }
            }
        }
        if let Some(reply) = flush {
            let _ = reply.send(match &failure {
                Some(error) => Err(error.clone()),
                None => Ok(()),
            });
        }
    }
}

fn conversations_store<'a>(
    slot: &'a mut Option<ConversationStore>,
    path: &PathBuf,
) -> Result<&'a mut ConversationStore, String> {
    if slot.is_none() {
        *slot = Some(ConversationStore::open(path).map_err(|error| error.to_string())?);
    }
    Ok(slot.as_mut().expect("conversation store"))
}

fn sessions_store<'a>(
    slot: &'a mut Option<SessionStore>,
    path: &PathBuf,
) -> Result<&'a mut SessionStore, String> {
    if slot.is_none() {
        *slot = Some(SessionStore::open(path).map_err(|error| error.to_string())?);
    }
    Ok(slot.as_mut().expect("session store"))
}

/// 投影必须带来源，避免两轨写入同 id 时互相覆盖语义。
pub fn snapshot_for(snapshot: &SavedConversation) -> SnapshotSource {
    snapshot.source
}
