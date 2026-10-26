//! Phase B1：两轨共享聊天视图的 seam（能力 → 入口显隐 + 后续 composer 回调载体）。
//!
//! Stage 3.6 Phase B 的目标是让 native 与 external ACP 都只向
//! `ConversationThread` + `ThreadCapabilities` + 本 surface 供数，UI 按能力位显隐
//! 入口，最终删除 `native_agent_view.rs`。本文件先落**无行为变化**的第一步：
//! 统一的 `ChatSurfaceFlags`（纯函数、可单测），panel 从此读 surface 而不是直接
//! 散读 `thread.capabilities`；后续 B2/B3 再把 composer/action 回调迁进来。

use std::sync::Arc;

use cgc_agent_ui::conversation::{ConversationThread, ThreadCapabilities};
use gpui_kit::component::input::TextareaState;
use gpui_kit::{App, Entity, Window};

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

type ComposerCallback = Arc<dyn Fn(&mut Window, &mut App)>;

/// Phase B2a：共享 composer 的输入句柄 + 发送/附件回调（行为由调用方注入）。
/// B2b/c 再把 queue/steer 等回调与 native adapter 接进来。
#[derive(Clone)]
pub(in crate::root_view) struct ComposerSurface {
    pub input: Option<Entity<TextareaState>>,
    pub callbacks: ComposerCallbacks,
}

#[derive(Clone)]
pub(in crate::root_view) struct ComposerCallbacks {
    /// 发送当前输入（行为等价于旧 composer 的 send + clear input）。
    pub send: ComposerCallback,
    /// 附件/上下文入口（B2a 对齐旧 paperclip：插入 `@` 触发 mention）。
    pub attach: ComposerCallback,
}

/// composer 操作显隐（纯函数；`phase_active` = Ready/Streaming，`busy` = 生成中）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::root_view) struct ComposerVisibility {
    pub can_send: bool,
    pub can_queue: bool,
    pub can_steer: bool,
}

pub(in crate::root_view) fn composer_visibility(
    flags: ChatSurfaceFlags,
    phase_active: bool,
    permission_pending: bool,
    busy: bool,
) -> ComposerVisibility {
    ComposerVisibility {
        can_send: phase_active && !permission_pending && !busy,
        can_queue: flags.queue && phase_active && busy && !permission_pending,
        can_steer: flags.steer && phase_active && busy && !permission_pending,
    }
}

#[cfg(test)]
mod composer_tests {
    use super::{composer_visibility, ChatSurfaceFlags};
    use cgc_agent_ui::conversation::ThreadCapabilities;

    fn native() -> ChatSurfaceFlags {
        ChatSurfaceFlags::from_capabilities(ThreadCapabilities::native())
    }

    fn acp() -> ChatSurfaceFlags {
        ChatSurfaceFlags::from_capabilities(ThreadCapabilities::acp())
    }

    #[test]
    fn idle_ready_can_send() {
        let visibility = composer_visibility(native(), true, false, false);
        assert!(visibility.can_send);
        assert!(!visibility.can_queue);
        assert!(!visibility.can_steer);
    }

    #[test]
    fn busy_native_can_queue_and_steer() {
        let visibility = composer_visibility(native(), true, false, true);
        assert!(!visibility.can_send);
        assert!(visibility.can_queue);
        assert!(visibility.can_steer);
    }

    #[test]
    fn busy_acp_cannot_queue_or_steer() {
        let visibility = composer_visibility(acp(), true, false, true);
        assert!(!visibility.can_send);
        assert!(!visibility.can_queue, "ACP 无 queue 能力位");
        assert!(!visibility.can_steer, "ACP 无 steer 能力位");
    }

    #[test]
    fn pending_permission_blocks_composer_actions() {
        let visibility = composer_visibility(native(), true, true, false);
        assert!(!visibility.can_send);
        assert!(!visibility.can_queue);
        assert!(!visibility.can_steer);
    }
}
