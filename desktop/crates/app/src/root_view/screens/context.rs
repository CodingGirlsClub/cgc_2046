use super::super::*;

/// 屏幕渲染上下文：把 screen 与 `RootView` 的耦合收口到一个入口。
/// 目前仍以 `RootView` 为宿主（GPUI entity），但 screen 只依赖该上下文，
/// 后续可把内部状态换成独立的 ShellState 而不改 screen 签名。
pub(in crate::root_view) struct ScreenContext<'a> {
    root: &'a mut RootView,
}

impl<'a> ScreenContext<'a> {
    pub(in crate::root_view) fn new(root: &'a mut RootView) -> Self {
        Self { root }
    }
}

impl std::ops::Deref for ScreenContext<'_> {
    type Target = RootView;

    fn deref(&self) -> &Self::Target {
        self.root
    }
}

impl std::ops::DerefMut for ScreenContext<'_> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.root
    }
}
