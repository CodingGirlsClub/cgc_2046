# B4b-c 执行清单（解锁后）

## 前置
- 真机验收 §13.8 清单 1–3 全部 PASS
- 工作区干净，HEAD = 748dba7b 之后

## 已完成的前置清理（2026-10-27 01:21）
- `SubagentCard` 已迁 `NativePanelHost`（`748dba7b`）；`native_thread_state` 现仅剩视图独占类型
  （`NativeThreadState`/`PendingPermission`），`native_view_model` 不再依赖它。
- 剩余引用面：controller 3、agent_panel 1、state 1、root_view 2、main.rs 2（demo 窗口）、
  `native_agent_view` 自身。

## 步骤
1. 类型迁移：`native_thread_state::SubagentCard` 等仍被 `native_view_model`/host 使用的类型
   → 迁到 `native_panel_host.rs`（或 `attachment.rs`）；确认无剩余引用。
2. 新建薄视图 `crates/app/src/native_panel_view.rs`：
   - 保留原 `NativeAgentView` 的对外方法签名（new/new_with_host/is_empty_thread/
     current_thread_id/display_title/set_title_override/regenerate_title/open_thread/
     send/stop/steer 等实际被外部调用的）；
   - 渲染用共享组件（message_row/message_actions/plan_card/queue_panel/image_viewer），
     legacy composer 原样搬入（837 行）；
   - `CGC_NATIVE_SHARED_VIEW` 及附件 chips 分支移除。
3. 改引用（9 处）：controller 1367/2150/2173、agent_panel 26、state 236、
   root_view 475/87、main.rs 7/161、native_view_model 10 → 指向 `native_panel_view`。
4. 删除 `native_agent_view.rs`、`native_thread_state.rs`；清理 lib.rs 模块声明。
5. 门禁：`env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY -u http_proxy -u https_proxy -u all_proxy -u no_proxy`
   `cargo fmt --check && clippy -D warnings && cargo test --workspace --exclude cgc-agent-tools -- --test-threads=1`
6. 报告 `git diff --stat` 净删行数；更新 §13.8/§13.4、README、ADR-0028。

## 环境限制（2026-10-27 01:23 确认）

- `gpui-kit 0.8.0` 未暴露 `TestAppContext`/`VisualTestContext` 等 headless 渲染测试设施，
  因此**无法在无界面环境验证布局/视觉等价**；B4b-c 的 UI 等价性只能真机确认。
- 屏幕锁定时（`CGSSessionScreenIsLocked`），macOS 阻止窗口级 `screencapture` 与 CUA AX 访问，
  自动化真机验证不可用。
- 结论：B4b-c（删除 native 唯一 UI）必须等屏幕解锁 + 真机冒烟通过后执行。
