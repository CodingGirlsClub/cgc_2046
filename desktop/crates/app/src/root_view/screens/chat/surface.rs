//! Phase B1：两轨共享聊天视图的 seam（能力 → 入口显隐 + 后续 composer 回调载体）。
//!
//! Stage 3.6 Phase B 的目标是让 native 与 external ACP 都只向
//! `ConversationThread` + `ThreadCapabilities` + 本 surface 供数，UI 按能力位显隐
//! 入口，最终删除 `native_agent_view.rs`。本文件先落**无行为变化**的第一步：
//! 统一的 `ChatSurfaceFlags`（纯函数、可单测），panel 从此读 surface 而不是直接
//! 散读 `thread.capabilities`；后续 B2/B3 再把 composer/action 回调迁进来。

use super::super::super::*;
use std::path::PathBuf;
use std::sync::Arc;

use cgc_agent_ui::conversation::{ConversationThread, ThreadCapabilities};
use gpui_kit::component::input::TextareaState;
use gpui_kit::{App, Entity, Window};

/// 聊天视图各入口的显隐位（来自 [`ThreadCapabilities`] 的稳定映射）。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct ChatSurfaceFlags {
    pub checkpoint_restore: bool,
    pub steer: bool,
    pub queue: bool,
    pub subagent: bool,
    pub config_options: bool,
    pub plan: bool,
    pub usage: bool,
    /// 附件输入入口（B2b）。
    pub attachments: bool,
    /// 图片输入入口（B2b）。
    pub images: bool,
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
            attachments: capabilities.attachments,
            images: capabilities.images,
        }
    }
}

/// 一个 thread 的共享视图参数（Phase B2 起在这里挂 composer/action 回调）。
#[derive(Clone, Copy, Debug)]
pub(crate) struct ChatSurface<'a> {
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
pub(crate) struct ComposerSurface {
    pub input: Option<Entity<TextareaState>>,
    pub callbacks: ComposerCallbacks,
    /// 已附加的附件 chip（两轨共用渲染；B2b ACP 恒空）。
    pub attachments: Vec<AttachmentChip>,
}

/// 附件 chip 数据（路径/名称/是否图片；预览由渲染层按 image 能力决定）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct AttachmentChip {
    pub id: String,
    pub label: String,
    pub is_image: bool,
}

#[allow(clippy::type_complexity)]
#[derive(Clone)]
pub(crate) struct ComposerCallbacks {
    /// 发送当前输入（行为等价于旧 composer 的 send + clear input）。
    pub send: ComposerCallback,
    /// 附件/上下文入口（B2a 对齐旧 paperclip：插入 `@` 触发 mention）。
    pub attach: ComposerCallback,
    /// 文件选择入口（B2b；无附件能力位时不渲染/不调用）。
    pub attach_pick: ComposerCallback,
    /// 追加指定路径图片（native adapter 用）。
    pub add_images_from_paths: Arc<dyn Fn(Vec<PathBuf>, &mut Window, &mut App)>,
    /// 粘贴图片（native adapter 用）。
    pub add_clipboard_image: ComposerCallback,
    /// 插入 mention（path 或引用文本）。
    pub insert_mention: Arc<dyn Fn(String, &mut Window, &mut App)>,
    /// 插入 skill mention（skill 标识）。
    pub insert_skill_mention: Arc<dyn Fn(String, &mut Window, &mut App)>,
    /// 排队当前输入（native busy 时；ACP 无 queue 能力位）。
    pub queue: ComposerCallback,
    /// steer 当前输入（native busy 时；ACP 无 steer 能力位）。
    pub steer: ComposerCallback,
}

/// native 附件 chip 映射：`(name, is_image)` → 共享 `AttachmentChip`（id 用序号）。
/// 由 native view 注入数据，surface 不反向依赖 native view。
pub(crate) fn attachment_chips_from_images(
    images: impl IntoIterator<Item = (String, bool)>,
) -> Vec<AttachmentChip> {
    images
        .into_iter()
        .enumerate()
        .map(|(index, (label, is_image))| AttachmentChip {
            id: format!("attachment-{index}"),
            label,
            is_image,
        })
        .collect()
}

/// `CGC_NATIVE_SHARED_VIEW=1`：native 面板使用共享 composer（Phase B2b 灰度，
/// 默认关闭；关闭时旧 native composer 行为完全不变）。
pub(crate) fn native_shared_view_enabled() -> bool {
    native_shared_view_enabled_from(std::env::var("CGC_NATIVE_SHARED_VIEW").ok().as_deref())
}

fn native_shared_view_enabled_from(value: Option<&str>) -> bool {
    value == Some("1")
}

/// 共享附件 chip 渲染（路径/名称/图片标记；空列表不渲染）。
pub(crate) fn render_attachment_chips(
    chips: &[AttachmentChip],
    palette: &theme::Palette,
    on_remove: impl Fn(&str) + Clone + 'static,
) -> Vec<AnyElement> {
    chips
        .iter()
        .map(|chip| {
            let remove = on_remove.clone();
            let id = chip.id.clone();
            div()
                .id(SharedString::from(format!(
                    "composer-attachment-{}",
                    chip.id
                )))
                .flex()
                .flex_row()
                .items_center()
                .gap(px(4.0))
                .px(space(1))
                .py(px(1.0))
                .rounded(px(RADIUS_SMALL))
                .border_1()
                .border_color(palette.line)
                .text_size(px(11.0))
                .text_color(palette.ink_2)
                .child(if chip.is_image { "🖼" } else { "📄" })
                .child(chip.label.clone())
                .child(
                    div()
                        .id(SharedString::from(format!(
                            "composer-attachment-remove-{}",
                            chip.id
                        )))
                        .hover(|style| style.bg(palette.soft))
                        .child("×")
                        .on_click(move |_, _, _| remove(&id)),
                )
                .into_any_element()
        })
        .collect()
}

/// 附件入口是否可见（B2b：能力位关闭时不渲染入口）。
pub(crate) fn attachment_entry_visible(flags: ChatSurfaceFlags) -> bool {
    flags.attachments
}

/// 图片入口是否可见。
pub(crate) fn image_entry_visible(flags: ChatSurfaceFlags) -> bool {
    flags.images
}

/// composer 操作显隐（纯函数；`phase_active` = Ready/Streaming，`busy` = 生成中）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ComposerVisibility {
    pub can_send: bool,
    pub can_queue: bool,
    pub can_steer: bool,
}

pub(crate) fn composer_visibility(
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
    fn attachment_and_image_entries_follow_capabilities() {
        let native_flags = super::ChatSurfaceFlags::from_capabilities(ThreadCapabilities::native());
        assert!(super::attachment_entry_visible(native_flags));
        assert!(super::image_entry_visible(native_flags));
        let acp_flags = super::ChatSurfaceFlags::from_capabilities(ThreadCapabilities::acp());
        assert!(!super::attachment_entry_visible(acp_flags));
        assert!(!super::image_entry_visible(acp_flags));
    }

    #[test]
    fn attachment_chips_map_name_and_image_flag() {
        let chips = super::attachment_chips_from_images(vec![
            ("screenshot.png".to_string(), true),
            ("notes.md".to_string(), false),
        ]);
        assert_eq!(chips.len(), 2);
        assert_eq!(chips[0].id, "attachment-0");
        assert_eq!(chips[0].label, "screenshot.png");
        assert!(chips[0].is_image);
        assert!(!chips[1].is_image);
    }

    #[test]
    fn native_shared_view_flag_defaults_off_and_reads_env_value() {
        assert!(!super::native_shared_view_enabled_from(None));
        assert!(!super::native_shared_view_enabled_from(Some("0")));
        assert!(super::native_shared_view_enabled_from(Some("1")));
    }

    #[test]
    fn pending_permission_blocks_composer_actions() {
        let visibility = composer_visibility(native(), true, true, false);
        assert!(!visibility.can_send);
        assert!(!visibility.can_queue);
        assert!(!visibility.can_steer);
    }
}
