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

## Agent skills

### Issue tracker

Issues and PRDs live as GitHub issues in `CodingGirlsClub/cgc_2046`, driven via `gh-axi` (use `npx -y gh-axi` instead of raw `gh`). See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), each label string equal to its role name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` at the repo root plus `docs/adr/` for architecture decisions. See `docs/agents/domain.md`.

### E2E validation

前端 UI 改动后用 agent-browser 做端到端验证（web/ 目录，Dev 服务跑起来后），按确定性分层，能数值断言的不问模型：

1. **结构 / 样式断言（主，确定性最高）**：`agent-browser eval` / `get styles` 拿 computed style 与几何（`getBoundingClientRect`），断言具体数值 —— 宽度 / 背景色 / 圆角 / 边距 / 选中态类名与边框 / 对齐差（<1px）。页面有渲染差异、组件回归、多页一致性都用这一层判定，不需要视觉模型。
2. **交互走通**：`snapshot -i`（refs）→ `click @eN` / `fill` → `wait --text/--url`，断言导航与状态变化（错误分支、成功分支都走）。
3. **视觉复核（兜底，仅感知层）**：截图交给视觉模型只查「无法数值断言」的主观项 —— 层级 / 对比度观感 / 留白协调 / 整体美感；同时截图作为给人看的证据。不要为每个页面都截图问模型；截图前先确认结构断言已全部通过。
4. **登录态**：优先 `agent-browser connect <cdp-port>` 复用已登录浏览器；无法复用且确需登录时，先备份 `users.hashed_password`（psql `cgc_2046_dev`），临时重置密码完成验证后**必须恢复原哈希**。

### 网络层调试（Rockxy）

按层选工具，不混用：页面层问题（DOM / 样式 / 控制台 / 性能）用 agent-browser / chrome-devtools；网络层问题（请求发了什么 / 收到了什么）用 Rockxy（macOS 本地抓包代理）。

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

### Deploy deps 镜像节奏

backend 部署依赖预编译镜像（`backend/Dockerfile.deps`，tag = `sha256(mix.lock)` 前 16 位）。deploy 命中 TCR 即跳过全部依赖编译（部署 ~4min）；未命中在 2 核 runner 上重建可超 45min（deploy 端 fallback 兜底，90min timeout，别依赖它）。

**mix.lock 变更后无需人工预推**：develop push 时 CI 的 `deps-image` job 检查 TCR，缺失或架构不符即构建推送——CI runner 恒 x86_64，天然 amd64，Apple Silicon 漏 `--platform` 推错架构的事故（run 32487795766 第二败）从源头消失。命中逻辑带架构校验，错架构按缺失处理自愈。

唯一注意事项：**mix.lock 变更的 merge 别抢在 `deps-image` job 完成前合入 main**（job 绿了再合），否则 deploy 端 fallback 现场重建，白等 45min。

