# ADR-0013：跨工作台挂载治理（暂不立项）与 HQ 跨台报表（缓）

> 日期：2026-09-16 ｜ 状态：**已接受（Accepted）** ｜ 决策者：用户（product owner）
> 关联：#596（挂载继承与预览读面）、GLOSSARY.md §5「挂载前预览」、issue #621（本批 PR 同车记录）
> 触发：Initiative 跨工作台挂载能力（#596 继承规则 + 预览读面）落地后，「跨台治理流程」与「HQ 跨台报表」两件下游能力是否需要随批立项——本 ADR 同时钉死挂载的边界规则，并把两件下游能力的开工条件写死。

---

## 决策（Decision）

### 1. 跨工作台挂载治理——暂不立项

**结论**：边界规则即刻生效（**以下三规则均为治理愿景，当前并无代码载体；触发条件 = 第一个真实跨台挂载请求出现，届时与治理流程一并落地**）——挂载是**引用**、不迁移所有权；被挂 Event 的授权**归属原 workspace**；跨工作台挂载**须双向确认**。治理流程（审批链 / 撤挂 / 仲裁）本身**不开工**。当前实现：同工作台挂载零校验即过（`Event.initiative_id` 是普通可写字段；`RuleInheritance.prepare_event_changes/2` 不校验 initiative 所属工作台）；跨台挂载场景目前无入口。
**理由**：尚无真实跨台挂载实例；规则先立是给已落地的挂载继承与预览读面（#596）划边界，流程缺可验证输入。
**再立项条件**：第一个真实跨工作台挂载请求出现时立项，以该实例反推流程，而非现在凭空设计审批链。

**2026-11-24 现状补记**：修正第 13 行对当前实现前提的描述——`Cgc2046.Initiatives.Initiative`（`backend/lib/cgc_2046/initiatives/initiative.ex`）实为平台级资源、无 `workspace_id` 列，不同工作台的 Event 已可挂载至同一平台 Initiative（`backend/lib/cgc_2046/initiatives/mounts.ex` 跨台汇总）；且挂载并非「零校验即过」，`Cgc2046.Initiatives.RuleInheritance.prepare_event_changes/2`（`backend/lib/cgc_2046/initiatives/rule_inheritance.ex`）已校验 Initiative `:open`、四项规则齐备、押金/定价/截止不变量与解绑溯源标记。本决策暂缓的范围聚焦于「跨台归属/双向确认审批链与仲裁治理流程」。

### 2. HQ 跨工作台报表——缓

**结论**：暂不做。
**理由**：无明确消费场景（谁看 / 看什么 / 据此做什么决策，三问皆无答案），且跨台聚合要正面处理租户边界（workspace 隔离 + platform_admin 可见性），现在做属 speculative 平台建设。
**再立项条件**：若确为真实组织需求，前置交付物 = **一页指标口径定义**（指标名 / 口径 / 维度 / 可见性），评审通过再立项。

**2026-11-24 现状补记**：工作台级 HQ 跨台运营报表仍暂缓；平台管理员面已落地跨全工作台的纯计数获客聚合读面 `Cgc2046.Accounts.AcquisitionStats.stats/1`（`backend/lib/cgc_2046/accounts/acquisition_stats.ex`）及 MCP 工具 `list_acquisition_stats`（按 `initiative_slug` 汇总报名/新用户/志愿者申请计数，不含 PII）。
