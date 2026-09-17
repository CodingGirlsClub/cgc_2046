# ADR-0015: draft 课程/活动可删除——draft-only destroy、slug 释放、权限收窄到 Owner ∪ 平台管理员

> 日期：2026-09-17 ｜ 状态：**已接受（Accepted）** ｜ 决策者：用户（product owner）
> 关联：#676（本 ADR 随其落地）、ADR-0014（slug 发布后锁死，本 ADR 论证 draft slug 释放不违其契约）、#619（slug 唯一索引与错误码）、#453（slug 锁定实施）、#39 / role-agent-journeys-v2 S5-S6（教研 run 与内容行）、#545 / #508（工作台管理面工具族）
> 触发：真实事故——在错误 Workspace 建出的 draft 课程**无法清理**：`cancel_course` 仅 open 可取消、核心实体无 destroy、而 slug 全局唯一（`courses_slug_index`）被 draft 永久占位。「删除重建」与「slug 占用」互相锁死。

---

## 背景（Context）

四个各自合理的设计叠加出死角：

| 设计 | 单独看 | 叠加后 |
|---|---|---|
| draft 只能前进（cancel 仅 open；close/cancel 终态不可逆，D4 v1） | 状态机严谨 | draft 无任何退出口 |
| slug 全局唯一（公开路由无 workspace 前缀，identity `all_tenants?`） | 公开 URL 契约化 | draft 也占着全局稀缺资源 |
| 发布后 slug 锁死（ADR-0014） | 已分发链接不 404 | 非 draft 无法腾位 |
| **缺失**：核心实体无删除 action | 保守合理 | 错建 draft 永久占位 |

Initiative 侧已有先例（`update :cancel` 接受 draft，注释「误建的草稿需要一条官方作废出口」），但 **cancel-draft 不释放 slug、僵尸行仍在**——Course/Event 需要的是 draft-only destroy。

## 决策（Decision）

1. **draft-only destroy（硬删，无回收站）**：`Course :delete` / `Event :delete`，仅 `status == :draft` 可删；其余状态一律 `cannot delete from status=…`（fail-closed，未来新增状态默认不可删）。
2. **行锁守卫而非裸状态检查**：`before_action` 内 `SELECT status FROM <table> WHERE id = $1 FOR UPDATE`——确认窗内被并发 launch 的课程，本事务等锁后读到新状态即拒；反向 launch 的 CAS UPDATE（`StatusTransition`）等锁后命中 0 行亦败。**恰一成一败**（`Initiative.transition/3` 同款行锁模式；`StatusTransition` 仅支持 UPDATE，故此处用行锁而非 CAS）。
3. **级联与 slug 释放（同事务，任一步失败整体回滚）**：
   - Course：`Prep.stop_active_runs/1` 收口非终态 prep run（run → cancelled，**保留痕迹**）+ `Output.delete_for_course/2` 删除 `key = course_<id>` 的内容行（`curriculum_outputs` 无 FK，只能显式删）；
   - Event：无级联（draft 阶段无教研 run、无内容行；moderator 等行由 FK `on_delete: delete_all` 承接）；
   - slug 随行删除自然释放全局唯一索引，同 slug 可立即重建；`ToolCallLog` / `AdminActionLog` 审计保留。
4. **权限收窄（与同族生命周期工具的 Owner/Admin 口径刻意不同）**：
   - Workspace **Owner** ✅（MCP + GraphQL 两面）；
   - **平台管理员**（`is_platform_admin`）✅（域 policy `PlatformAdmin` 放行）——MCP 面 member-only 门**不含** platform_admin 豁免（S2 成文契约，见 `Wrapper` 双面契约），非成员平台管理员走 GraphQL 域；
   - workspace **admin ❌**、普通成员 ❌（fail-closed）。
   - 排除 admin 的理由：删除不可逆、无回收站、无审计回滚路径，风险与「编辑元数据」不同级；owner 是工作台最终责任人，平台管理员是跨台治理兜底——两者构成最小可解释集合。
5. **暴露面**：MCP 确认流工具 `delete_course` / `delete_event`（two-tool，摘要强提示「不可恢复、教研草稿一并删除、slug 释放」）+ GraphQL mutation `deleteCourse` / `deleteEvent`。MCP 工具不声明 meta ⇒ 落 fail-closed 默认门（member-only + workspace_id 必填）。
6. **范围外**：跨台转移 / 跨台授权复用（ADR-0013）、`admin_` 治理族删除工具、Initiative 统一（见下）、回收站 / 软删。

### 拒绝的替代

- **cancel-draft（Initiative 先例的直接移植）**：不释放 slug、行仍在——事故的两个痛点（占位、僵尸）一个都没解；且会把「draft 可取消」引入状态机（新增 draft → cancelled 出边），扩大状态空间却无收益。
- **软删 / 回收站**：v1 无恢复入口的真实需求，却要给全部读面加 `deleted_at` 过滤（口径扩散到 web/小程序/MCP 三端与全部 list 工具）；先例（D4 终态不可逆、恢复 = 新建）指向硬删。
- **把 draft slug 改为「非全局唯一」（加 workspace 前缀或 draft 不占索引）**：动公开路由契约与 identity 结构（ADR-0014 的全局唯一前提），影响面远大于一个 destroy action。
- **放开 admin 到删除权限**：见决策 4 的理由；收窄面可随时放宽（放宽是后续增量），放宽后再收窄则是破坏性变更。
- **统一 Course/Event/Initiative 三资源删除口径（本批顺手做）**：Initiative 的 draft 已由 `:cancel` 覆盖（无 slug 释放需求，其 slug 亦全局唯一但 draft 可改名）、治理族删除另有 `admin_` 面设计——统一议程不在本批，避免把 #676 的事故修复绑上跨资源重构。

## 后果（Consequences）

- **FK 级联清单（逐一核查，迁移侧无需改动）**：
  - `enrollments`（`event_id` / `course_id`）、`invite_batches`（`event_id` / `course_id`）、`sponsorships`（`event_id`）、`speaker_invitations`（`event_id`）、`event_moderators`（`event_id`）：均为 `on_delete: delete_all`，DB 自动级联；
  - `curriculum_course_revisions`（`course_id`）、`attendances`（`event_id`）：RESTRICT——**draft 结构性不产生行**（revision 生成即发布；核销行只在 open 后由 confirmed 报名产生），若因数据异常存在则 DELETE 被 FK 拒绝（fail-closed，不静默丢数据）；
  - `curriculum_outputs`：无 FK（`key` 文本约定），由 `Output.delete_for_course/2` 显式删除；`workflow_runs`：无 FK，非终态 run 由 `Prep.stop_active_runs/1` 收口（终态 run 与 `input_snapshot.course_id` 作为历史痕迹保留）。
- **正面**：错建 draft 有官方出口（MCP 与 web 同源同语义）；slug 释放使「重来一遍」不必换公开 URL；行锁使删除与发布互斥，不会出现「删掉已发布课程」。
- **代价/风险**：
  - 删除不可逆、无回收站——误删只能重建（内容行与教研进度一并丢失）；
  - `Output` 的「行只增不删」（学习记录按行 id 引用）在设计上多了一个**例外**路径，例外边界经 `authorize?: false` 内部 action + 唯一调用方 `Course :delete` 收口（资源 policy 未覆盖 destroy ⇒ 任何授权调用一律拒绝）；
  - draft 删除后同 slug 重建会产生「同 URL、不同 id」的两段历史——审计（ToolCallLog）按 id 留痕，URL 层面无重定向（与 ADR-0014「无 rename 后门」同款取向）。
- **无迁移**：只新增 action / policy / 内部函数与工具，无 attribute / identity / 约束变化（`mix ash_postgres.generate_migrations --check` 零 pending）。
