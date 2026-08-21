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

### Deploy deps 镜像节奏

backend 部署依赖预编译镜像（`backend/Dockerfile.deps`，tag = `sha256(mix.lock)` 前 16 位）。CI 命中 TCR 即跳过全部依赖编译（部署 ~4min）；未命中在 2 核 runner 上重建可超 45min（timeout 已放宽至 90min 兜底，但别依赖它）。

**改 `mix.lock`（加/升依赖）后、部署前，本地预构建推送**（M3 Max 数分钟，CI 兜底分支只在忘记时触发）：

```bash
TAG=$(shasum -a 256 backend/mix.lock | cut -c1-16)  # macOS 无 sha256sum；与 CI 的 sha256sum 前 16 位一致
docker build --platform linux/amd64 -f backend/Dockerfile.deps \
  -t ccr.ccs.tencentyun.com/codingirlsclub/cgc2046-backend-deps:$TAG .
docker push ccr.ccs.tencentyun.com/codingirlsclub/cgc2046-backend-deps:$TAG
```

原理：镜像 tag 只随 mix.lock 变——lock 不变永远命中；变更即新 tag，本地推完 CI 即命中。凭据用 TCR 个人版（`ccr.ccs.tencentyun.com`），`docker login` 一次即可。

**`--platform linux/amd64` 不可省**：CI/生产是 x86，Apple Silicon 默认构建 arm64——CI 拉到错架构基础镜像会在 `RUN mix compile` 处 `exec format error` 直接败（run 32487795766 第二败实证，2026-08-22）。推完可验证：`docker manifest inspect <image> | grep architecture` 应为 amd64。

