# omp-access-pack 端到端验证清单

本清单用于验证接入包在真实 OMP 会话中的黄金链路切片。每项含前置、操作、预期三要素，可独立复验。

**验证环境**：清洁沙盒 `$HOME`（或专用测试机），已装 OMP 与 browser relay 扩展。

**执行方式**：逐项执行，记录实际结果与结论（✓/✗/豁免+理由）。失败项回写 plan 的 Risks 后修复重跑。

---

## 1. 安装与发现（AE8 前置）

**前置**：清洁 `$HOME`，未装接入包。

**操作**：
1. `bash omp-access-pack/install.sh install`
2. 启动 `omp`
3. 输入 `/agents` 查看 agent 列表
4. 输入 `/mcp list` 查看 MCP server 列表
5. 输入 `/cgc`

**预期**：
- install 输出含「守门配置已写入。请启动 OMP 后调一次 confirm 类工具确认弹审批框」
- `/agents` 可见 `cgc`
- `/mcp list` 可见 `cgc-2046`（记录实际注册的工具名，回填 plan KTD4 的配置键）
- `/cgc` 显示「未连接」+ onboarding 引导

**实际**（2026-09-20 沙盒验证，清洁 `$HOME`）：
- install 输出含守门验证指引 ✓
- agent/skill/extension 落位 ✓
- mcp.json 生成且权限 600 ✓
- config.yml 含守门配置 `mcp__cgc_2046_confirm_operation: prompt` ✓
- `/agents`、`/mcp list`、`/cgc` 三项需真实 OMP 会话，待用户执行

**结论**：沙盒 install 部分 ✓；OMP 会话内三项（/agents、/mcp list、/cgc）待用户执行。

---

## 2. 连接 onboarding（AE7）

**前置**：Chrome 已装 relay 扩展并登录 CGC 网站。

**操作**：对 agent 说「连接 CGC」。

**预期**：
- agent 用 `browser` 工具（relay）接管 Chrome，打开 MCP 页
- 自动撤销旧 `omp-auto-*` token（如有），签发新 token
- token 进剪贴板，agent 不读取/转述明文
- 剪贴板管道写入 `~/.omp/agent/mcp.json`
- `/mcp test cgc-2046` 握手成功
- agent 报告连接建立

**实际**（2026-09-20 真实环境验证，用户 Chrome + relay）：
- agent 用 browser 工具接管 Chrome，打开 MCP 页 ✓
- 签发新 token `omp-auto-20260920` ✓
- **事故**：agent 每次动作后 dump page text 用于状态确认，签发后页面渲染 token 明文被 dump 进会话记录——token 泄漏。agent 意识到后撤销该 token 并重签干净 token ✓（教训已写入 onboarding skill 纪律）
- **误伤**：撤销时误点了 `dsh-auto-20260909`（用户手动创建、非 `omp-auto-*` 命名）的撤销按钮——该 token 被误撤销。教训：撤销按钮定位需精确匹配卡片，不能只按按钮文本找。
- 剪贴板管道写入 mcp.json ✓（`authHeader: True`）
- 端到端只读调用 `list_my_workspaces` 返回真实数据（2 个 workspace、角色、is_platform_admin）✓
- mcp.json 权限 600、config.yml 守门配置在位 ✓

**结论**：连接建立 ✓；两个执行细节（page text dump 泄漏、误撤销非目标 token）已记录为 skill 改进点。

---

## 3. 连接安全性（AE3）

**前置**：已完成连接。

**操作**：检查对话记录与工具调用参数。

**预期**：
- 连接 token 不出现对话记录与工具调用参数中
- `~/.omp/agent/mcp.json` 权限为 600（`stat -f '%Lp' ~/.omp/agent/mcp.json` 或 `stat -c '%a'`）

**实际**（2026-09-20 真实环境验证）：
- mcp.json 权限 600 ✓
- **token 曾泄漏**：agent dump page text 导致 token 明文进入会话记录——已撤销并重签干净 token。教训：签发后页面渲染 token 明文，任何 page text dump 都会带进会话记录；已写入 onboarding skill 纪律。
- 重签后的干净 token 未进对话（agent 只点复制按钮，未读页面文本）✓

**结论**：权限断言 ✓；token 泄漏事故已处理（撤销+重签），纪律已写入 skill。

---

## 4. 角色进入（AE5 前置）

**前置**：已连接（项 2 已完成）。

**操作**：在**新 OMP 会话**中（MCP 工具在会话启动时注册，当前会话用不了新连接），对 agent 说「我想学习」或「我想管理课程」。

**预期**：
- agent 调 `list_my_workspaces`，按名称展示可访问 Workspace 与角色
- 用户按名称选择后，agent 调 `get_role_playbook` 加载对应角色 playbook
- agent 展示 playbook 版本号
- 全程无 UUID 手填

**实际**：待用户在新 OMP 会话执行。

**结论**：待用户执行。

---

## 5. Learner 学习切片（AE5）

**前置**：已连接，用户有 Learner 身份的 Workspace 与已发布课程。

**操作**：对 agent 说「帮我学 <课程名>」。

**预期**：
- agent 调 `start_learning_run` 启动学习
- agent 用 `todo` 建学习任务清单，每完成一步更新状态
- agent 按 learner playbook 执行教学循环
- 调 `submit_learning_attempt` 提交评价
- 调 `get_learning_state` 确认进度

**实际**：待用户在新 OMP 会话执行。

**结论**：待用户执行。

---

## 6. 确认流（AE1 + AE2）

**前置**：已连接，用户有 Owner/Admin 身份的 Workspace。

**操作**：对 agent 说「帮我撤销 <某成员> 的报名」（或其他低风险确认流工具）。

**预期**：
- 业务工具返回 `needs_confirmation` + 摘要
- agent 复述摘要并调 `ask` 让用户点选
- 用户点「确认执行」后，`confirm_operation` 触发 OMP 原生审批框
- 用户在审批框确认后才落库
- 对话记录含 ask 复述，审批框决策进 OMP 会话记录（两层可追溯）

**实际**：待用户在新 OMP 会话执行。

**结论**：待用户执行。

---

## 7. 守门 headless 拒绝（AE2 补充）

**前置**：已连接，守门配置已写入。

**操作**：在 headless 子代理中（如 vibe worker 或 task 子代理）尝试调 `confirm_operation`。

**预期**：调用被直接拒绝（headless 中 `prompt` 策略无法满足，拒绝调用）。

**实际**：待用户在新 OMP 会话执行（vibe 模式 spawn worker）。

**结论**：待用户执行。

---

## 8. `/cgc` 已连接态（AE8）

**前置**：已连接。

**操作**：输入 `/cgc`。

**预期**：显示连接状态（工具数）、待办引导、角色引导、快捷操作。

**实际**：待用户在新 OMP 会话执行。

**结论**：待用户执行。

---

## 9. relay 不可用回退（AE7 补充）

**前置**：Chrome 未装 relay 扩展。

**操作**：对 agent 说「连接 CGC」。

**预期**：agent 检测 relay 不可用，回退手工 token 流程（引导用户在网站 MCP 页创建 token、复制到剪贴板、跑管道命令），不报错中断。

**实际**：待用户在新 OMP 会话执行（临时禁用 relay 扩展后重试连接）。

**结论**：待用户执行。

---

## 豁免记录

| AE | 豁免理由 |
| --- | --- |
| AE4（支付链路） | 需要真实支付环境，本验证不覆盖；支付回调与订单状态由网站既有测试覆盖 |
| AE6（双宿主审计一致性） | 需要 OpenClacky 宿主对照环境，本验证不覆盖；审计语义由网站 ToolCallLog 统一承担，宿主无关 |
| AE9（Tutor vibe 并行） | 需要 vibe 模式与多 worker 环境，本验证不覆盖；vibe 约束（headless prompt 拒绝）已在 AE2 补充项验证 |

---

## 总结

- 必验项（AE1/AE2/AE3/AE5/AE7/AE8）：___ / 6 通过
- 豁免项（AE4/AE6/AE9）：___ / 3 记录理由
- 失败项：___（如有，回写 plan Risks 后修复重跑）

**验证人**：___
**验证日期**：___
**OMP 版本**：___（回填 README 的最低版本记录位）
