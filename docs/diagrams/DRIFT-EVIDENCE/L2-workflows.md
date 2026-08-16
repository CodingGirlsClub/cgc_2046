# L2 业务工作流层漂移取证底稿（图 ↔ codebase）

> 取证：L2WorkflowScout（2026-08-16）· 基准：`.worktrees/docs/diagram-taxonomy`（develop@72c5924）
> 汇总判定见 [DRIFT-REPORT.md](../DRIFT-REPORT.md) §5.3；本文件为证据底稿。

## 1. Codebase 实际 workflow 类型全集与驱动机制

权威源 `backend/lib/cgc_2046/workflows/workflow_definition.ex:40-47`：`@type_values [:platform_ops, :learning, :enrollment, :sponsorship, :speaker_invitation, :research]`（注释自称「全 6 枚举，领域模型定稿 ER §5.2 权威源」）。

驱动机制总纲：**数据驱动而非硬编码**。`jido_adapter.ex:56-100 build_workflow/1` 把 node_def 的 steps 编译为 runic DAG（四分类 auto→ActionNode / manual→信号门控子图 / gate→Condition / sub_workflow→递归）；不存在按 type 分派的硬编码 instantiator DAG。但「是否真的走引擎」按类型分三档：

| type | 驱动机制 | 建 run？ | 走 Engine？ | 证据 |
|---|---|---|---|---|
| research | ResearchInstantiator 订阅 `event.launched`/`course.launched`（state_based 幂等，key=`event_<id>`/`course_<id>`）→ find_or_create_and_start | ✅ | ✅ 全量 DAG 执行（start_run→Engine.run） | research_instantiator.ex:16-67；application.ex:26 |
| speaker_invitation | SpeakerInvitationInstantiator：定义按 workspace find_or_create（内置模板），create_invitation 事务内起 run，run 镜像 decision/materials 双人工门控 | ✅ | ✅（manual-only 最小 DAG） | speaker_invitation_instantiator.ex:12-40；speaker_invitation.ex:422-430 |
| learning | LearningInstantiator 订阅 `enrollment.completed`（claim_in_handle 幂等，key=`enrollment_<id>`）→ `start_action: :start` **纯状态流转，不经 Engine**（「协议而非 DAG」，算法在学员 BYO agent） | ✅ | ❌ 刻意绕过 | learning_instantiator.ex:4-16,49-62；workflow_run.ex:685 |
| enrollment | **无 instantiator**。Enrollment 资源自序贯：Ash action 事务内条件 UPDATE（capacity/invite quota/部分唯一索引）直接落 pending/confirmed；workflow_run_id 列保留不写 | ❌ | ❌ | enrollment.ex:1-10,50,363-398；application.ex 无挂载 |
| sponsorship | **无 instantiator**。实体自序贯；代码注释明示「workflow_run_id 保留列供二期引擎化（v1 实体自序贯不创建 run）」 | ❌ | ❌ | sponsorship.ex:226-227 |
| platform_ops | 有枚举值，无任何 instantiator/订阅/建 run 代码（预留位） | ❌ | ❌ | 全库 grep Instantiator 仅 3 处实现 |

生命周期伴生（图未画）：ResearchRunReaper（event/course.ended → cancel 教研 run）、SponsorshipEndedSubscriber、ApprovalExpiryWorker、LearningProgressWorker、ReconciliationScanWorker（application.ex:25-35；workers/ 目录）。

## 2. 差异表（图断言 vs 码现实）

判定四态：✅一致 ｜ 🟦图超前码 ｜ 🟨码超前图 ｜ 🔀双向漂移

| # | 图断言 | 码现实 | 判定 | 证据文件 |
|---|---|---|---|---|
| 1 | L2 共 4 张业务 workflow 图（enrollment/sponsorship/invitation/research），隐含业务流程=workflow 编排 | type 枚举 6 值；仅 3 类真正建 run；enrollment/sponsorship 实体自序贯不建 run | 🔀 图多画了编排（enrollment/sponsorship 两张图的 DAG 在码中不存在），码多出 learning/platform_ops 两类 | workflow_definition.ex:40-47；sponsorship.ex:226；application.ex:25-35 |
| 2 | 报名图：报名段 S1–S8 + 审批段 A1–A5，P1 持久化 pending 由 workflow step 驱动 | Enrollment 创建/审批全在 Ash action（prepare_policy 直接落 pending/confirmed；claim_pending 条件 UPDATE 转 confirmed/rejected），无任何 run | 🟦 图超前码（v1 拍板实体自序贯） | enrollment.ex:363-418 |
| 3 | 赞助图：Intent 段+审批段两段式 workflow | 同上，实体自序贯 pending→active/rejected，workflow_run_id 预留二期 | 🟦 图超前码 | sponsorship.ex:226,535-539,703-704 |
| 4 | 邀请图：S1 创建→S2 决策→A1/M1/M2 或 R1，材料落 WorkflowRun.facts | 码结构一致：create 起 run、save_materials 写 facts[materials]、resume_run/fail_run 镜像、declined→run failed | ✅（唯一步骤命名/编号是文档层约定，码按 manual 门控实现） | speaker_invitation.ex:275-277,422-430,625-727；speaker_invitation_instantiator.ex:12-17 |
| 5 | 教研图：三段式 S0–S12 模板，key=event_#/course_#，event.launched 实例化 | 码一致：订阅信号、key 约定、DAG 数据驱动、reaper 回收；S0–S12 具体步骤是 definition 数据（node_def），非代码硬编码 | ✅（拓扑在数据层，图↔种子定义才需逐 step 对） | research_instantiator.ex:16-67；jido_adapter.ex:56-100；research_run_reaper.ex:39-41 |
| 6 | WorkflowRun 6 态：pending→running→waiting→succeeded/failed/cancelled | 码 7 态：+`expired`（`@status_values` 含 :expired；:expire 动作 pending/waiting→expired） | 🟨 码超前图 | workflow_run.ex:71,393-397 |
| 7 | 图：WAITING→CANCELLED「deadline 到点唤醒 cancel 🟡 待 v1 补测（Schedule Directive 或恢复检查）」 | 已落地但形态不同：ApprovalExpiryWorker Oban 周期扫描 → waiting→**expired**（非 cancelled；deadline=进 waiting 的 updated_at+definition.approval_timeout，nil=永不超时，F7 方案 A） | 🟨 码超前图且语义偏移（expired≠cancelled；Oban 扫描≠Schedule Directive） | approval_expiry_worker.ex:6-16,63-99,138-150 |
| 8 | 图 Step 四分类（自动/人工/门控/子 workflow） | jido_adapter 编译四分类完全对应（auto/manual/gate/sub_workflow） | ✅ | jido_adapter.ex:28-51；workflow-run-state.puml note |
| 9 | 图：WorkflowDefinition 状态机 draft→published→archived（+new_version） | 码一致 `@status_values [:draft,:published,:archived]` + new_version 复制 Step/StepRow | ✅ | workflow_definition.ex:48,74-79 |
| 10 | Enrollment 实体图：draft→submitted→pending→confirmed/rejected/cancelled | 码：`[pending,confirmed,rejected,expired,cancelled]`——无 draft/submitted（创建即 pending/confirmed）；多 expired | 🔀 图多 draft/submitted（码从未实现），码多 expired | enrollment.ex:58,363-398,441 |
| 11 | Sponsorship 实体图：pending→active→rejected/ended | 码：`[pending,active,rejected,expired,ended]`——多 expired（pending 超时可重提） | 🟨 码超前图 | sponsorship.ex:84,746-748 |
| 12 | SpeakerInvitation 实体图：invited→accepted/declined/**expired**（可选）→completed | 码：`[invited,accepted,declined,completed]`——**无 expired 态**（expires_at 仅作 token 校验谓词，不落状态） | 🟦 图超前码（图标「可选」，码选择不做态） | speaker_invitation.ex:38,127-128 |
| 13 | InviteBatch 实体图：active→disabled/**exhausted** | 码：`[active,disabled]`——无 exhausted 态（配额尽=remaining_quota=0 条件 UPDATE 扣减失败） | 🟦 图超前码 | invite_batch.ex:53,105-108 |
| 14 | 赞助图 note：「支付/开票=二期（状态机插 payment_pending→paid）」（F4 预留建议） | **全库无任何支付状态**：grep payment\|paid\|refund 仅命中通知配额 refund（notification_consent.ex:67），无 payment_pending/paid/支付资源 | ✅ 图码一致地「未做」（二期声明成立；feat/payment-loop 分支不在本基准） | sponsorship.ex:84；grep 全 lib |
| 15 | 图：learning 无 L2 图 | LearningInstantiator + LearningProgress 进度投影 + LearningProgressWorker 停滞提醒 + E-10 对账规则⑦——完整子系统 | 🟨 码超前图（缺 workflow-learning.puml） | learning_instantiator.ex:1-16；learning_progress.ex:9-23 |
| 16 | 图：platform_ops 无图、无文档提及 | 枚举存在但零驱动代码 | 🟨 码超前图（且超前自身——枚举无消费方） | workflow_definition.ex:42 |
| 17 | 图：course-issue 学习闭环无图 | 设计已定稿（docs/01-定稿设计/课程issue学习闭环详细设计.md v1.0，2026-08-16：issue 卡/LearningRecord/Todo-In Progress-Done 派生态）但**零实现**：无 LearningRecord/checklist/issue 资源；进度仍 step 级（completed_manual_steps）非 issue 级（doneIssues）；唯一代码锚点 @membership_deferred 为既有事实 | 🟦 设计/图双超前码 | 课程issue学习闭环详细设计.md:1-63；learning_progress.ex:44-63；mcp/wrapper.ex:30 |
| 18 | （图内部）README L2 清单自述「报名三段式 S0–S6/S7–S9/S10–S12」「邀请 S7 校验批次」 | 实际 puml 用报名段/审批段（S1–S8,A1–A5）与邀请 S1/S2/A1/M1/M2/R1；三段式 S0–S12 仅 research | 🔀 README↔puml 内部漂移（同目录资产互相矛盾） | docs/diagrams/README.md:97-100 vs workflow-enrollment.puml/workflow-invitation.puml |

## 3. 状态机对照结论

**WorkflowRun**：图 6 态 vs 码 7 态（+expired）。转移对照：create→pending、start（pending→running）、start_run（pending→running→succeeded|waiting|failed）、wait、resume/resume_signal（waiting→running→…）、complete（running/waiting→succeeded）、fail、cancel（pending/running/waiting→cancelled）均与图一致（workflow_run.ex:244-397）；码额外 `:expire`（pending/waiting→expired）。图上唯一「🟡待补测」的 deadline 唤醒路径已由 Oban 周期扫描实现，但落点是 expired 而非图示 cancelled——建议图补 expired 态并把该转移改到 WAITING→EXPIRED。

**业务实体**：Enrollment（图多 draft/submitted、码多 expired）、Sponsorship（码多 expired）、SpeakerInvitation（图多 expired、码无）、InviteBatch（图多 exhausted、码无）四家全部存在状态集偏差；WorkflowDefinition 唯一完全一致。**支付相关新状态：不存在**——payment_pending/paid 仅存在于赞助图二期注释（F4 建议预留），develop 基准代码零实现、零预留列；支付工作在 feat/payment-loop worktree，不在本对照范围。

**结构性结论**：L2 四张业务图中，真正「图=码」的只有 invitation 与 research；enrollment/sponsorship 两张图描绘的引擎化 DAG 是设计意图（二期引擎化预留列在码中留有痕迹：enrollment.ex:50 / sponsorship.ex:65 的 workflow_run_id），v1 现实是 ADR-0005 实体自序贯。反向的码有图无：learning（完整子系统）与 platform_ops（空枚举）。修复建议优先级：① 补 workflow-learning.puml；② workflow-run-state.puml 加 expired 态并改 deadline 转移；③ entity-state-machines.puml 按 :58/:84/:38/:53 四处枚举修正；④ enrollment/sponsorship 两图标「(二期引擎化蓝图，v1 实体自序贯)」限定语；⑤ README L2 行描述与 puml 对齐。
