---
title: "报名成功后的 User Journey 修复方案"
date: 2026-09-09
status: proposed
artifact_readiness: implementation-ready
execution: code
source: "代码取证（scout 全链路调研 + 主会话直读），见「现状证据」各条引用"
---

# 报名成功后的 User Journey 修复方案

## Goal Capsule

报名成功的下一个动作是「开始学习」，不是「知道报上了」。当前 `/w/[slug]/courses/:id` 报名成功后只剩纯文案「你已报名该课程。」，无跳转、无链接、无通知——而下游能力（内容授权、阅读页、我的学习）全部已存在，断的只是入口。本方案补齐入口，让报名 → 学习形成闭环。

关联图：`docs/diagrams/user-journey-enrollment-learning.puml`（角色泳道现状图，断点①-⑥ 与本文件编号一致）。

## 现状证据（断点清单）

| # | 断点 | 证据 |
|---|------|------|
| ① | 工作台详情页成功态/回访态只有纯文案，无任何出口；公开页仅一行弱化小字链接 | `web/components/offering-pages.tsx:1402-1405`（纯文本，全文件无 `/participations`、`/learning` 引用）；`web/components/public-offering-detail.tsx:512/541/553` |
| ② | `/participations` 报名 tab 的 confirmed 卡片无「进入课程」入口，卡片不可点 | `web/app/[locale]/participations/page.tsx` `EnrollmentCard`（:64-176） |
| ③ | `offering.status !== "open"` 时工作台报名卡（含已报名状态）整块不渲染 | `web/components/offering-pages.tsx:1340-1346` 渲染门 |
| ④ | 租户无已发布 `type=learning` WorkflowDefinition 时 run 种不出，学习 tab 空态——尽管内容授权此时已满足 | `backend/lib/cgc_2046/learning/learning_instantiator.ex:86-99`（best-effort skip）；`backend/lib/cgc_2046/learning/runs.ex:349-372`（my_learning_runs 只取 confirmed） |
| ⑤ | 阅读页空态是死文案「暂无可读课程内容」，无开课提示、无返回引导 | `web/components/learning/course-content-viewer.tsx:96-110` |
| ⑥ | `enrollment.completed` 信号无任何用户通知 deep link，关页即失联 | `backend/lib/cgc_2046/admission/enrollment.ex` 信号面（submitted/completed/approved/rejected） |
| ⑦ | `/learning` 与 `/participations`（默认学习 tab）渲染同一个 `LearningTab`，双「学习主页」并列 | `web/app/[locale]/learning/page.tsx`；`web/app/[locale]/participations/page.tsx:385-390` |

**关键事实**：内容授权 = staff ∪ **本人 confirmed enrollment** ∪ run 持有者（`backend/lib/cgc_2046/learning/authorization.ex`）。报名 confirmed 即解锁阅读，**不依赖 learning run**——因此入口修复不需要动后端授权链路。

## 目标 Journey

按 enrollment 终态分叉 CTA：

| 状态 | 成功反馈 | 主 CTA | 落点 |
|------|---------|--------|------|
| confirmed（未开课） | ✓ 报名成功 | 开课后在此学习 · X | `/learning/courses/:courseId` |
| confirmed（已开课） | ✓ 报名成功 | **进入课程** | `/learning/courses/:courseId` |
| payment_pending | 弹支付（现状保留） | 支付成功后就地落 confirmed 卡，同上 | 同上 |
| pending | 申请审批中 + 审批截止时间（后端 `approval_deadline` 已有） | 在「我的参与」跟踪 | `/participations` |

回访路径渲染与成功态相同的 CTA，形成闭环：

```
详情页报名 → 进入课程（内容阅读页）→ /learning 掌握地图 + next_action → 回访任一入口可直达
```

## 改动点

### P0（纯前端，授权现状即生效）

1. **详情页 confirmed CTA**：工作台（`offering-pages.tsx`）与公开（`public-offering-detail.tsx`）两条链路的 confirmed 成功态、`myEnroll` 回访态、支付成功 `onPaid` 刷新后，统一渲染主按钮 → `/learning/courses/{courseId}`；次级链接「在我的参与查看」保留。按 `startsAt > now`（字段已有）分叉文案：未开课显示「开课后在此学习 · X」，已开课显示「进入课程」。
2. **阅读页空态升级**（`course-content-viewer.tsx`）：空文案改为「课程开始后会在这里看到内容」+ 返回 `/learning` 链接——保证 P0 的 CTA 永远不指向死胡同。
3. **i18n**：`offerings` / `offeringDetail` / `courseReader` 命名空间加 `enterCourse` 等文案（zh-CN + en）。

### P1（补全回访入口与小量后端配合）

4. **参与列表入口**：`EnrollmentCard` 在 `status === "confirmed" && courseId` 时加「进入课程」链接（查询已含 `courseId`，无需后端改动）。
5. **拆开 open 门**：`offering.status !== "open"` 时已报名状态卡仍渲染（状态展示与报名操作分离）；注意**不能**连带放出报名按钮。
6. **学习 tab 兜底**：confirmed 但未种出 run 的课程也给内容入口——目前「查看课程内容」链接长在 run 行上，run 缺失即无入口，与「授权不依赖 run」矛盾。
7. ~~**completed 通知 deep link**：`enrollment.completed` 信号管道已存在，通知模板加 deep link 落 `/learning/courses/:courseId`。~~ **实施期证伪，本次不实施**：微信订阅消息 `page` 参数仅支持小程序路径（`backend/lib/cgc_2046/integrations/wechat/client.ex:63-72` `notification_page/2`，learner 模板落 `pages/my-enrollments/index`），且小程序当前无课程学习页（`miniprogram/src/pages/`：discover/enrollment-result/event-detail/join/login/my-enrollments/openclacky/order-pay/privacy/profile/register-form/workspace）——web deep link 在该通道不可达。需小程序新增课程学习页（含课程 id 路由参数）后独立排期。

### P2（精化，可后续）

8. **hasPublishedContent 精化**：offering 查询带 `Curriculum.latest_revision` 存在性，无内容时详情页 CTA 降级为「开课后在『我的学习』开始」→ `/learning`，替代 P0 的 startsAt 启发式。
9. **学习主页信息架构收敛（断点⑦）**：`/learning` 与 `/participations`（默认学习 tab）渲染同一个 `LearningTab`，两个并列「学习主页」易混淆。倾向：内容页（`/learning/courses/:id`）为学习主落点，掌握地图收敛为内容页的下一层/侧栏，而非并列主页。需单独讨论。

## 验收标准

- 免费开放课：报名成功当屏出现「进入课程」，点击直达内容页并能看到已发布 curriculum。
- 付费课：支付成功后就地刷新的 confirmed 卡同样出现该 CTA。
- 未开课课程：CTA 显示开课时间；内容未发布时阅读页空态有引导而非死文案。
- 刷新/回访详情页、进 `/participations` 报名 tab：confirmed 课程均可一键进入内容页。
- 课程转非 open 后，已报名用户回访详情页仍能看到报名状态与入口，但不会出现报名按钮。
- 收到 completed 通知时，点击直达 `/learning/courses/:courseId`。

## 风险与注意

- **open 门拆解（P1-5）**：当前 `offering.status === "open"` 把「状态展示」和「报名操作」锁在一个渲染条件里，拆开时只放行已报名状态卡，报名按钮仍受 open 约束。
- **run 缺失与内容可达性解耦（P1-6）**：若长期方向是「run = 进度跟踪、enrollment = 内容准入」，学习 tab 的数据源可能需要从 `myLearningRuns` 扩展为「runs ∪ confirmed enrollments」，本方案只做入口兜底，不改数据模型。
- **通知（P1-7）**：原设计假设通知可带 web URL——实施期证伪（见 P1-7 条），本次未实施。
- **前提保障边界（运营侧，不在本方案）**：断点④/⑤只修了学员侧入口与兜底文案；「租户无已发布 learning 定义」（前提 B）与「curriculum 未发布」（前提 A）的**成因**——建课时未引导 Owner 发布 learning 定义、Tutor 未及时 publish 内容——属于运营侧建课 journey，本方案不覆盖。若 P0/P1 落地后空态仍频繁出现，需另开建课流程引导项。

## 实施状态（2026-09-09）

分支 `sundevilyang/enrollment-success-journey`（base `origin/develop` 4d7844d7），改动全部落在 `web/` + `docs/`，**零后端改动**。

| 项 | 状态 | 落点 |
|---|---|---|
| P0-1 详情页 CTA（双链路 × 成功态/回访态/支付后） | ✅ | `offering-pages.tsx` `enrollmentFollowUp()`；`public-offering-detail.tsx` 同款；startsAt 分叉文案 |
| P0-2 阅读页空态升级 | ✅ | `course-content-viewer.tsx` 空态块 + 返回 `/learning` |
| P1-4 参与列表入口 | ✅ | `participations/page.tsx` `enter-course-<enrollmentId>` |
| P1-5 拆 open 门 | ✅ | 卡片渲染去 open 门；非 open 未报名显示「报名已关闭」 |
| P1-6 学习 tab 兜底 | ✅ | `coursesWithoutRuns()` + `extraCourses` prop；`/learning` 与 `/participations` 双入口 |
| P1-7 通知 deep link | ❌ 证伪 | 微信 `page` 仅小程序路径，小程序无课程页（见上） |
| pending 态截止时间 | ✅ | `approvalDeadline` 入 `MyEnrollmentRow` + 两查询 + `fetchMyEnrollment` |

验证：`pnpm typecheck` ✓ · `pnpm check:i18n` ✓（1701 键对齐）· `pnpm test` 926/926 ✓（新增 12 条行为测试）。
