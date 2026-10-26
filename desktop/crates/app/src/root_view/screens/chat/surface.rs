//! Phase B1：两轨共享聊天视图的 seam（能力 → 入口显隐 + 后续 composer 回调载体）。
//!
//! Stage 3.6 Phase B 的目标是让 native 与 external ACP 都只向
//! `ConversationThread` + `ThreadCapabilities` + 本 surface 供数，UI 按能力位显隐
//! 入口，最终删除 `native_agent_view.rs`。本文件先落**无行为变化**的第一步：
//! 统一的 `ChatSurfaceFlags`（纯函数、可单测），panel 从此读 surface 而不是直接
//! 散读 `thread.capabilities`；后续 B2/B3 再把 composer/action 回调迁进来。

use cgc_agent_ui::conversation::{ConversationThread, ThreadCapabilities};

/// 聊天视图各入口的显隐位（来自 [`ThreadCapabilities`] 的稳定映射）。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(in crate::root_view) struct ChatSurfaceFlags {
    pub checkpoint_restore: bool,
    pub steer: bool,
    pub queue: bool,
    pub subagent: bool,
    pub config_options: bool,
    pub plan: bool,
    pub usage: bool,
}

impl ChatSurfaceFlags {
    /// 能力位 → 入口显隐（唯一映射点；以后加能力位只改这里）。
    pub(in crate::root_view) fn from_capabilities(capabilities: ThreadCapabilities) -> Self {
        Self {
            checkpoint_restore: capabilities.checkpoint_restore,
            steer: capabilities.steer,
            queue: capabilities.queue,
            subagent: capabilities.subagent,
            config_options: capabilities.config_available(),
            plan: capabilities.plan,
            usage: capabilities.usage,
        }
    }
}

/// 一个 thread 的共享视图参数（Phase B2 起在这里挂 composer/action 回调）。
#[derive(Clone, Copy, Debug)]
pub(in crate::root_view) struct ChatSurface<'a> {
    pub thread: &'a ConversationThread,
    pub flags: ChatSurfaceFlags,
}

impl<'a> ChatSurface<'a> {
    pub(in crate::root_view) fn new(thread: &'a ConversationThread) -> Self {
        Self {
            thread,
            flags: ChatSurfaceFlags::from_capabilities(thread.capabilities),
        }
    }
}

#[cfg(test)]
mod surface_tests {
    use super::ChatSurfaceFlags;
    use cgc_agent_ui::conversation::{ConversationThread, ThreadCapabilities};

    #[test]
    fn native_capabilities_expose_all_entries() {
        let thread = ConversationThread::default().with_capabilities(ThreadCapabilities::native());
        let flags = ChatSurfaceFlags::from_capabilities(thread.capabilities);
        assert!(flags.checkpoint_restore);
        assert!(flags.steer);
        assert!(flags.queue);
        assert!(flags.subagent);
        assert!(flags.config_options);
        assert!(flags.plan);
        assert!(flags.usage);
    }

    #[test]
    fn acp_capabilities_hide_native_only_entries() {
        let thread = ConversationThread::default().with_capabilities(ThreadCapabilities::acp());
        let flags = ChatSurfaceFlags::from_capabilities(thread.capabilities);
        assert!(!flags.checkpoint_restore, "ACP 无 checkpoint");
        assert!(!flags.steer);
        assert!(!flags.queue);
        assert!(!flags.subagent);
        assert!(flags.config_options, "ACP 由 session config options 提供");
    }

    #[test]
    fn surface_reads_flags_from_thread() {
        let thread = ConversationThread::default().with_capabilities(ThreadCapabilities::native());
        let surface = super::ChatSurface::new(&thread);
        assert!(surface.flags.steer);
        assert_eq!(surface.thread.entries.len(), 0);
    }
}
