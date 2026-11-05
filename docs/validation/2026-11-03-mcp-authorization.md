# MCP 授权修复与同族普查：#1084 / #1087

关联：[#1084](https://github.com/CodingGirlsClub/cgc_2046/issues/1084)、[#1087](https://github.com/CodingGirlsClub/cgc_2046/issues/1087)。基线：`653fcf96`。

## 结论与授权边界

两个问题均已通过真实 `/mcp` endpoint、真实终端连接 token 和会话复现。

- **#1087**：`Confirmation.confirm/2` 校验 pending 的归属、状态与有效期，再直接调用 `execute_confirmed/2`，不会重跑原工具的 scope 或 Wrapper 门。四个 Flashback 管理执行器原先没有授权检查，且其业务函数使用系统权限。现在四个执行器在副作用之前检查 `PlatformAdmin.platform_admin?/1`，失权返回 `forbidden: platform admin required`。
- **#1084 审核写面**：`Prep.reviewer?/2` 在未指定 reviewer 时原先恒为 true。现在默认仅当前 assignee 可审，与 Owner/Admin 取并集；显式 reviewer 可以是任一工作台成员，允许自审。审核、覆盖质量门、退回修改与审核待办共用此判定。确认阶段仍重新读取当前 run 和成员资格，改派及撤销成员资格立即生效。
- **#1084 读取面**：三个列表改用携带 actor 与 tenant 的领域读取。Course 通过领域 policy 的 `draft_roles: [:tutor]` 授权 tutor 读草稿；Event 不启用该选项。邀请课程摘要按课程领域权限读取；`get_prep_status` 另允许当前 active run 的审核人读取该课程的教研状态投影，例外不扩展课程列表或 GraphQL 的草稿读权。

以下为目标工作台成员的普通权限，平台治理 policy 的例外仍由资源层判定：

| 调用者 | 课程列表 | 活动列表 | 招募批次列表 |
|---|---|---|---|
| 无角色成员、learner、volunteer | open / closed | open / closed | open |
| tutor | draft / open / closed | open / closed | open |
| Owner / Admin | 全部状态 | 全部状态 | 全部状态 |

显式 `status` 参数只能收窄可见集合。tutor 对课程草稿的读取同时适用于 MCP 和 GraphQL，因为授权条件位于领域 policy。

这是授权语义调整，无迁移和存量数据改写。已有的未指定 reviewer 的 prep run 与 pending 使用新规则；确认拒绝后沿用既有语义回滚为 pending，恢复权限后可在 TTL 内重试。

## #1087：确认执行器普查

除本次修复的四个执行器外，另外 12 个 `admin_*` 确认执行器均将 actor 传入领域写操作，由领域 policy 复核平台管理员权限。

| 工具 | 判定 | 授权依据 |
|---|---|---|
| `admin_send_flashback_outreach` | 本次修复 | 入队与治理留痕之前显式复核 |
| `admin_resend_flashback_outreach` | 本次修复 | 重发入队之前显式复核 |
| `admin_soft_delete_wish` | 本次修复 | 系统软删除之前显式复核 |
| `admin_soft_delete_wish_comment` | 本次修复 | 系统软删除之前显式复核 |
| `admin_approve_workspace_application` / `admin_reject_workspace_application` | 未发现同形漏洞 | `WorkspaceApplication` approve/reject policy |
| `admin_create_workspace` | 未发现同形漏洞 | `Workspace` create policy |
| `admin_reassign_workspace_owner` | 未发现同形漏洞 | `Workspace` reassign_owner 的 `forbid_unless(PlatformAdmin)` |
| `admin_promote_user` / `admin_demote_user` | 未发现同形漏洞 | `User` set_platform_admin/demote_platform_admin policy |
| `admin_create_initiative` / `admin_update_initiative` / `admin_open_initiative` / `admin_close_initiative` / `admin_cancel_initiative` | 未发现同形漏洞 | `Initiative` create/update policy |
| `admin_upsert_initiative_rule` | 未发现同形漏洞 | 新建和更新均受 `InitiativeRule` policy 约束 |

关键证据：`backend/lib/cgc_2046/mcp/confirmation.ex`、`mcp/tools/admin_*.ex`，以及 `accounts/{user,workspace,workspace_application}.ex`、`initiatives/{initiative,initiative_rule}.ex` 的 policies。HTTP token 校验每次重读 User，因此同一 token / 同一会话的下一次确认会拿到降级后的 actor。

## #1084：成员门之后的系统读取普查

检查默认 member-only 工具中的直接 `authorize?: false`，并追踪 `Course.fetch_scoped`、Prep 与共享 helper 的间接读取。此表按工具列出返回面与领域 policy 的比较；“未发现同形漏洞”不等于全面安全审计。

| 工具 | 判定及依据 |
|---|---|
| `list_workspace_courses` | 本次修复：按 Course actor policy 读，保留 tutor 草稿发现面 |
| `list_workspace_events` | 本次修复：按 Event actor policy 读，普通成员仅 open/closed |
| `list_recruitment_cohorts` | 本次修复：按 RecruitmentCohort actor policy 读，普通成员仅 open |
| `get_prep_status` | 领域 actor 读之外，仅本台 active run 的当前审核人可读取 draft 的状态投影；例外直接使用已授权 run，不懒建新周期；其余隐藏草稿返回 not found |
| `create_invitation` | 本次修复摘要读取：首段原先能回显无权读取的课程标题；现在按 actor 读，隐藏课程与不存在同形，不建 pending |
| `approve_prep` / `override_prep_gate` / `request_changes_prep` | 本次收紧 reviewer 判定；工具细粒度授权在返回摘要或修改流程之前发生，确认写再次授权 |
| `get_workspace_context` | 未发现同形漏洞：成员资格满足 Workspace 读条件，返回基本信息及本人角色 |
| `list_my_tasks` | 未发现同形漏洞：先筛本人可处理任务，再装配课程标题；显式 reviewer 的任务授权是课程读之外的定向投影 |
| `list_enrollments` | 未发现同形漏洞：先限制管理角色，再按 actor 读 Enrollment；人数和用户摘要只装配已授权的报名集合 |
| `list_attendances` | 未发现同形漏洞：先限制管理角色，再按 actor 读 Attendance；报名、订单和用户摘要仅来自本场已授权核销集合 |
| `batch_create_events` | 未发现同形漏洞：管理角色先于批处理；冲突读取仅同台回显标题，他台不回显数据库记录 |
| `save_course_content` | 未发现同形漏洞：staff 判定先于课程、草稿版本及流程镜像读取 |
| `update_course` / `update_event` | 未发现同形漏洞：管理角色及 actor 资源读取先于报名计数和关联摘要 |
| `assign_prep_tutor` | 未发现同形漏洞：管理角色先于 Course/Prep 的系统读取 |
| `claim_prep_authoring` | 未发现同形漏洞：tutor 或管理角色先于系统读取，符合教研授权 |
| `get_course_learning_analytics` | 未发现同形漏洞：staff 先于课程聚合，只返回教学统计，不返回学员证据正文 |
| `update_prep_policy` | 未发现同形漏洞：策略写两段均复核管理资格 |
| `submit_prep_quality_report` | 业务返回受 assignee/管理角色保护；授权前的课程/run 查找可区分不存在、无 run 与无权限，存在性差分需单独评估 |
| `submit_prep_for_check` | 待单独评估：`ensure_active_run` 发生在细粒度授权之前，可能建 run 后才返回 forbidden；需结合 `get_prep_status` 允许懒开下一周期的既有契约决定副作用边界 |
| `list_event_moderators` | 既有定向投影例外：`Events.Moderators.list/3` 显式允许活动主理人，而 EventModerator 资源读 policy 更窄；需统一契约后再决定是否收紧 |
| `assign_event_moderator` / `remove_event_moderator` | 未发现同形漏洞：helper 先判管理角色，后续读取用于已授权操作的回显与通知 |

工具证据位于 `backend/lib/cgc_2046/mcp/tools/<tool>.ex`。领域对照：`offering/actor_reads_offering.ex`、`courses/course.ex`、`events/event.ex`、`recruitment/recruitment_cohort.ex`、`workflows/workflow_run.ex`、`curriculum/output.ex`、`events/moderators.ex`。

`get_prep_status.tutor_summary` 的用户 ID/显示名属于绕过 User 资源 read policy 的成员投影。父课程可见性已修复；该投影是否需要进一步收紧，属于独立的产品契约问题。未进行生产数据普查，也没有据此判断曾发生真实越权事件。

## 验证

新增 `backend/test/cgc_2046_web/mcp_authorization_test.exs`，16 项真实 HTTP 测试覆盖：

- 四个管理工具先 pending、经真实领域 action 降级、复用 token/session 确认拒绝；核对触达记录与软删除状态无变化、pending 回滚和 forbidden 审计；恢复权限后同一 pending 成功。
- 三个审核工具拒绝无角色成员、learner、未指派 tutor；覆盖 review_required=true/false 的覆盖质检门路径；确认窗口改派后拒绝，显式无角色 reviewer 保持可用。
- 三个列表对无角色成员、learner、tutor、纯 Admin、纯 Owner 的 ID 集合与领域 actor 读集合相等；同时检查明确的非空预期集合、draft 过滤，以及课程/活动 cancelled 可见性。
- 草稿教研状态与邀请摘要拒绝普通成员，管理者正例可用。

变异验证已执行：同时旁路四个管理员复核、恢复 `nil -> true`，并旁路三个列表、教研状态和邀请摘要的读取授权，16 项测试中 15 项越权回归失败；精确恢复实现后 16 项全部通过。

```sh
cd backend
mix test test/cgc_2046_web/mcp_authorization_test.exs
mix precommit
```

旧测试已按新授权契约调整，保留默认 assignee 自审、显式 reviewer、草稿版本绑定、全链发布、撤销成员资格、列表排序及管理者发现面验证。

首轮完整 `mix precommit` 退出码为 0：3619 项通过、1 项跳过；包含 warnings-as-errors 编译、依赖锁清理检查、格式化与完整测试。`git diff --check` 通过。改动未涉及依赖锁、迁移或 CI 配置。

## PR 提交验收

- 专用分支从 `origin/develop` 的 `8d24cea2` 创建，该基线与上一轮完整验证之间没有后端文件差异；在新分支隔离库上重跑 MCP 授权回归，16 项通过。
- 独立启动 Phoenix/Bandit，经实际 TCP HTTP 请求完成 MCP initialize/tools-call/confirm 和 GraphQL sign-in/listCourses 验收：管理员降级拒绝、恢复权限可重试、普通成员不见草稿、tutor 可见课程草稿、未指派成员不能审核均通过。使用 test 配置及 SQL Sandbox，结束时回滚全部 fixture，服务随命令退出。
- 前端 `pnpm test`：168 个文件、1778 项通过；`pnpm typecheck`、`pnpm lint` 通过（lint 有 6 条既有 warning）；显式设置本地 `BACKEND_URL` 后 `pnpm build` 通过。

## PR review 补充：审核人的教研状态读取

通用 Course actor 读无法覆盖课程级的 reviewer 授权：显式指定的无 staff 成员虽能收到审核任务并执行审核，却会在 `get_prep_status` 被拒绝。补充路径复用 `Prep.reviewer?/2`，仅对目标工作台当前 active run 的 draft 课程返回状态投影；显式 reviewer 与默认 assignee 的任务授权均有效，普通成员及其他课程仍拒绝，课程列表和 GraphQL 读权保持由领域 policy 判定。

审核例外直接携带已校验的 run，不再次调用 `ensure_active_run/2`。确定性交错测试在课程回读后取消 R1：丢弃已授权 run 的中间实现会创建并返回未获授权的 R2（已实测红），最终实现仍返回 R1 的已授权快照，数据库没有新 active run、课程关联也未改写。

新增 `backend/test/cgc_2046_web/mcp_prep_status_authorization_test.exs` 的 8 项真实 MCP HTTP 回归，验证状态投影字段、待办与读取衔接、列表不扩权、同会话改派撤权、移出成员、跨课程/租户、无 run 不懒建、cancelled 不可见，以及上述交错。已有 16 项授权回归继续通过。

变异验证已执行：旁路 reviewer 条件导致 3 项回归失败；去掉 draft 限定导致 1 项失败；丢弃已授权 run、重新取当前 run 导致交错测试失败。精确恢复实现后，两组 HTTP 测试共 24 项通过。独立 Phoenix/Bandit 服务的真实 TCP 验收也确认了 reviewer 可读、列表仍收窄及撤权即时生效。

补充修复后的完整 `mix precommit`：3627 项通过、1 项跳过，退出码 0。独立静态复核确认审核例外不二次查询或懒建 run，且成员、课程、租户和 draft 边界完整。
