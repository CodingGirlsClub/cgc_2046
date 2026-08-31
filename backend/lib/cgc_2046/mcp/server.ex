defmodule Cgc2046.Mcp.Server do
  @moduledoc """
  全平台唯一 MCP server（D6 / #42）：anubis_mcp streamable HTTP。

  工具集(59,role-agent-journeys-v2 S8 学习 v2 后):
  - 读:get_workspace_context / list_members / list_join_requests / get_workflow / get_step_output
  - 公开浏览(membership: :public,KTD2/KTD3;任何持连接 token 的登录用户,匿名白名单口径):
    list_public_offerings / get_public_offering
  - 角色工作台基座(S1,R2/R3/R8):list_my_workspaces(workspace_id: :optional,
    actor 锚定跨工作台读) / get_role_playbook(optional+deferred 双键,工具层四分支
    授权) / list_my_tasks(member-only,PendingApprovals 聚合)
  - 平台治理(S2,R12-R16;membership: :platform_admin 新门控族,is_platform_admin
    全局标记专属,无工作台作用域):
    读 admin_list_users / admin_list_workspaces / admin_list_workspace_applications /
    admin_list_audit_logs / admin_list_reconciliation_findings(各封顶 50;审计面
    三源元数据投影结构性不读 params/metadata 列,对账面当前孤儿清单)
    + 确认流写 admin_approve_workspace_application / admin_reject_workspace_application /
    admin_create_workspace / admin_reassign_workspace_owner / admin_promote_user /
    admin_demote_user(委托 accounts 域既有 action + LogAdminAction 留痕)
  - 工作台管理面(S3,R17-R19 + R21 前半;member-only 门 + 工具层
    Role.manage_role?/1 判定,Owner/Admin 专属;写走确认流两段式快速失败):
    Course 生命周期 create_course(唯一直接写——零输入草稿可逆低风险,title 缺省
    生成「未命名课程 <hex8>」+ provisional_title 标记,launch 命名门拦截) /
    update_course(pricing_enabled true→false 摘要含批量免缴影响) / launch_course /
    close_course / cancel_course(终态不可逆提示);报名管理 list_course_enrollments
    (读,报名人摘要投影) / confirm_enrollment / reject_enrollment / waive_payment
    (委托 Admission 既有 action,免缴同事务作废 pending 单 + 补发 completed);
    订单 list_workspace_orders(读) / refund_order / retry_refund(委托 Payments
    既有 CAS action);加入策略 update_join_policy
  - 课程教研流程(S5,R22-R28;member-only 门 + 工具层角色判定,域逻辑宿主
    Curriculum.Prep;prep run = 协议而非 DAG,prep_state 存 facts):
    get_prep_status(读,任何成员) / assign_prep_tutor(Owner/Admin 直接写) /
    claim_prep_authoring(tutor∪Owner/Admin,run version 乐观锁 CAS 认领) /
    update_prep_policy(Owner/Admin 确认流,提交质检后冻结) /
    submit_prep_for_check(assignee∪Owner/Admin,同步跑 PrepGate 结构门禁) /
    submit_prep_quality_report(达标按策略进 review 或直接发布) /
    override_prep_gate(reviewer-per-policy∪Owner/Admin 确认流,理由落审计) /
    approve_prep(reviewer-per-policy∪Owner/Admin 确认流,发布=生成不可变
    CourseRevision+课程 open) /
    request_changes_prep(review → authoring 直接写)
  - 课程版本读(role-agent-journeys-v2 S6,R29/R38):get_course_revision(deferred;
    成员任意版本/confirmed 学员仅最新/其他 forbidden;从未发布明确错误不回退
    草稿;内容快照原样投影)
  - 学员旅程(role-agent-journeys-v2 S7,R30-R35;两读面 optional+deferred 双键
    跨台锚定,三面 deferred):
    discover_offerings(公开∪成员可访问并集,{kind,id} 去重,封顶 100+total_count
    截断前小计;invite_only 台非成员 workspace 块落 nil) /
    get_enrollment_summary(报名前摘要;would_create_status 镜像域 prepare_policy,
    驱动因子=offering enrollment_policy;capacity_info 仅成员;goals 取 published
    revision 无则回退草稿) / create_enrollment(唯一直接写——客户端确认即契约;
    reason 进 Wrapper 前摘除;撞 enrollment_duplicate_active 幂等重放既有活跃
    报名;payment_pending 附 checkout_url 外部结算页) /
    get_my_enrollments(全状态跨台,封顶 100,课程面板列表源) /
    get_order_status(本人最新订单白名单摘要,非终态优先;渠道凭据永不出面)
  - 写:save_step_output
  - 管理(确认流 two-tool,D-D3):create_invitation / approve_join_request / assign_roles
  - 内置:confirm_operation / cancel_operation

  （get_agent_instruction：D10 任务指令模式，拉取 Agent 定义 prompt/skills/授权；
  plan 020 只留接口语义，不实现——roadmap）

  鉴权：`Cgc2046Web.Plugs.McpAuthPlug` 验 Bearer → `frame.assigns[:current_user]`；
  每工具调用经 `Cgc2046.Mcp.Wrapper` 做 workspace_id 必填校验（D12）+ membership
  鉴权 + ToolCallLog 审计（D9）。

  elicitation 不启用（目标客户端均不支持，见 research §5b；D8 用 two-tool 模式）。
  """
  use Anubis.Server,
    name: "cgc-2046",
    version: "0.1.0",
    capabilities: [:tools]

  component(Cgc2046.Mcp.Tools.GetWorkspaceContext)
  component(Cgc2046.Mcp.Tools.ListMembers)
  component(Cgc2046.Mcp.Tools.GetWorkflow)
  component(Cgc2046.Mcp.Tools.GetStepOutput)
  component(Cgc2046.Mcp.Tools.SaveStepOutput)
  component(Cgc2046.Mcp.Tools.CreateInvitation)

  # 成员管理三工具(#240):工具面 12 → 15(读列表 + 确认流批加入/改角色,Owner/Admin 专属)
  component(Cgc2046.Mcp.Tools.ListJoinRequests)
  component(Cgc2046.Mcp.Tools.ApproveJoinRequest)
  component(Cgc2046.Mcp.Tools.AssignRoles)
  component(Cgc2046.Mcp.Tools.ConfirmOperation)
  component(Cgc2046.Mcp.Tools.CancelOperation)
  # 课程 issue 学习闭环(切片 H U3,#180):工具面 8 → 12
  # (S8:get_learning_records/save_learning_records 已随 LearningRecord 退役——
  # 学习 v2 三件见文件尾注册区)
  component(Cgc2046.Mcp.Tools.GetCourseContent)
  component(Cgc2046.Mcp.Tools.SaveCourseContent)
  # 公开浏览(U2,#293):工具面 15 → 17(membership: :public 新豁免家族,KTD3)
  component(Cgc2046.Mcp.Tools.ListPublicOfferings)
  component(Cgc2046.Mcp.Tools.GetPublicOffering)
  # 角色工作台基座(role-agent-journeys-v2 S1,R2/R3/R8):工具面 17 → 20
  component(Cgc2046.Mcp.Tools.ListMyWorkspaces)
  component(Cgc2046.Mcp.Tools.GetRolePlaybook)
  component(Cgc2046.Mcp.Tools.ListMyTasks)
  # 平台治理族(role-agent-journeys-v2 S2,R12-R16):工具面 20 → 30
  # (membership: :platform_admin 新门控族,is_platform_admin 全局标记专属,无工作台作用域;
  # 读四件封顶 50 且审计面结构性不读 params/metadata 列,写六件走确认流委托 accounts 域 action)
  component(Cgc2046.Mcp.Tools.AdminListUsers)
  component(Cgc2046.Mcp.Tools.AdminListWorkspaces)
  component(Cgc2046.Mcp.Tools.AdminListWorkspaceApplications)
  component(Cgc2046.Mcp.Tools.AdminListAuditLogs)
  component(Cgc2046.Mcp.Tools.AdminListReconciliationFindings)
  component(Cgc2046.Mcp.Tools.AdminApproveWorkspaceApplication)
  component(Cgc2046.Mcp.Tools.AdminRejectWorkspaceApplication)
  component(Cgc2046.Mcp.Tools.AdminCreateWorkspace)
  component(Cgc2046.Mcp.Tools.AdminReassignWorkspaceOwner)
  component(Cgc2046.Mcp.Tools.AdminPromoteUser)
  component(Cgc2046.Mcp.Tools.AdminDemoteUser)
  # Workspace Owner/Admin 管理面（role-agent-journeys-v2 S3，R17-R19 + R21 前半）：
  # 工具面 30 → 43（member-only 门 + 工具层 Role.manage_role?/1 判定；写走确认流
  # 两段式快速失败，create_course 为唯一直接写——零输入草稿可逆低风险）
  component(Cgc2046.Mcp.Tools.CreateCourse)
  component(Cgc2046.Mcp.Tools.UpdateCourse)
  component(Cgc2046.Mcp.Tools.LaunchCourse)
  component(Cgc2046.Mcp.Tools.CloseCourse)
  component(Cgc2046.Mcp.Tools.CancelCourse)
  component(Cgc2046.Mcp.Tools.ListCourseEnrollments)
  component(Cgc2046.Mcp.Tools.ConfirmEnrollment)
  component(Cgc2046.Mcp.Tools.RejectEnrollment)
  component(Cgc2046.Mcp.Tools.WaivePayment)
  component(Cgc2046.Mcp.Tools.ListWorkspaceOrders)
  component(Cgc2046.Mcp.Tools.RefundOrder)
  component(Cgc2046.Mcp.Tools.RetryRefund)
  component(Cgc2046.Mcp.Tools.UpdateJoinPolicy)
  # 课程教研流程九工具（role-agent-journeys-v2 S5，R22-R28）：工具面 43 → 52
  # （member-only 门 + 工具层角色判定；策略调整/门禁覆盖/审核发布三件走确认流，
  # 域逻辑宿主 Curriculum.Prep）
  component(Cgc2046.Mcp.Tools.GetPrepStatus)
  component(Cgc2046.Mcp.Tools.AssignPrepTutor)
  component(Cgc2046.Mcp.Tools.ClaimPrepAuthoring)
  component(Cgc2046.Mcp.Tools.UpdatePrepPolicy)
  component(Cgc2046.Mcp.Tools.SubmitPrepForCheck)
  component(Cgc2046.Mcp.Tools.SubmitPrepQualityReport)
  component(Cgc2046.Mcp.Tools.OverridePrepGate)
  component(Cgc2046.Mcp.Tools.ApprovePrep)
  component(Cgc2046.Mcp.Tools.RequestChangesPrep)
  # 课程版本读（role-agent-journeys-v2 S6，R29/R38）：工具面 52 → 53
  # （deferred 族 +1：发布即冻结的不可变内容快照，授权三分支在工具层）
  component(Cgc2046.Mcp.Tools.GetCourseRevision)
  # 学员旅程五工具（role-agent-journeys-v2 S7，R30-R35）：工具面 53 → 58
  # （发现/报名/支付；create_enrollment 为唯一直接写——客户端确认契约，
  # 幂等重放；订单摘要渠道凭据红线）
  component(Cgc2046.Mcp.Tools.DiscoverOfferings)
  component(Cgc2046.Mcp.Tools.GetEnrollmentSummary)
  component(Cgc2046.Mcp.Tools.CreateEnrollment)
  component(Cgc2046.Mcp.Tools.GetMyEnrollments)
  component(Cgc2046.Mcp.Tools.GetOrderStatus)
  # 学习循环 v2（role-agent-journeys-v2 S8，R36-R44；ADR-0011）：工具面 58 → 59
  # （-2 学习记录读写随 LearningRecord 退役，+3 学习 v2：run 幂等启动/
  # 不可变评价提交/状态投影——掌握由账本纯投影，agent 永不直写）
  component(Cgc2046.Mcp.Tools.StartLearningRun)
  component(Cgc2046.Mcp.Tools.SubmitLearningAttempt)
  component(Cgc2046.Mcp.Tools.GetLearningState)
  component(Cgc2046.Mcp.Tools.GetCourseLearningAnalytics)
end
