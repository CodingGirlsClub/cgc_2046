---
title: "Native Agent - 实施状态与交接"
type: plan
date: 2026-10-23
topic: desktop-native-agent
status: draft
---

# Native Agent - 实施状态与交接

> 分支：`feat/native-agent-design`（基于 `feat/desktop`，未 push、未开 PR）。
> 设计依据：`docs/plans/2026-10-22-1500-feat-native-agent-design.md` + `docs/adr/0028-desktop-native-agent-dual-track.md`。
> 本文只记录**已实现范围、验证方式、剩余工作与风险**，不重复设计细节。

## 1. 已落地的 crate

| crate | 职责 |
|---|---|
| `cgc-agent-provider` | Model/Request/CompletionEvent/TokenUsage 四件套、Provider trait、FakeProvider、EchoProvider、OpenAI-compatible Provider（SSE/thinking/tool_call/usage/错误分类） |
| `cgc-agent-core` | Thread/Entry、单轮 + 工具 loop、审批回调、取消、follow-up、steering、上下文预算与摘要式 compaction、`run_subagent` |
| `cgc-agent-tools` | Tool trait/registry、读写/列目录/终端、路径与沙箱约束、命令危险策略、todo/plan/goal、AppAction（open_page/highlight_range）、task 子 agent |
| `cgc-agent-host` | AgentCommand/AgentEvent/HostState、EventCollector/ChannelObserver/AsyncChannelObserver、slash 命令解析 |
| `cgc-agent-store` | SQLite 会话（threads/entries/checkpoints）、模型与 Provider 偏好、动作审计 JSONL |
| `cgc-agent-checkpoint` | Git checkpoint：临时索引 + 隐藏 ref、snapshot/list/diff/restore/prune、逐文件 Keep/Reject |
| `cgc-agent-demo` | CLI 可交互 demo（REPL、`--once`、`--selftest`、`--allow-tools`） |
| `cgc-desktop-app` | 面板集成：NativeAgentView、账号菜单入口、课程页内联 ACP↔Native 切换、AppAction 路由与高亮提示、灰度开关 |

## 2. 功能矩阵

| 阶段 | 内容 | 状态 |
|---|---|---|
| P0 | Provider 四件套 / Fake / OpenAI-compatible / CLI+GPUI demo / 偏好持久化 | ✅ 完成 |
| P1a | loop、工具、审批、OS 沙箱（Seatbelt/bwrap/Windows 降级）、SQLite 会话、Host 协议、AppAction + 审计、危险命令策略 | ✅ 完成 |
| P1b | Git checkpoint、逐文件 diff/Keep/Reject、HEAD 漂移检测、灰度开关、课程页内联替换（可切回 ACP） | ✅ 完成 |
| P2 | Provider 设置（Settings → AI / LLM Providers，gpui-kit Settings 组件，多 provider + 钥匙串）、composer 模型/推理档位/审批模式、follow-up、steering、slash 面板、todo/plan/goal、摘要式 compaction、subagent + 实时卡片 | ✅ 完成（存在已知缺口，见 §4） |
| P3 | 多 mate 定义下发、第三方 MCP、web agent 退役评估 | ⏳ 未开始 |

## 3. 验证方式

```bash
cd desktop
# agent 相关 crate（132 项单测 + 1 项 E2E selftest）
cargo test -p cgc-agent-provider -p cgc-agent-core -p cgc-agent-tools \
           -p cgc-agent-demo -p cgc-agent-store -p cgc-agent-host -p cgc-agent-checkpoint
cargo run -p cgc-agent-demo -- --selftest

# app（87 项 lib 测试 + 编译）
cargo test -p cgc-desktop-app --lib
cargo check -p cgc-desktop-app

# 质量门
cargo fmt --all --check
cargo clippy -p cgc-agent-provider -p cgc-agent-core -p cgc-agent-tools \
             -p cgc-agent-demo -p cgc-agent-store -p cgc-agent-host \
             -p cgc-agent-checkpoint --all-targets -- -D warnings
python3 scripts/check_licenses.py
```

GPUI 手动验收：

```bash
CGC_NATIVE_AGENT_DEMO=1 cargo run -p cgc-desktop-app      # 启动即开 demo 窗口
# 或登录后：设置 → Native Agent（Beta）开启灰度 → 账号菜单 / 课程页「Native」入口
# 真实 provider：CGC_AGENT_BASE_URL / CGC_AGENT_API_KEY / CGC_AGENT_MODEL
```

## 3.1 真实 provider 冒烟（2026-10-23）

- 环境：桌面 debug 构建，`CGC_NATIVE_AGENT_DEMO=1`，**在应用内 Provider 设置里配置**（非环境变量）。
- Provider：DeepSeek，Base URL `https://api.deepseek.com`，Model `deepseek-flash`，API Key 存系统钥匙串。
- 结果：首轮 `hi` 正常流式返回（"Hi! What can I help you with today?"），状态栏显示 `usage: 1131 tokens`，无错误。
- 备注：未记录/提交任何 key；Base URL 未带 `/v1` 时仍拼出 `/chat/completions` 并成功；应用内保存 Provider 后**立即生效**（无需重启窗口）。

## 4. 已知缺口与风险（按优先级）

1. ~~高亮只是提示~~：已升级为读取工作区文件的内容预览卡片（行号 + 高亮区间 + 关闭），但没有编辑器级定位/滚动。
2. ~~会话未共享~~：已通过 `Agent::replace_thread` + 发送前从 SQLite 拉取最新会话解决；并发写入仍是 last-write-wins。
3. **推理档位只对 `supports_thinking=true` 的 provider 下发**；`reasoning_effort` 需要 provider 侧支持，否则不发送。
4. **审批 UI 边界**：turn 结束后残留审批的清理只做了 sender 清理，未做状态机级处理。
5. **审计无轮转**：`actions.jsonl` 只追加不清理；写入失败只有 `let _`，无告警。
6. **compaction 摘要成本**：摘要调用未计入 thread usage，且摘要可能丢细节；失败回退硬截断。
7. **子 agent 受限**：只读工具、共享主 provider/model、无独立计费/限流；事件仅在 turn 内实时。
8. **命令策略可绕过**：字符串子串匹配，shell 变形可能绕过；真正边界仍是沙箱 + 审批。
9. **Windows 沙箱**：仅降级为审批，无 OS 级隔离。
10. **P3 未开始**：多 mate 定义下发、第三方 MCP、web agent 退役评估。

## 5. 交接建议

- 先补「会话共享 + 高亮定位」两个用户可感知缺口，再评估 P3。
- 真实 provider 冒烟必须手动跑一次（DeepSeek / CGC 网关），当前自动化只用 FakeProvider。
- 合并前注意：`desktop/Cargo.lock` 变更属于人工合并范围；新增依赖（rusqlite、ureq、futures 等）已过许可门禁但需人工确认。
- 本分支所有提交均未 push；合入 `develop` 前建议按 repo 约定走 PR + 质量门。
