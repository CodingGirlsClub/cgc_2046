---
title: "课程内容隐私主线与 develop 视频 skill 私有化整合计划"
date: 2026-09-07
status: proposed
artifact_readiness: implementation-ready
execution: code
source: "当前分支 9361e795 + origin/develop 7224d1bf"
---

# 课程内容隐私主线与 develop 视频 skill 私有化整合计划

## Goal Capsule

把当前分支已经完成的 WorkflowRun 隐私边界、CourseRevision 阅读器、角色治理投影和 typed Material 合同，与 `origin/develop` 最近完成的视频制作能力私有化重构整合起来，最终形成一条可发布的课程内容链路：

- 公开扩展只携带视频执行物料，不公开视频制作方法论；
- Tutor 通过可信 Workspace/playbook 获得视频流程，playbook 缺失或读取失败时 fail closed；
- OpenClacky 教研编辑器和 MCP/Web 使用同一 typed Material 合同，不再生成 `{title, ref}` 或 `video:<id>`；
- Tutor/Owner/Admin/Platform Admin 的页面和 API 继续保持投影隔离；
- 真实登录态 Web、扩展和 GraphQL 权限证据齐全，迁移失败安全，Web 全套门禁可运行。

## 当前证据与整合边界

`origin/develop` 当前为 `7224d1bf`，相关视频重构主要来自 `8a40bb54`、`d4da7904` 和 `ad52786a`：

- 删除 `openclacky-ext/cgc-2046/skills/issue-video/` 的公开 skill、方法论、测试和品牌物料路径；
- 将执行物料迁移到 `openclacky-ext/cgc-2046/agents/cgc-tutor/video/`；
- `ext.yml` 删除 `issue-video` skill 声明；
- tutor system prompt 改为依赖私有 tutor playbook 的“配套视频”章节；
- 新增 `video_pipeline_assets_test.rb`，验证公开扩展不再暴露 skill、物料存在且不含开发者路径或密钥；
- 当前 `develop` 同时删除了本分支的课程阅读器、治理投影、Platform Audit、migration 和相关计划文件。

因此整合规则是：

1. 不把 `origin/develop` 直接 merge/rebase 到当前分支后接受删除结果。
2. 以当前分支的隐私/课程内容实现为主线，逐项吸收视频私有化的文件移动、prompt、manifest 和测试契约。
3. 对 remote 与当前分支共同修改的 `content.ex`、OpenClacky curriculum panel、测试和文档逐文件重审，不接受自动冲突结果。
4. 保留旧计划、ADR、迁移和 generated GraphQL，直到新整合通过后再更新文档；不能让远程删除掩盖未完成的发布证据。

## Requirements Traceability

- **R1–R4 / AE1–AE2：** raw WorkflowRun 继续 self-only；Tutor/Owner/Admin 只能读业务投影；Platform Admin 只能读脱敏审计。
- **R5–R6 / R10 / R12–R13 / AE3 / AE6：** chapter 与 typed Material 成为 Web、MCP、OpenClacky 唯一新协议。
- **R7–R11 / R14–R15 / AE4–AE7：** Reader、媒体失败态、角色路由和 public goal-only map 保持当前分支设计。
- **视频私有化新增约束：** 公开扩展不提供 issue-video skill；执行物料留在 tutor agent 目录；方法论由平台 playbook 下发；playbook 不可读时停止，不凭记忆执行。
- **发布门禁：** 干净数据库 migration、失败 preflight 原子回滚、真实 GraphQL 权限、真实登录态浏览器、扩展 round-trip、i18n 和全套 lint/test。

## Design Decisions

### D1. 先做整合基线，不直接合并 develop

使用当前分支 `9361e795` 和 `origin/develop 7224d1bf` 的共同祖先 `92abcbe4` 作为对比基线。先建立文件级冲突清单，再分批整合。这样可以避免远程为了视频 skill 私有化而删除课程隐私功能。

### D2. 视频制作方法论与执行物料分离

公开扩展只保留 `agents/cgc-tutor/video/` 下的模板、自检脚本、TTS 脚本和品牌素材。制作步骤、授权、脚本确认、渲染和验收规则由 `get_role_playbook(role=tutor)` 返回的私有章节提供。playbook 缺失、版本过期、401/连接失败或 forbidden 时，Tutor 停止视频流程。

### D3. typed Material 是跨端协议唯一真源

视频产出最终保存为：

```json
{"kind":"video","title":"配套动画","provider":"bilibili","external_id":"BVxxxxxxxxxx","caption":"公开外部视频"}
```

第一阶段不把本地 `media/videos/<chapter>` 路径当作学习内容 locator，不保存 iframe HTML，不保存 `video:<chapter>` 字符串。若视频仍是本地文件，只能作为制作中间产物或待上传资产，不能写入正式 CourseRevision。

### D4. 旧草稿明确迁移，不加兼容解析

旧 `{title, ref}`、`video:<id>` 和任意 iframe 只作为 unresolved legacy material 报告。OpenClacky 编辑器必须把它们转换或要求作者重新输入 typed 字段；后端拒绝新保存和发布。已发布历史 revision 保持不可变，但阅读器显示不可用/需重新保存提示。

## Work Units

### U0. 整合基线和冲突分类

**Files:** `git diff HEAD..FETCH_HEAD` 涉及的 remote 删除/重命名文件、当前 `docs/plans/2026-09-06-1846-feat-course-content-workflow-privacy-plan.md`、`docs/adr/`、`openclacky-ext/cgc-2046/ext.yml`。

**Work:**

- 建立 current-only、develop-only、same-file semantic conflict 三类清单；
- 标记 remote 删除但当前功能仍需要的文件：课程阅读器、治理投影、Platform Audit、migration、Material renderer；
- 标记视频重构应吸收的文件移动和 manifest/prompt/test 变化；
- 记录不得直接采用的 remote 删除项；
- 形成一个可复核的整合顺序，避免在 dirty 当前分支上直接 rebase。

**Acceptance:** 清单能解释每个 remote 删除或新增文件的取舍；没有未分类的 same-file overlap。

### U1. 视频私有化与 Tutor playbook 契约

**Files:**

- `openclacky-ext/cgc-2046/agents/cgc-tutor/system_prompt.md`
- `openclacky-ext/cgc-2046/agents/cgc-tutor/video/**`
- `openclacky-ext/cgc-2046/ext.yml`
- `openclacky-ext/cgc-2046/test/video_pipeline_assets_test.rb`
- `openclacky-ext/cgc-2046/test/cgc_home_panel_test.rb`
- `backend/lib/cgc_2046/mcp/playbooks.ex` 或实际 playbook seed/source
- tutor playbook 的私有增量来源和版本测试

**Work:**

- 吸收 remote 的目录迁移、公开 skill 删除、ext manifest 删除和薄 prompt；
- 在私有 tutor playbook 中补齐“issue 卡配套视频”章节，包含授权确认、环境检查、脚本确认、渲染、抽帧、外部 provider 发布和 typed Material 保存；
- playbook 章节必须明确禁止写 `video:<id>` / `{title, ref}`；
- playbook 版本变更后，Tutor 章节边界重新拉取并展示版本；
- 测试公开扩展不存在 issue-video skill，执行物料完整，脚本不含密钥和本机绝对路径；
- 明确本地视频产物与正式课程 Material 的边界，不声称已有视频对象存储。

**Acceptance:** OpenClacky manifest、tutor prompt、private playbook 和 video asset tests 对同一职责边界一致；playbook 缺失时业务停止。

### U2. OpenClacky typed Material 编辑器

**Files:**

- `openclacky-ext/cgc-2046/panels/cgc-2046-curriculum/view.js`
- `openclacky-ext/cgc-2046/panels/cgc-course/view.js`
- `openclacky-ext/cgc-2046/panels/cgc-2046-tutor-aside/view.js`
- `openclacky-ext/cgc-2046/test/course_content_write_test.rb`
- `openclacky-ext/cgc-2046/test/panel_behavior_harness.js`
- `openclacky-ext/cgc-2046/test/learner_journey_routes_test.rb`
- `openclacky-ext/cgc-2046/test/course_routes_test.rb`

**Work:**

- 将当前 `m-title`/`m-ref` 行改为 `kind` 驱动的字段编辑器；
- `text`/`markdown` 编辑 body；`web`/`image` 编辑 HTTPS URL；image 强制 alt_text；video 编辑 provider/external_id/caption；
- 保存时只序列化 typed Material，保留未知字段以支持无损 round-trip；
- Story materials 与 Objective materials 使用同一编辑器和校验器；
- 旧 material 进入编辑态时显示“需重新保存为 typed Material”，不得静默把 ref 当 url 或 video；
- chapter selector/grouping 保留，不接受 remote 删除章节展示的回退；
- 在 preview 中使用安全外链/Provider adapter，不输出 raw iframe 或任意 HTML；
- 版本冲突后要求重新读取并合并，不覆盖他人草稿。

**Acceptance:** 所有五类 Material 可编辑、保存、重读并保持 typed shape；旧 ref 不会再次生成；章节分组和 Objective/rubric 不丢失；unknown provider 和 unsafe URL 在保存前阻止。

### U3. Backend typed Material 与发布门禁整合

**Files:**

- `backend/lib/cgc_2046/curriculum/content.ex`
- `backend/lib/cgc_2046/curriculum/output.ex`
- `backend/lib/cgc_2046/curriculum/prep_gate.ex`
- `backend/lib/cgc_2046/mcp/tools/save_course_content.ex`
- `backend/lib/cgc_2046/mcp/tools/get_course_content.ex`
- `backend/lib/cgc_2046/mcp/tools/get_course_revision.ex`
- `backend/test/cgc_2046/curriculum/content_test.exs`
- `backend/test/cgc_2046/curriculum/prep_gate_test.exs`
- `backend/test/cgc_2046/mcp/course_content_tools_test.exs`
- `backend/test/cgc_2046/mcp/course_revision_tool_test.exs`

**Work:**

- 清理正式文档/模块示例中的 `{title, ref}`；
- 保持 chapter、objective DAG、typed source、provider allowlist 和 legacy error location 信息；
- Bilibili ID 使用严格格式校验；未知 provider、危险 scheme、iframe/html、缺 alt、缺 provider ID fail closed；
- 增加结构化错误码和教研面板逐条修复提示；
- 确认 MCP draft/revision response 与 GraphQL `courseContent` 字段形状一致；
- 对旧 draft 做只读 inventory，不自动转换和不静默 backfill。

**Acceptance:** 新 typed content 保存/发布通过；legacy ref 明确失败；发布 revision 不可变；MCP/Web/扩展形状一致。

### U4. WorkflowRun 隐私和角色投影保全

**Files:** 当前分支已有 WorkflowRun policy、subject migration、analytics、PlatformAudit、GraphQL schema 和对应 tests；remote 删除的同名文件不能直接接受。

**Work:**

- 以当前分支实现重新对照 develop 的 GraphQL/schema 变化，解决真实冲突；
- 保留 learning run subject backfill、fail-closed policy、Tutor/Owner/Admin analytics 和 Platform Admin redacted audit；
- 确认 remote 分支没有重新引入 `listWorkflowRuns/getWorkflowRun` 或 Workspace raw run 页面；
- 保留 migration preflight、失败原子性和新 run subject 自动填充；
- 更新 generated GraphQL artifacts，不让 remote 生成物覆盖隐私字段。

**Acceptance:** Learner A/B、Tutor、Owner/Admin、Platform Admin、跨 Workspace 的真实 GraphQL negative/positive probes 全部有证据，响应不含 facts/input snapshot/evidence。

### U5. Web 页面、i18n 与真实 agent-browser E2E

**Files:**

- `web/components/learning/course-content-viewer.tsx`
- `web/components/learning/material-renderer.tsx`
- `web/components/learning/course-governance-panel.tsx`
- `web/app/[locale]/w/[slug]/courses/[id]/curriculum/page.tsx`
- `web/app/[locale]/admin/audit/page.tsx`
- `web/lib/graphql/course-content.ts`
- `web/lib/graphql/workflow.ts`
- `web/messages/zh-CN.json`
- `web/messages/en.json`
- 相关测试与 `web/app/[locale]/w/[slug]/workflows/`

**Work:**

- 把新增页面和 Material renderer 中文迁入双语 messages，清理仓库既有 73 处 i18n 门禁残留；
- 对照 develop 的页面回退，恢复并保留课程 reader、治理 projection、audit redaction 和旧 Workflows removal；
- 启动 backend/web dev server，使用真实登录态 agent-browser：Learner、Tutor、Owner/Admin、Platform Admin；
- 做 DOM/样式/几何断言、交互导航、错误态、视频失败态、Workspace 切换 stale guard；
- 记录每个角色的登录方式、GraphQL 响应摘要和页面证据，不保存 token/cookie/password。

**Acceptance:** `pnpm check:i18n && pnpm test` 通过；`pnpm typecheck`/lint/build 通过；agent-browser 四类角色和跨 Workspace 证据齐全。

### U6. Migration failure-proof 与历史数据盘点

**Files:** migration、migration tests、`docs/` cutover/release evidence。

**Work:**

- 在隔离 test DB 构造无法解析的历史 learning run；验证 migration 在 preflight 阶段失败；
- 断言失败后没有半成品字段/index/backfill 或 policy 放宽；
- 盘点现有 draft materials：typed、legacy ref、unknown provider、unresolved count；
- 盘点历史 WorkflowRuns：可 backfill、缺 subject、invalid UUID、unclassified；
- 输出 cutover evidence，明确旧 draft 由内容负责人重新保存，无法 backfill 的 run 需人工 reconciliation。

**Acceptance:** 干净迁移、失败迁移原子回滚、inventory 数量和 unresolved identifiers 可复核。

### U7. Extension/runtime verification 与发布包

**Files:** OpenClacky tests、manifest、README、release evidence、ADR/diagram。

**Work:**

- 运行 Ruby tests、`panel_behavior_harness.js`、`openclacky ext verify`；
- 验证安装后的扩展包包含 `agents/cgc-tutor/video/**`，不包含 `skills/issue-video/**`；
- 在真实连接 OpenClacky 实例验证 playbook 拉取版本、typed content round-trip、章节分组、无 raw WorkflowRun；
- 更新 ADR、课程隐私图、部署/迁移说明，避免声称视频已进入 CGC 自有存储；
- 记录 release packet，把每个 R-ID 映射到代码、测试或真实 E2E 证据。

**Acceptance:** 源码、manifest、打包产物和运行时行为一致；扩展可安装并完成 Tutor 内容工作流。

## Dependency Order

1. U0 整合基线和冲突分类。
2. U1 视频私有化/playbook 契约。
3. U2 OpenClacky typed Material 编辑器。
4. U3 Backend typed Material、MCP、发布门禁。
5. U4 WorkflowRun 隐私和角色投影保全（可与 U2/U3 分支并行，但合并前必须统一 schema）。
6. U5 Web i18n、页面恢复和 agent-browser E2E。
7. U6 migration failure-proof 与历史 inventory。
8. U7 extension runtime、文档、release packet 和最终全套门禁。

## Verification Contract

### Backend

- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- targeted Curriculum/PrepGate/MCP/WorkflowRun/GraphQL tests
- `mix precommit`
- `mix cgc2046.check_licenses`
- clean DB `ecto.drop/create/migrate`
- migration failure atomicity test
- real `/api/graphql` actor matrix

### Web

- `pnpm check:i18n`
- `pnpm test`
- `pnpm typecheck`
- `pnpm lint`
- production build/check
- agent-browser structural, interaction and cross-Workspace assertions

### OpenClacky

- Ruby extension tests
- `node test/panel_behavior_harness.js`
- `openclacky ext verify`
- packaged install smoke
- connected MCP/playbook/content round-trip

## Definition of Done

- `origin/develop` 的视频 skill 私有化已经吸收，但没有删除课程隐私、reader、治理投影、audit 或 migration。
- OpenClacky 不再生成 `{title, ref}`、`video:<id>` 或任意 iframe；所有正式材料都是 typed Material。
- Tutor playbook 是视频方法论唯一来源，公开扩展只包含执行物料；playbook 错误 fail closed。
- Web 全套 i18n/test/typecheck/lint/build 通过。
- Backend 全套 precommit、许可证、干净迁移、失败回滚和真实 GraphQL actor matrix 通过。
- 真实 agent-browser、OpenClacky runtime 和打包安装证据齐全。
- ADR、图、cutover inventory 和 release evidence 与代码一致。
- 分支提交前通过 Mainline preflight，并以 merge commit 方式整合 develop；不直接 push 或 merge main。

## Risks and Open Questions

- `origin/develop` 删除了当前分支的大量隐私/阅读器文件，整合时可能存在真实语义冲突；必须先做 U0，不能自动接受删除。
- 私有 tutor playbook 的源文件/seed 是否在本仓库或外部 cgc-playbooks 仓库，需要在 U1 执行时确认；当前计划只规定接口和门禁，不复制方法论到公开扩展。
- 当前第一阶段没有视频对象存储；如果产品要求 Learner 访问本地生成视频，需要另立对象存储/签名 URL 计划，不能把本地路径塞进 Material。
- 真实登录态 agent-browser 需要现有浏览器 session 或测试账号；凭证恢复和脱敏必须遵守仓库规则。
