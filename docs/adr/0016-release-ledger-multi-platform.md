# ADR-0016: 发布账本多平台化——端标签词汇、独立端节点、平台 scope

> 日期：2026-09-24 ｜ 状态：**已接受（Accepted）** ｜ 决策者：用户（product owner）
> 关联：`CHANGELOG.md` 头版约定、`docs/agents/loopx-workflow.md` §9（发布收口工序）、`scripts/changelog-draft.rb` v2、根 AGENTS.md「PR 合并与发布」门条目、合规发布纪律（后端收紧 × 客户端过审窗口）
> 触发：2026-09-24 首发版（PR #843）后复盘——单一日期线只能记 server 面（web+backend 同一 deploy），小程序（微信审核 1-7 天）与扩展（自托管 zip）的发版节奏不同；小红书、抖音小程序未来也要进仓。

---

## 背景（Context）

「发版」在本仓不是单一动作，而是四条节奏不同的发射线：

| 端 | 发布动作 | 节奏 |
|---|---|---|
| web / backend | merge 落 main → deploy | 分钟级，同一 deploy |
| 微信小程序 | 上传 → 审核 → 手动发布 | 1-7 天人工窗口 |
| 扩展 ext | 自托管 zip，ext.yml 版本 + 指纹 | 用户手工升级，滞后不可控 |
| （未来）小红书 / 抖音小程序 | 各自审核 | 各自 SLA |

只按「日期段」记账会把未过审的小程序功能错报为上线；按 Git tag/version 记账又不符合 server 面持续部署的实际。

## 决定（Decision）

1. **单一时间线读者体验**：只保留一个仓库根 `CHANGELOG.md`，不放 per-端文件。
2. **日期段只记 server 面**：`## [YYYY-MM-DD]` 由 develop→main merge 触发，覆盖 web+backend；条目可带行内端标签（`[微信]` 等）提示落点。
3. **客户端/扩展按各自发布动作另立节点**：`## [微信 vX.Y.Z]` / `## [小红书 vX.Y.Z]` / `## [抖音 vX.Y.Z]` / `## [扩展 vX.Y.Z]`，与日期段平行混排；触发分别是过审 / 过审 / 过审 / zip 上线。
4. **组合发布纪律显式化**：后端 API 收紧 × 客户端未过审的组合，在对应节点下写 `> ⚠️` 灰注。
5. **commit scope 平台化**：新提交从笼统的 `miniprogram` 过渡为 `mp-wechat` / `mp-xhs` / `mp-dy`；`changelog-draft.rb` 按 scope 打端标签，碰客户端版本字段文件（`miniprogram/package.json`、`openclacky-ext/cgc-2046/ext.yml` 等）时输出警告——「别算进日期段」。
6. **账本先行、抽象滞后**：平台抽象层（通用小程序包、统一发版脚本）**不现在做**，等第一个第二平台立项时由真实需求决定缝在哪（届时另立 ADR）。

## 后果（Consequences）

- 正：每条用户可见变更能指到它真实的上线端与时刻，运营不再读错节奏；组合窗口事故（hardening-先落导致的存量 4xx）在账本上有痕。
- 负：单文件混排端节点，写时要多判一次「这条落哪」；由 §9 收口工序承接判断，成本可控。
- 触发面：`CHANGELOG.md` 头版约定与 loopx-workflow §9 已同步；`docs/agents/` 与 AGENTS.md 门条目随本 ADR 同一 PR 落地，由人合并。
