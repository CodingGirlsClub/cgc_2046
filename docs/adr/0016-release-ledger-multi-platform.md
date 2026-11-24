# ADR-0016: 发布账本多平台化——端标签词汇、独立端节点、平台 scope

> 日期：2026-09-24（2026-11-22 补记 Desktop 发布线与 `changelog-draft.rb` 双层检测） ｜ 状态：**已接受（Accepted）** ｜ 决策者：用户（product owner）
> 关联：`CHANGELOG.md` 头版约定、`docs/agents/loopx-workflow.md` §9（发布收口工序）、`scripts/changelog-draft.rb`、`scripts/test/changelog_draft_test.rb`、`desktop/README.md`「发布节奏（内测）」、根 AGENTS.md「PR 合并与发布」门条目、合规发布纪律（后端收紧 × 客户端过审窗口）
> 触发：2026-09-24 首发版（PR #843）后复盘——单一日期线只能记 server 面（web+backend 同一 deploy），小程序（微信审核 1-7 天）、扩展（自托管 zip）与桌面客户端（tag 驱动内测）的发版节奏不同。

---

## 背景（Context）

「发版」在本仓不是单一动作，而是五条节奏不同的发射线：

| 端 | 发布动作 | 节奏 |
|---|---|---|
| web / backend | merge 落 main → deploy | 分钟级，同一 deploy |
| 微信小程序 | 上传 → 审核 → 手动发布 | 1-7 天人工窗口（`miniprogram/package.json` 承载版本号） |
| 小红书 / 抖音小程序 | 上传 → 各自审核 | 各自 SLA；版本号在开放平台后台独立管理，不写进仓内 JSON（见 `miniprogram/README.md`） |
| 扩展 ext | 自托管 zip，`openclacky-ext/cgc-2046/ext.yml` 版本 + 指纹 | 用户手工升级，滞后不可控 |
| Desktop 桌面端 | `desktop-v*` tag → `Desktop Release` workflow | `desktop/Cargo.toml` 承载 base 版本，内测 `-dev` tag 不改 `Cargo.toml`（见 `desktop/README.md`） |

只按「日期段」记账会把未过审的小程序功能错报为上线；按 Git tag/version 记账又不符合 server 面持续部署的实际。

## 决定（Decision）

1. **单一时间线读者体验**：只保留一个仓库根 `CHANGELOG.md`，不放 per-端文件。（**2026-11-22 补记**：根目录 `CHANGELOG.md` 是跨端统一发布时间线的唯一真相源；仓库内同时保留两份端侧细节日志并存——`openclacky-ext/cgc-2046/CHANGELOG.md` 打入 `dist/cgc-2046.zip` 扩展包并由 `openclacky-ext/cgc-2046/bin/check-version-bump` 强制校验版本节，`miniprogram/CHANGELOG.md` 记录小程序客户端侧细粒度变更并在其头部声明面向用户的发布里程碑以根 `CHANGELOG.md` 为准。）
2. **日期段只记 server 面**：`## [YYYY-MM-DD]` 由 develop→main merge 触发，覆盖 web+backend；条目可带行内端标签（`[微信]` 等）提示落点。
3. **客户端/扩展按各自发布动作另立节点**：`## [微信 vX.Y.Z]` / `## [小红书 vX.Y.Z]` / `## [抖音 vX.Y.Z]` / `## [扩展 vX.Y.Z]` / `## [Desktop vX.Y.Z]`，与日期段平行混排；触发分别是过审 / 过审 / 过审 / zip 上线 / `desktop-v*` tag 发布。
4. **组合发布纪律显式化**：后端 API 收紧 × 客户端未过审的组合，在对应节点下写 `> ⚠️` 灰注。
5. **commit scope 平台化与双层门禁检测**：新提交从笼统的 `miniprogram` 过渡为 `mp-wechat` / `mp-xhs` / `mp-dy` / `desktop`；`scripts/changelog-draft.rb` 原样输出保留清单中的 commit subject（由收口工序按 scope 手工补 `[微信]`/`[小红书]`/`[扩展]`/`[Desktop]` 前缀），并通过「真实 3 个版本文件（`miniprogram/package.json`、`openclacky-ext/cgc-2046/ext.yml`、`desktop/Cargo.toml`）+ 客户端目录前缀（`desktop/`、`miniprogram/`、`openclacky-ext/`）+ 区间内 `desktop-v*` tag」双层检测输出门禁提示与 server 面变更判定，防止纯客户端改动误入 server 日期段；同时检查 `desktop/Cargo.lock` 等人工合并范围与 `deps-image` 四项编译输入（`backend/mix.lock`、`backend/Dockerfile.deps`、`backend/config/config.exs`、`backend/config/prod.exs`），由 `scripts/test/changelog_draft_test.rb` 守卫路径真实性。
6. **账本先行、抽象滞后**：平台抽象层（通用小程序包、统一发版脚本）**不现在做**，等第一个第二平台立项时由真实需求决定缝在哪（届时另立 ADR）。（**2026-11-22 补记**：小红书小程序已上线，根 `CHANGELOG.md` 已收录 `[小红书 v0.3.0+]` 节点；仓内已落地 `miniprogram/src/platform/index.ts` 与 `miniprogram/src/platform/flashback-card.ts` 轻量平台适配薄层及 `miniprogram/project.xhs.json`、`miniprogram/project.tt.json`，未单独拆分重量级分包 ADR。）

## 后果（Consequences）

- 正：每条用户可见变更能指到它真实的上线端与时刻，运营不再读错节奏；组合窗口事故（hardening-先落导致的存量 4xx）在账本上有痕。
- 负：单文件混排端节点，写时要多判一次「这条落哪」；由 §9 收口工序承接判断，成本可控。
- 触发面：`CHANGELOG.md` 头版约定与 loopx-workflow §9 已同步；`docs/agents/` 与 AGENTS.md 门条目随本 ADR 同一 PR 落地，由人合并。
