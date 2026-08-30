# ADR-0011:Learning v2——不可变评价账本与派生掌握投影

- 状态:已接受(2026-08-30;随 role-agent-journeys-v2 S8 落地)
- 决策者:product owner(计划 2026-08-29-1110 第五部分草案 → 本片实施定稿)
- 对照:ADR-0009 §目标地图 Learning 行("Learning (core) —— LearningRecord(记忆挂人)、进度投影")与 CONTEXT.md 旧「学习记录」词条

## 背景

- 现状 Learning 域 = `LearningRecord`(checklist 条目打勾账本,唯一键 `(course_id, user_id, issue_id, item_id)` upsert 最新为准,"记忆挂人不挂报名")+ `Progress`(issue 口径纯函数投影)+ `RunProjection` + `LearningInstantiator` + `LearningProgressWorker`。
- 产品契约 R36–R48 要求:不可变评价(Attempt)、四态掌握(Mastery)、间隔复习(ReviewSchedule)、确定性下一步(NextAction)、版本绑定(run × CourseRevision)、无限重试、Agent 不可直写掌握态。checklist 打勾模型无法承载"评价可审计、掌握可解释、复习可调度"。
- 旧参考实现已给出完整语义(`.worktrees/role-agent-journeys`),本 ADR 把它按新地图定型。

## 决策

- **L1:`Learning.Attempt` 不可变评价账本(唯一写模型)。** 属性:workspace_id(租户,writable? false)/ learning_run_id / course_revision_id / objective_id(string 宽存)/ evidence / rubric_results / passed / rationale(恒必填)/ confidence(0..1)/ agent_meta / 仅 `created_at`。**actions 只有 `:create` 与 `:read`**——失败评价永不删除,重试写新行(R44)。policy:写 = 仅 run 持有者本人(fail-closed);读 = run 持有者 ∪ 本台 tutor/owner/admin;**平台管理员刻意不放行**(R16/R48 配套红线)。不开 GraphQL 面(投影消费)。
- **L2:Mastery 为纯函数投影,不建表。** qualifying 判据单源:`passed ∧ confidence ≥ 0.8 ∧ rubric 精确覆盖全部 criterion 且逐条 met`。四态 latest-attempt-driven:无 attempt = unassessed;无一 qualifying = developing;最新 qualifying = mastered;曾 qualifying 但最新失败 = needs_review。`ever_mastered` 粘性(解锁与完成判定用它,复习失败不倒退);`first_mastered_at` 锚首条 qualifying。
- **L3:掌握聚合键 = (learning_run, objective)。** 每个 run 的掌握态独立派生——是 R36/R37"新 Run 从新版事实重新评价"的直接落法。**语义修订**:旧"记忆挂人不挂报名"词条随 LearningRecord 退役改写为"**账本挂人**(attempts 永久保留、跨 run 可审计可回放),**掌握态挂 run × revision**"。跨 run/跨 enrollment 的掌握延续 = deferred(投影不建表的红利:账本俱在,未来按人×revision 重算即可,无需迁移)。
- **L4:ReviewSchedule 派生不建表。** 里程碑 [1, 7, 30] 天锚 `first_mastered_at`;掌握后 qualifying attempt 按序消费里程碑(须晚于上一里程碑锚点,防突击刷档);失败复习不消费任何里程碑且使当前态 needs_review 立即到期;全必修 ever_mastered 后完成守卫生效(run 完成记录不因复习失败撤销,AE10)。**v1 已知边界**:已 succeeded 的 run 不接受新 attempt——完成后的复习提交通道留后续切片单独决策。(S9 已实施:review_queue 接通 get_learning_state / submit_learning_attempt / GraphQL courseLearningDetail,扩展面板复习队列区就位)
- **L5:NextAction 纯函数五级优先。** 完成守卫先行(全必修 ever_mastered → nil);否则 review → remediation(developing 的先修中有 needs_review 者)→ developing(最近活动者)→ next_required(内容序首个已解锁必修 unassessed)→ elective。`unlocked?` = 全部 prereq_ids ever_mastered;锁定项返回缺失先修 id+title,工具层拒绝对锁定 objective 提交 attempt(R41 不可绕过)。"确定性路径算法属网站"由本函数族独占。
- **L6:LearningRun 维持 WorkflowRun 载体(ADR-0005 复审通过),revision 绑定走 input_snapshot。** 证成:run 承担进度投影、停滞看护(规⑦)、完成账本,与既有 instantiator/对账/通知链路连续;无新增跨角色编排诉求,不值得自建 Run 资源。绑定机制沿 enrollment 锚先例:`input_snapshot["course_revision_id"]` 创建期固化 + `Learning.Runs` 域内唯一读取面;instance key `learning_<enrollment_id>_<revision_id>`(revision 缺失兜底 `"none"`),按 key 命中任意状态即 resume;`LearningInstantiator`(信号路径)与 `start_learning_run`(工具路径)共用 `Learning.Runs.instance_key/2`,两路径幂等互通。**不在 `workflow_runs` 加域列、不给 `find_or_create_and_start/4` 加 opt**——generic 引擎面零膨胀;查询/分析一律走 `learning_attempts` 实列。
- **L7:退役清单(无兼容层、无数据迁移)。** 删除 `Learning.LearningRecord`(drop `learning_records` 表)、`Learning.Progress`(issue 口径投影,objective 口径由 Mastery/Runs 取代)、MCP `get_learning_records`/`save_learning_records`、内容 `story.checklist` 的学习语义(checklist 校验保留,v1 内容兼容;学习消费面消失);web `myLearningRuns` / `courseLearningDetail` 与扩展课程面板同步切 objective 口径。

## 拒绝的替代

- **Mastery 建表(写模型)**:Agent 或任何写路径都可能污染掌握态;投影可从账本重算,建表引入双写一致性负担(R43"Agent 不能直接写 Mastery"的最强执行 = 根本没有可写的表)。
- **掌握按 (user, revision) 穿透 run 聚合**:会使退款重报/学新版的新 run"出生即完成",与 R36/R37"新 Run 从新版事实重新评价"矛盾;且参考实现语义为 per-run,不重新发明产品行为。
- **跨 Revision 掌握迁移**:产品契约明拒(R37)。
- **`workflow_runs.course_revision_id` 列**(参考实现路径):generic 引擎表加域列重开 ADR-0009 关闭的门;enrollment 锚先例已确立 input_snapshot + 域读取面为 run 域事实的正统形态;列的可查询性收益由 attempts 实列覆盖。
- **Learning 自建 LearningRun 资源**:instantiator/progress/对账规①⑦/通知全链重接线,无新增不变量,纯搬家成本。
- **Tutor 逐次审核评价**:产品契约明拒(R44,即时反馈 + 无限重试)。

## 后果

- `领域模型定稿.md` §5.4 Learning 行改写:`LearningRecord` → `Attempt(不可变评价账本)+ Mastery/ReviewSchedule/NextAction(派生投影与纯函数族)`;CONTEXT.md 词条同步(「学习记录」词条退役改写 + 新增 Attempt/Mastery/复习调度/NextAction/Runs 词条),随落地切片(S8/S9)入册。
- 对账规⑦ 停滞判据改"最新 attempt created_at"(detail 键 `last_activity_at`);规① 不变(仍按 input_snapshot enrollment 锚)。
- 已知代价:完成判定与账本非同事务(一拍窗口,worker 兜底);succeeded run 无复习提交通道(v1 边界);GraphQL 学习类型破坏性变更(登录面,一次性切换)。
