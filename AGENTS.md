## Agent principles

- **Don't preserve backward compatibility.** Delete obsolete code paths instead of adding compatibility layers, fallbacks, or migration code.
- **Choose the simplest implementation** that fully meets current needs. Avoid speculative abstractions, configuration, and indirection.
- **Build systems in layers.** Start with the smallest version that runs end-to-end, add new features on top of an already working product. Never trade a working product for unfinished complexity.
- **Keep components modular** with clear separation of concerns.
- **Prefer mature, well-maintained libraries** when they reduce overall complexity or improve reliability. Don't reimplement common functionality without good reason.
- **Leverage existing dependencies** in the project before writing your own implementation or adding new packages. Don't assume a library lacks a capability without consulting its documentation and types.
- **Make long-term architectural decisions.** Don't accept temporary solutions that only work now with the intention of replacing them later.
- **Study how established products solve the problem** before designing a solution. Adopt their proven patterns and conventions rather than inventing an approach from scratch.
- **License compliance is a hard gate for new dependencies.** Any Hex/npm/native dependency you introduce must be AGPL-3.0-compatible: permissive licenses (MIT/Apache-2.0/BSD/ISC/0BSD/CC0) or AGPL-compatible weak copyleft (MPL-2.0/LGPL-3.0+/EPL-2.0). **Forbidden:** GPL-2.0-only, SSPL, BUSL, Elastic, proprietary, unlicensed. Multi-license declarations are OK only if at least one allowed option exists. When unsure, open an issue instead of adding the dependency. Rules: `docs/开源合规/依赖引入规则.md`; CI enforces via `mix cgc2046.check_licenses` + `pnpm check:licenses`.

## 编排主权（LoopX / Mainline / sop-omp）

- **LoopX** 管何时派工/quota/续跑；**Mainline** 定 git 写边界上限（`.mainline/config.toml` 的 `[agent] autonomy`，当前 `review`：允许 push 非 main 分支 + 开 PR）；**sop-omp** 定质量前置（reviewer PASS + e2e PASS 才许 push）与任务状态 truth（`pipeline-status.md` / Sign-off）。
- 两类约束**取更严者**；`Mainline > sop-omp > LoopX` 仅裁指令冲突，不裁质量门。
- LoopX 拉起的会话：commit→seal→publish 按配置自治放行，不停机；push 仅在双 PASS 后；preflight block、语义冲突、未答 question、merge/deploy/公开动作仍是硬门，停机上报。
- 任务状态唯一 truth 是 sop-omp 状态文件；LoopX goal state 只留指针与 heartbeat，不重建任务条目。
- 各 worktree 的 `.mainline/config.toml` 必须与根仓一致：改动提交入库经 git 传播，不手改单副本；编排类 chore commit 带 `Mainline-Skip:` trailer 或命中 skip pattern，避免 uncovered 噪音。

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

### Worktree 编排 SOP

worktree agent 改文件与自证、可在 worktree 内本地 commit；push / PR / merge / 分支引用归编排者（沙箱能力以当场实测为准，被拒即回落只改文件）；重建走索引层 3-way（不 rebase）、落地链 fail-closed。见 `docs/agents/worktree-orchestration.md`。

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
- **AI 取证**：装了 Rockxy 的机器上，MCP（`~/.omp/agent/mcp.json` 用户级已配 `rockxy-mcp`）可直接列 flows / 读请求响应 / 导出 cURL，不要让用户手贴 curl。

Rockxy MCP 前提：Rockxy app 在运行且 **Settings → MCP → Enable MCP Server** 已开（监听 `127.0.0.1:9710`，握手文件 `~/Library/Application Support/com.amunx.rockxy.community/mcp-handshake.json`）；app 没跑时桥报 `handshake file not found`，属预期，先开 app。

红线：

- 捕获含真实凭证。导出 / 分享捕获前必须过 redaction（authorization / cookie / bearer token）；保持 MCP 的 Redact Sensitive Data 开启。
- 调试中的临时状态（重置的密码、注入的 token）验证完必须恢复，同 E2E 登录态规则。
- HTTPS 解密依赖信任 Rockxy 根 CA；只对调试需要的 host 开解密，其余 passthrough。

### PR 合并与发布

- **一律 merge commit**（repo 已禁 squash/rebase 合并，界面选不出别的）：CI gate 与 deploy 的去重判定依赖「双亲 merge commit + tree 等值」识别已验证代码——squash 会让每次合并都白跑一轮全量 CI。
- **发布 = develop→main PR**。repo 已开 auto-merge，checks 全绿自动合并，merge 落 main 即触发 Deploy：

  ```bash
  gh pr create --base main --head develop --fill && gh pr merge --auto --merge
  ```

- feature→develop PR 同样用 `gh pr merge --auto --merge`（develop 与 main 同为 4 checks strict 保护）。
- 紧急修复可直接 hotfix→main PR：head 非 develop 时 4 checks 在 PR 上重新跑，绿了即可合并部署，不必绕道 develop。
- **后端 API 收紧 × 客户端依赖的组合发布纪律（#752，2026-09-18）**：后端新增必填校验/收紧参数（如 #727 的押金 `depositConsent` 门）而客户端（小程序/APP）需过审才能带上新参数时——后端与客户端**同窗口发布**，或**客户端先行过审**后再合后端；窗口期存量客户端的对应请求会被硬拒。同时为新增拒绝错误码加监控曲线（观察窗口期拒绝量回落至基线）。

### Deploy deps 镜像节奏

backend 部署依赖预编译镜像（`backend/Dockerfile.deps`，tag = `sha256(mix.lock)` 前 16 位）。deploy 命中 TCR 即跳过全部依赖编译（部署 ~4min）；未命中在 2 核 runner 上重建可超 45min（deploy 端 fallback 兜底，90min timeout，别依赖它）。

**mix.lock 变更后无需人工预推**：develop push 时 CI 的 `deps-image` job 检查 TCR，缺失或架构不符即构建推送——CI runner 恒 x86_64，天然 amd64，Apple Silicon 漏 `--platform` 推错架构的事故（run 32487795766 第二败）从源头消失。命中逻辑带架构校验，错架构按缺失处理自愈。

唯一注意事项：**mix.lock 变更的 merge 别抢在 `deps-image` job 完成前合入 main**（job 绿了再合），否则 deploy 端 fallback 现场重建，白等 45min。

