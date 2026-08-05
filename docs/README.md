# CGC 平台 docs 导航索引

> CGC 是一个「业务中枢」形态的社区活动平台（BYO 架构：网站 = 业务中枢，用户自带 OpenClacky 经 MCP 调用网站）。
> 本文件是 **docs 目录导航**；领域术语的**单一事实源**是根目录 [CONTEXT.md](../CONTEXT.md)，本文档只负责文件导航。
> 📖 设计全貌先读 **[00-CGC平台设计总纲.md](00-CGC平台设计总纲.md)**（单一事实来源总纲，细节回查本目录）。

---

## 目录结构总览

```
docs/
├── 01-定稿设计/      当前权威设计（领域模型 + 四业务 workflow + 实施计划 + 决策清单 + 用户旅程）
├── 02-调研分析/      历史调研（技术选型/多租户/认证等，可能过时，仅作参考）
├── 03-决策记录/      Grill 决策记录与决策覆盖度 Review（含 docs/adr/ 的 ADR）
├── 04-引擎验证/      POC 验证报告与 Jido workflow 引擎 DDD 设计
├── 开源合规/        开源许可与合规（依赖许可证审计等）
├── adr/             Architecture Decision Records（ADR，与 03-决策记录 同属决策依据，保持原位）
└── agents/          Matt Pocock skills 约定（domain/issue-tracker/triage-labels，勿删）
```

## 每份文档一行说明

### 01-定稿设计/（当前权威设计）

| 文件 | 性质 | 版本/状态 | 权威 |
| --- | --- | --- | --- |
| 领域模型定稿.md | 定稿 · 领域模型 | v1.1（WorkflowDefinition.type 枚举统一，2026-08-01） | ✅ 是 |
| 报名workflow详细设计.md | 定稿 · 业务 workflow | v1.3（含 §7 开放问题拍板 + 幂等键承载约束） | ✅ 是 |
| 赞助workflow详细设计.md | 定稿 · 业务 workflow | v1.1.1（一致性修正，Leader 拍板） | ✅ 是 |
| 邀请workflow详细设计.md | 定稿 · 业务 workflow | v1.1 | ✅ 是 |
| 教研workflow详细设计.md | 定稿 · 业务 workflow | v1.1 | ✅ 是 |
| 技术调研与实施计划.md | 实施计划 · 里程碑 | M1–M4 规划（Jido 同步 + BYO 大改） | 计划参考 |
| 开放问题决策清单.md | 决策清单 · 拍板记录 | 开放问题 ✅/🟡/🔶 统计 | 参考 |
| 用户旅程与Web功能清单.md | 定稿 · 8 角色旅程 | 8 角色已定稿；结构决策 D-A 系列 | ✅ 是 |

### 02-调研分析/（历史调研，可能过时）

| 文件 | 性质 | 说明 |
| --- | --- | --- |
| ash-authentication-token-调研.md | 调研 | ash_authentication token 方案调研 |
| brainstorm-多租户平台.md | 调研 | 多租户平台头脑风暴 |
| deploy-api-rest-vs-graphql-调研.md | 调研 | REST vs GraphQL 调研 |
| multitenancy-调研.md | 调研 | 多租户方案调研 |
| OpenClacky扩展调研与实施计划.md | 调研/计划 | OpenClacky 扩展调研与 BYO 实施计划 |

### 03-决策记录/（决策依据）

| 文件 | 性质 | 说明 |
| --- | --- | --- |
| grill-决策记录-2026-08-01.md | 决策记录 | Grill 决策 D1–D14 / D-A 系列拍板记录 |
| 决策覆盖度Review-2026-08-01.md | Review | 决策覆盖度审查 |
| 开放问题决策清单.md | 决策清单 | 架构审查决策（REVIEW-FINDINGS F1 落账 / F7 待拍板），与 01-定稿设计 的 workflow 层决策清单互补 |
| 前端UI设计决策-2026-08-01.md | 决策记录 | 前端 UI 设计决策 U1–U4（A 切片原型交付缺口，用户 2026-08-01 拍板） |

### 04-引擎验证/（POC 与引擎 DDD）

| 文件 | 性质 | 说明 |
| --- | --- | --- |
| workflow-engine-ddd-design.md | 设计 | Jido workflow 引擎 DDD 设计（原 Jido_Workflow架构研究员/） |
| poc-验证报告.md | 验证 | POC 验证报告（G1/G2 实证、hibernate/thaw、Bus journal 重放等） |

### docs/adr/（ADR，保持原位）

| 文件 | 性质 | 说明 |
| --- | --- | --- |
| 0001-website-as-mcp-server-byo.md | ADR | 网站 = MCP server（BYO）架构决策 |
| 0002-workflow-first-jido.md | ADR | workflow-first + Jido 生态决策 |

### docs/agents/（skills 约定，勿删）

- domain.md / issue-tracker.md / triage-labels.md —— Matt Pocock skills 约定，勿删。

---

## 单一事实来源（Single Source of Truth）约定

| 主题 | 权威位置 |
| --- | --- |
| 领域术语 / 词汇表 | 根目录 **CONTEXT.md**（唯一术语事实源） |
| 领域模型与业务 workflow 设计 | **docs/01-定稿设计/** |
| 引擎可行性 / POC 验证 | **docs/04-引擎验证/** |
| 决策依据 / 拍板记录 | **docs/03-决策记录/** + **docs/adr/** |
| 文件导航 | 本文件（docs/README.md） |

> 约定：设计文档间引用一律指向上述权威位置；02-调研分析 内容如与 01-定稿设计 冲突，以 01-定稿设计 为准。
