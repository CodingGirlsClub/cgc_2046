## Agent principles

- **Don't preserve backward compatibility.** Delete obsolete code paths instead of adding compatibility layers, fallbacks, or migration code.
- **Choose the simplest implementation** that fully meets current needs. Avoid speculative abstractions, configuration, and indirection.
- **Build systems in layers.** Start with the smallest version that runs end-to-end, add new features on top of an already working product. Never trade a working product for unfinished complexity.
- **Prefer mature, well-maintained libraries** when they reduce overall complexity or improve reliability. Don't reimplement common functionality without good reason.
- **Leverage existing dependencies** in the project before writing your own implementation or adding new packages. Don't assume a library lacks a capability without consulting its documentation and types.
- **Make long-term architectural decisions.** Don't accept temporary solutions that only work now with the intention of replacing them later.
- **Study how established products solve the problem** before designing a solution. Adopt their proven patterns and conventions rather than inventing an approach from scratch.
- **License compliance is a hard gate for new dependencies.** Any Hex/npm/native dependency you introduce must be AGPL-3.0-compatible: permissive licenses (MIT/Apache-2.0/BSD/ISC/0BSD/CC0) or AGPL-compatible weak copyleft (MPL-2.0/LGPL-3.0+/EPL-2.0). **Forbidden:** GPL-2.0-only, GPL-2.0-or-later, SSPL, BUSL, Elastic, proprietary, unlicensed. Multi-license declarations are OK only if at least one allowed option exists. When unsure, open an issue instead of adding the dependency. Rules: `docs/开源合规/依赖引入规则.md`; CI enforces via `mix cgc2046.check_licenses` + `pnpm check:licenses`.

## Testing principles

- Write unit tests before the code they verify, never after — a test written afterwards tends to assert whatever the code already does.
- Highly prefer E2E tests as the sole testing mechanism. Use them to verify complex features work. At the end of E2E tests, produce a verifiable and repeatable artifact.
- If you must test a system in isolation, first write down all the ways it could fail, then write the code.

## 子目录规则

改 `backend/`、`web/`、`miniprogram/` 下的文件前，先读该目录的 `AGENTS.md`——Codex 只自动加载仓库根到当前工作目录路径上的 AGENTS.md，不会读更深的子目录。

## LoopX 工作流（Codex CLI）

- **宿主**：Codex CLI 的 `/goal` 可见循环，LoopX agent id `codex-cli-cgc-2046`。
- **运行位置**：主控会话在主 checkout 运行（`.loopx/` 与 LoopX 管理的项目 skill 只在这里），主 checkout 保持在 `develop`；所有改动都在 worktree 里做。手动会话同样用自己的 worktree，别在主 checkout 上切分支。
- **任务来源**：只接带 `ready-for-agent` 标签的 issue，一个 issue 对应一个 LoopX todo（记 issue 号、分支、PR 链接）。任务状态只记在 LoopX，不另建状态文件。
- **模型**：主控用 Codex 默认模型；子 agent 统一用 LoopX goal 配置的子任务模型（`loopx configure-goal --subagent-model`），不在别处另设。
- **质量门**：push 前 LoopX change-quality 收据通过（`--base-ref origin/develop`；收据生成后再改代码即作废，需重跑）；开 PR 后跑 LoopX pr-review。涉及哪一端就先做哪一端的真实验收。
- **合并**：符合授权表的 PR 由主控自合并到 `develop`，随后主 checkout 快进到最新 `develop`，下一个 issue 从它开工。
- **不调用 `sop-omp`**：它只用于非 LoopX 的手动流程。
- 流程细节（闭环、索引层 3-way 重建不 rebase、验证纪律、发现分流）见 `docs/agents/loopx-workflow.md`。

授权表（唯一依据；LoopX goal 的 boundary 配置与它保持一致）：

| 动作 | LoopX 会话 | 前提 |
|---|---|---|
| 读代码；在自己的 feature 分支 / worktree 改代码并本地 commit | 允许 | 不直接改 `develop` / `main` |
| push feature 分支、开 PR（正文写 `Closes #N`） | 允许 | 质量门通过 |
| 在自己的 PR 上发布 LoopX pr-review 评审 | 允许 | — |
| 开 issue、评论 issue | 允许 | 新 issue 打 `needs-triage` |
| 把自己的 PR 合并到 `develop` | 允许 | 同时满足：CI 必过检查全绿；change-quality 收据覆盖当前 head 且 `verify` 通过；LoopX pr-review 结论 APPROVE 已发在 PR 上；合并前 `loopx pr-review --check-merge-readiness <PR>@<head>` 返回 `ready=true`。直接用 merge commit 合并，不开 auto-merge（它可能合入未经评审的新 head）；改动碰到下方人工合并范围时不适用 |
| 合并碰到人工合并范围的 PR；合并到 `main` | 禁止 | 人工执行；LoopX 记一条 user_action todo 后继续下一个任务 |
| develop→main 发布、deploy、生产数据、凭证、仓库设置 | 禁止 | 人工执行 |

人工合并范围（PR 改动碰到任一项，就由人合并）：

- `AGENTS.md`、`docs/agents/**`：agent 规则本身——防止 agent 先放宽自己的规则、再自己合并
- `.github/**`：CI 与部署流程
- `backend/priv/repo/migrations/**`：数据库迁移
- `backend/mix.lock`、`web/pnpm-lock.yaml`、`miniprogram/pnpm-lock.yaml`：依赖变更

## 安全红线（Security red lines）

- **敏感文件不读内容**：`.env`、密钥文件、证书、token 文件——用存在性检查（`grep -q "KEY_NAME" .env && echo "present"`），不输出值到对话/日志/截图。
- **内部标识符不进公开面**：模板 ID、批次号、person_id、内部 URL——公开 Issue/文档用占位符（`<模板ID>`）或「见 SendCloud 后台」。commit message 是例外（git 历史需要可追溯性），但代码注释避免写死 ID（用「当前模板」而非「942118」）。
- **凭证泄露即轮换**：任何密钥/token 意外暴露在对话/日志/公开面，立即建议用户轮换（重新生成，旧的作废）——不假设「没人看到」。

## Agent skills

### Issue tracker

Issues and PRDs live as GitHub issues in `CodingGirlsClub/cgc_2046`, driven via `gh-axi` (use `npx -y gh-axi` instead of raw `gh`). See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), each label string equal to its role name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` at the repo root plus `docs/adr/` for architecture decisions. See `docs/agents/domain.md`.

### E2E validation

前端 UI 改动后用 ego-browser 做端到端验证（web/ 目录，Dev 服务跑起来后），按确定性分层，能数值断言的不问模型：

1. **结构 / 样式断言（主，确定性最高）**：`page.evaluate()` 拿 computed style（`getComputedStyle`）与几何（`getBoundingClientRect`），断言具体数值 —— 宽度 / 背景色 / 圆角 / 边距 / 选中态类名与边框 / 对齐差（<1px）。页面有渲染差异、组件回归、多页一致性都用这一层判定，不需要视觉模型。
2. **交互走通**：`page.snapshot()`（refs）→ `page.click("@N")` / `page.fill()` → `page.waitForURL()` / `page.waitForSelector()` / `page.waitForFunction()`，断言导航与状态变化（错误分支、成功分支都走）。
3. **视觉复核（兜底，仅感知层）**：`page.screenshot()` 截图交给视觉模型只查「无法数值断言」的主观项 —— 层级 / 对比度观感 / 留白协调 / 整体美感；同时截图作为给人看的证据。不要为每个页面都截图问模型；截图前先确认结构断言已全部通过。
4. **登录态**：ego-browser（ego-lite）即用户日常浏览器，默认复用其已登录 profile；确需独立登录态时，先备份 `users.hashed_password`（psql `cgc_2046_dev`），临时重置密码完成验证后**必须恢复原哈希**。

### 网络层调试（Rockxy）

按层选工具，不混用：页面层问题（DOM / 样式 / 控制台 / 性能）用 ego-browser / chrome-devtools；网络层问题（请求发了什么 / 收到了什么）用 Rockxy（macOS 本地抓包代理）。

Rockxy 场景：

- **API 争议仲裁**：抓真实请求取证（实际发出的 header / body / 状态码），Compose 重放验证修复，Diff 对比修复前后——不靠猜。
- **错误注入**：Breakpoint 把响应改成 401/500/bad payload 测前端 fallback；Block host 模拟第三方 API 故障。不改后端代码。
- **Mock / 环境切换**：Map Local 钉死本地 JSON（后端未完成先调前端）；Map Remote 把流量改写到 localhost，不动 `/etc/hosts`。
- **Webhook 重放**：第三方回调失败时从捕获改参重发。
- **AI 取证**：当前会话的工具里有 `rockxy-mcp` 时，可直接列 flows / 读请求响应 / 导出 cURL，不要让用户手贴 curl。

Rockxy MCP 前提：Rockxy app 在运行且 **Settings → MCP → Enable MCP Server** 已开（监听 `127.0.0.1:9710`，握手文件 `~/Library/Application Support/com.amunx.rockxy.community/mcp-handshake.json`）；app 没跑时桥报 `handshake file not found`，属预期，先开 app。

红线：

- 捕获含真实凭证。导出 / 分享捕获前必须过 redaction（authorization / cookie / bearer token）；保持 MCP 的 Redact Sensitive Data 开启。
- 调试中的临时状态（重置的密码、注入的 token）验证完必须恢复，同 E2E 登录态规则。
- HTTPS 解密依赖信任 Rockxy 根 CA；只对调试需要的 host 开解密，其余 passthrough。

### PR 合并与发布

LoopX 会话只按上方授权表把自己的 PR 合并到 `develop`；其余合并与所有发布由人执行，下面的命令是人工操作口径。

- **一律 merge commit**（repo 已禁 squash/rebase 合并，界面选不出别的）：CI gate 与 deploy 的去重判定依赖「双亲 merge commit + tree 等值」识别已验证代码——squash 会让每次合并都白跑一轮全量 CI。
- **发布 = develop→main PR**。repo 已开 auto-merge，checks 全绿自动合并，merge 落 main 即触发 Deploy：

  ```bash
  gh pr create --base main --head develop --fill && gh pr merge --auto --merge
  ```

- feature→develop PR 同样用 `gh pr merge --auto --merge`（develop 与 main 同为 4 checks strict 保护）。
- 紧急修复可直接 hotfix→main PR：head 非 develop 时 4 checks 在 PR 上重新跑，绿了即可合并部署，不必绕道 develop。
- **后端 API 收紧 × 客户端依赖的组合发布纪律**：后端新增必填校验/收紧参数（如 #727 的押金 `depositConsent` 门）而客户端（小程序/APP）需过审才能带上新参数时——后端与客户端**同窗口发布**，或**客户端先行过审**后再合后端；窗口期存量客户端的对应请求会被硬拒。同时为新增拒绝错误码加监控曲线（观察窗口期拒绝量回落至基线）。

### Deploy deps 镜像节奏

backend 部署依赖预编译镜像（`backend/Dockerfile.deps`，tag = `sha256(mix.lock)` 前 16 位）。deploy 命中 TCR 即跳过全部依赖编译（部署 ~4min）；未命中在 2 核 runner 上重建可超 45min（deploy 端 fallback 兜底，90min timeout，别依赖它）。

**mix.lock 变更不用人工推镜像**：develop push 时 CI 的 `deps-image` job 检查 TCR，缺失或架构不符即构建推送（CI runner 恒 x86_64，产出即 amd64）。命中逻辑带架构校验，错架构按缺失处理自愈。

唯一注意事项：**mix.lock 变更的 merge 别抢在 `deps-image` job 完成前合入 main**（job 绿了再合），否则 deploy 端 fallback 现场重建，白等 45min。

