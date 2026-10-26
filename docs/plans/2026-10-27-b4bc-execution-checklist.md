# B4b-c 执行清单（解锁后）

## 前置
- 真机验收 §13.8 清单 1–3 全部 PASS
- 工作区干净，HEAD = 52763ad0 之后

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
