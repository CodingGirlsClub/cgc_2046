import type { FetchPolicy, TypedDocumentNode } from "@apollo/client";
import { client } from "./apollo-client";
import type { MutationError } from "./graphql/shared";
import type {
  AdminActionLog,
  AdminApplicationStatus,
  AdminListArgs,
  AdminPendingOperation,
  AdminReconciliationFinding,
  AdminSignalLog,
  AdminToolCallLog,
  AdminUser,
  AdminUserPayload,
  AdminWorkspace,
  AdminWorkspaceApplication,
  AdminInitiative,
  AdminInitiativePayload,
  AdminInitiativeRule,
  AdminEvent,
  AdminEventDetail,
  AdminEventPayload,
  AdminEventUpdateInput,
  AdminCourse,
  AdminCourseDetail,
  AdminCoursePayload,
  AdminCourseUpdateInput,
  ApproveApplicationResultData,
  RejectApplicationResultData,
  FlashbackAdminStats,
  FlashbackRedemption,
  FlashbackOutreachPreview,
  FlashbackOutreachBatch,
  FlashbackOutreachRosterEntry,
  FlashbackAdminArchive,
} from "./graphql/admin";
import {
  ADMIN_CANCEL_EVENT, ADMIN_CLOSE_EVENT, ADMIN_LAUNCH_EVENT, ADMIN_UPDATE_EVENT,
  ADMIN_CANCEL_COURSE, ADMIN_CLOSE_COURSE, ADMIN_LAUNCH_COURSE, ADMIN_UPDATE_COURSE,
  APPROVE_WORKSPACE_APPLICATION,
  CREATE_WORKSPACE_APPLICATION,
  DEMOTE_USER,
  LIST_ADMIN_ACTION_LOGS,
  LIST_PENDING_OPERATIONS,
  LIST_SIGNAL_LOGS,
  LIST_TOOL_CALL_LOGS,
  LIST_USERS,
  LIST_INITIATIVES,
  GET_INITIATIVE,
  GET_ADMIN_EVENT,
  LIST_ADMIN_EVENTS,
  GET_ADMIN_COURSE,
  LIST_ADMIN_COURSES,
  CREATE_INITIATIVE, UPDATE_INITIATIVE, OPEN_INITIATIVE, CLOSE_INITIATIVE, CANCEL_INITIATIVE,
  LIST_WORKSPACE_APPLICATIONS,
  UPSERT_INITIATIVE_RULE,
  LIST_WORKSPACES,
  MY_WORKSPACE_APPLICATIONS,
  PROMOTE_USER,
  RECONCILIATION_FINDINGS,
  REJECT_WORKSPACE_APPLICATION,
  FLASHBACK_ADMIN_STATS,
  FLASHBACK_ADMIN_REDEMPTIONS,
  FLASHBACK_ADMIN_WISH_INBOX,
  FLASHBACK_ADMIN_WISH_REPORTS,
  FLASHBACK_ADMIN_DISMISS_REPORT,
  FLASHBACK_ADMIN_APPROVE_REPORT,
  FLASHBACK_ADMIN_SET_WISH_HIDDEN,
  FLASHBACK_ADMIN_LISTED_WISHES,
  FLASHBACK_ADMIN_WISH_ECHOES,
  FLASHBACK_ADMIN_CREATE_WISH_ECHO,
  FLASHBACK_ADMIN_UPDATE_WISH_ECHO_DRAFT,
  FLASHBACK_ADMIN_PUBLISH_WISH_ECHO,
  FLASHBACK_ADMIN_CORRECT_WISH_ECHO,
  FLASHBACK_ADMIN_REVOKE_WISH_ECHO,
  type FlashbackAdminListedWishEntry,
  type FlashbackAdminWishEcho,
  type FlashbackAdminWishEchoesResult,
  type FlashbackAdminWishInboxEntry,
  type FlashbackAdminReportEntry,
  FLASHBACK_ADMIN_UPDATE_REDEMPTION,
  FLASHBACK_OUTREACH_PREVIEW,
  FLASHBACK_OUTREACH_BATCHES,
  FLASHBACK_OUTREACH_ROSTER,
  FLASHBACK_ADMIN_ARCHIVES,
  FLASHBACK_ADMIN_SEND_OUTREACH,
  FLASHBACK_ADMIN_RESEND_OUTREACH,
  type CreateWorkspaceApplicationInput,
  type CreateWorkspaceApplicationResultData,
} from "./graphql/admin";
import {
  CREATE_WORKSPACE,
  REASSIGN_WORKSPACE_OWNER,
  type CreateWorkspaceInput,
  type CreateWorkspaceResultData,
  type ReassignWorkspaceOwnerInput,
  type ReassignWorkspaceOwnerResultData,
} from "./graphql/workspace";

/**
 * 平台管理员数据源（Phase 7 后半，对齐后端 Phase 5 GraphQL 契约 ca89719）。
 *
 * 唯一真实路径 = GraphQL；列表分页用 offset（after 为上一页已返回条数，字符串）。
 * 审计列表（ToolCallLog/PendingOperation/SignalLog）按 workspaceId 过滤
 * （D5：ToolCallLog/PendingOperation 走 params JSONB 表达式，SignalLog 走真实列）。
 */

export interface AdminPage<T> {
  items: T[];
  /** 本页已返回总条数（下一页 offset = 当前 offset + items.length） */
  total: number;
}

const DEFAULT_PAGE_SIZE = 50;

function listVars(
  extra: Record<string, string | number | null | undefined>,
  opts?: AdminListArgs,
) {
  const variables: Record<string, string | number | null | undefined> = {
    ...extra,
    first: opts?.first ?? DEFAULT_PAGE_SIZE,
  };
  if (opts?.after != null) {
    variables.after = opts.after;
  }
  return variables;
}

/**
 * admin 列表查询构造器：listVars + 取 field，一处模板（leverage）。
 * field 与返回类型联动（field 写错编译报错）；variables 经 listVars 统一。
 * fetchMyApplications / mutation 不用此构造器：形状不同。
 */
async function adminList<D, F extends keyof D>(
  query: TypedDocumentNode<D>,
  extraVars: Record<string, string | number | null | undefined>,
  field: F,
  opts?: AdminListArgs,
  fetchPolicy?: FetchPolicy,
): Promise<D[F] extends (infer T)[] | undefined ? T[] : never> {
  const { data } = await client.query({
    query,
    variables: listVars(extraVars, opts),
    ...(fetchPolicy ? { fetchPolicy } : {}),
  });
  return (data?.[field] ?? []) as D[F] extends (infer T)[] | undefined
    ? T[]
    : never;
}

/** 平台管理员：用户列表（R8；search 匹配 email/display_name） */
export async function fetchUsers(
  search?: string,
  opts?: AdminListArgs,
): Promise<AdminUser[]> {
  return adminList(LIST_USERS, { search: search || null }, "listUsers", opts);
}

export async function fetchInitiatives(status?: string, search?: string): Promise<AdminInitiative[]> {
	return adminList(LIST_INITIATIVES, { status: status || null, search: search || null }, "listInitiatives", { first: 200 });
}
export async function fetchInitiative(id: string): Promise<AdminInitiative | null> {
  const { data } = await client.query({ query: GET_INITIATIVE, variables: { id }, fetchPolicy: "network-only" });
  return data?.getInitiative ?? null;
}
export async function upsertInitiativeRule(id: string, key: string, valueJson: string, locked: boolean): Promise<{ result: AdminInitiativeRule | null; errors: MutationError[] }> {
  const { data } = await client.mutate<{ upsertInitiativeRule: { result: AdminInitiativeRule | null; errors: MutationError[] } }>({ mutation: UPSERT_INITIATIVE_RULE, variables: { initiativeId: id, key, valueJson, locked } });
  return data?.upsertInitiativeRule ?? { result: null, errors: [] };
}

export async function createInitiative(input: Record<string, unknown>): Promise<AdminInitiativePayload> {
  const { data } = await client.mutate<{ createInitiative: AdminInitiativePayload }>({ mutation: CREATE_INITIATIVE, variables: { input } });
  return data?.createInitiative ?? { result: null, errors: [] };
}
export async function updateInitiative(id: string, input: Record<string, unknown>): Promise<AdminInitiativePayload> {
  const { data } = await client.mutate<{ updateInitiative: AdminInitiativePayload }>({ mutation: UPDATE_INITIATIVE, variables: { id, input } });
  return data?.updateInitiative ?? { result: null, errors: [] };
}
export async function openInitiative(id: string): Promise<AdminInitiativePayload> {
  const { data } = await client.mutate<{ openInitiative: AdminInitiativePayload }>({ mutation: OPEN_INITIATIVE, variables: { id } });
  return data?.openInitiative ?? { result: null, errors: [] };
}
export async function closeInitiative(id: string): Promise<AdminInitiativePayload> {
  const { data } = await client.mutate<{ closeInitiative: AdminInitiativePayload }>({ mutation: CLOSE_INITIATIVE, variables: { id } });
  return data?.closeInitiative ?? { result: null, errors: [] };
}
/** 中止倡导活动（#628）：级联取消挂载中仍开放的场次 + 全额退款，终态不可逆。 */
export async function cancelInitiative(id: string): Promise<AdminInitiativePayload> {
  const { data } = await client.mutate<{ cancelInitiative: AdminInitiativePayload }>({ mutation: CANCEL_INITIATIVE, variables: { id } });
  return data?.cancelInitiative ?? { result: null, errors: [] };
}

/**
 * Event 治理列表过滤条件（空值 = 不过滤）。
 * status 只接受 `OFFERING_STATUS_VALUES`（后端 `status_values/0`）；workspaceId 为真实列过滤。
 */
export interface AdminEventFilters {
	status?: string;
	search?: string;
	workspaceId?: string;
}

/**
 * 平台管理员：跨租户 Event 列表（U2/U3 R1-R2；含 draft 与终态行）。
 * 列表不带报名计数——权威计数只在 `fetchAdminEvent` 现取（KTD4）。
 */
export async function fetchAdminEvents(
	filters?: AdminEventFilters,
	opts?: AdminListArgs,
): Promise<AdminEvent[]> {
	return adminList(
		LIST_ADMIN_EVENTS,
		{
			status: filters?.status ?? null,
			search: filters?.search ?? null,
			workspaceId: filters?.workspaceId ?? null,
		},
		"listAdminEvents",
		opts,
		// P3 同款：治理写后 refreshAfterWrite → loadList 必须现取，
		// cache-first 会命中同 variables 的旧快照（#754 FAIL-1）
		"network-only",
	);
}

/**
 * 平台管理员：Event 治理详情（R3）。
 *
 * network-only + id 不存在返回 null（不是错误）：确认弹窗与展开详情共用这一条
 * 现取路径，是 KTD4「计数单一来源」的取数口。
 */
export async function fetchAdminEvent(
	id: string,
): Promise<AdminEventDetail | null> {
	const { data } = await client.query({
		query: GET_ADMIN_EVENT,
		variables: { id },
		fetchPolicy: "network-only",
	});
	return data?.getAdminEvent ?? null;
}

/** 治理写结果兜底：mutation resolve 出空形状时按「未成功、错误未知」处理，不假装成功。 */
function eventPayloadEnvelope(
	payload: AdminEventPayload | null | undefined,
): AdminEventPayload {
	return payload ?? { result: null, errors: [] };
}

/** 平台管理员：发布活动（draft → open；同工作台 launch action 语义） */
export async function adminLaunchEvent(id: string): Promise<AdminEventPayload> {
	const { data } = await client.mutate<{ adminLaunchEvent: AdminEventPayload }>({
		mutation: ADMIN_LAUNCH_EVENT,
		variables: { id },
	});
	return eventPayloadEnvelope(data?.adminLaunchEvent);
}

/** 平台管理员：结束活动（open → closed；发 event.ended 信号） */
export async function adminCloseEvent(id: string): Promise<AdminEventPayload> {
	const { data } = await client.mutate<{ adminCloseEvent: AdminEventPayload }>({
		mutation: ADMIN_CLOSE_EVENT,
		variables: { id },
	});
	return eventPayloadEnvelope(data?.adminCloseEvent);
}

/**
 * 平台管理员：取消活动（open → cancelled）。
 * 受影响报名按既有取消链路**异步**处理（已付批量退款、待付作废释放名额，无同步回执）。
 */
export async function adminCancelEvent(id: string): Promise<AdminEventPayload> {
	const { data } = await client.mutate<{ adminCancelEvent: AdminEventPayload }>({
		mutation: ADMIN_CANCEL_EVENT,
		variables: { id },
	});
	return eventPayloadEnvelope(data?.adminCancelEvent);
}

/**
 * 平台管理员：编辑 Event 元数据（R5 标准元数据全集）。
 *
 * input 只落**本次真变更**的键（同值重发会把缴费槽位重新写成"场主的决定"，
 * 且 datetime-local 的分钟精度会截断库里的秒——见 workbench 表单脏检查纪律）。
 * slug 不在治理面输入：已发布实体的 slug 编辑由后端 `event_slug_locked` 拒绝（R7）。
 */
export async function adminUpdateEvent(
	id: string,
	input: AdminEventUpdateInput,
): Promise<AdminEventPayload> {
	const { data } = await client.mutate<{ adminUpdateEvent: AdminEventPayload }>({
		mutation: ADMIN_UPDATE_EVENT,
		variables: { id, input },
	});
	return eventPayloadEnvelope(data?.adminUpdateEvent);
}

/**
 * Course 治理列表过滤条件（空值 = 不过滤）。
 * status 只接受 `OFFERING_STATUS_VALUES`（后端 `status_values/0`）；workspaceId 为真实列过滤。
 */
export interface AdminCourseFilters {
	status?: string;
	search?: string;
	workspaceId?: string;
}

/**
 * 平台管理员：跨租户 Course 列表（U2/U4 R1-R2；含 draft 与终态行）。
 * 列表不带报名计数——权威计数只在 `fetchAdminCourse` 现取（KTD4）。
 */
export async function fetchAdminCourses(
	filters?: AdminCourseFilters,
	opts?: AdminListArgs,
): Promise<AdminCourse[]> {
	return adminList(
		LIST_ADMIN_COURSES,
		{
			status: filters?.status ?? null,
			search: filters?.search ?? null,
			workspaceId: filters?.workspaceId ?? null,
		},
		"listAdminCourses",
		opts,
		// P3 同款：治理写后 refreshAfterWrite → loadList 必须现取，
		// cache-first 会命中同 variables 的旧快照（#754 FAIL-1）
		"network-only",
	);
}

/**
 * 平台管理员：Course 治理详情（R3）。
 *
 * network-only + id 不存在返回 null（不是错误）：确认弹窗与展开详情共用这一条
 * 现取路径，是 KTD4「计数单一来源」的取数口。
 */
export async function fetchAdminCourse(
	id: string,
): Promise<AdminCourseDetail | null> {
	const { data } = await client.query({
		query: GET_ADMIN_COURSE,
		variables: { id },
		fetchPolicy: "network-only",
	});
	return data?.getAdminCourse ?? null;
}

/** 治理写结果兜底：mutation resolve 出空形状时按「未成功、错误未知」处理，不假装成功。 */
function coursePayloadEnvelope(
	payload: AdminCoursePayload | null | undefined,
): AdminCoursePayload {
	return payload ?? { result: null, errors: [] };
}

/** 平台管理员：发布课程（draft → open；同工作台 launch action 语义） */
export async function adminLaunchCourse(id: string): Promise<AdminCoursePayload> {
	const { data } = await client.mutate<{ adminLaunchCourse: AdminCoursePayload }>({
		mutation: ADMIN_LAUNCH_COURSE,
		variables: { id },
	});
	return coursePayloadEnvelope(data?.adminLaunchCourse);
}

/** 平台管理员：结束课程（open → closed；发 course.ended 信号） */
export async function adminCloseCourse(id: string): Promise<AdminCoursePayload> {
	const { data } = await client.mutate<{ adminCloseCourse: AdminCoursePayload }>({
		mutation: ADMIN_CLOSE_COURSE,
		variables: { id },
	});
	return coursePayloadEnvelope(data?.adminCloseCourse);
}

/**
 * 平台管理员：取消课程（open → cancelled）。
 * 受影响报名按既有取消链路**异步**处理（已付批量退款、待付作废释放名额，无同步回执）。
 */
export async function adminCancelCourse(id: string): Promise<AdminCoursePayload> {
	const { data } = await client.mutate<{ adminCancelCourse: AdminCoursePayload }>({
		mutation: ADMIN_CANCEL_COURSE,
		variables: { id },
	});
	return coursePayloadEnvelope(data?.adminCancelCourse);
}

/**
 * 平台管理员：编辑 Course 元数据（R5 标准元数据全集里治理面的可编辑子集）。
 *
 * input 只落**本次真变更**的键（同值重发会把定价槽位重新写成「课程主的决定」，
 * 且 datetime-local 的分钟精度会截断库里的秒——见 workbench 表单脏检查纪律）。
 * slug 不在治理面输入：已发布实体的 slug 编辑由后端 `course_slug_locked` 拒绝（R7）。
 */
export async function adminUpdateCourse(
	id: string,
	input: AdminCourseUpdateInput,
): Promise<AdminCoursePayload> {
	const { data } = await client.mutate<{ adminUpdateCourse: AdminCoursePayload }>({
		mutation: ADMIN_UPDATE_COURSE,
		variables: { id, input },
	});
	return coursePayloadEnvelope(data?.adminUpdateCourse);
}

/** 平台管理员：工作台列表（R13；search 匹配 name/slug） */
export async function fetchWorkspaces(
  search?: string,
  opts?: AdminListArgs,
): Promise<AdminWorkspace[]> {
  return adminList(
    LIST_WORKSPACES,
    { search: search || null },
    "listWorkspaces",
    opts,
  );
}

/** 平台管理员：工作台创建申请列表（R7；status 过滤） */
export async function fetchApplications(
  status?: AdminApplicationStatus,
  opts?: AdminListArgs,
): Promise<AdminWorkspaceApplication[]> {
  return adminList(
    LIST_WORKSPACE_APPLICATIONS,
    { status: status ?? null },
    "listWorkspaceApplications",
    opts,
    // P3：审批列表高频变动，network-only 绕过 cache-first 命中旧缓存
    "network-only",
  );
}

/** 当前用户（申请人）自己的工作台创建申请（R7a） */
export async function fetchMyApplications(): Promise<
  AdminWorkspaceApplication[]
> {
  const { data } = await client.query({
    query: MY_WORKSPACE_APPLICATIONS,
    // #205：提交后 loadMyApps 必须绕过 cache-first 命中旧缓存（P3 同款）
    fetchPolicy: "network-only",
  });
  return data?.myWorkspaceApplications ?? [];
}

/** 提交创建工作台申请（R6 /apply 表单；applicantId 由调用方从 useAuthed 传入）。
 *  后端 policy 强制 applicant_id == actor.id 防伪造。 */
export async function createApplication(
  input: CreateWorkspaceApplicationInput,
): Promise<CreateWorkspaceApplicationResultData> {
  const { data } = await client.mutate({
    mutation: CREATE_WORKSPACE_APPLICATION,
    variables: { input },
  });
  return (
    data?.createWorkspaceApplication ?? {
      result: null,
      errors: [],
    }
  );
}

/**
 * #117 审计筛选条件（audit 页 toolbar → fetch 参数；空值 = 不过滤）。
 * status 语义按 tab：ToolCallLog → resultStatus / PendingOperation → status（含派生
 * expired）/ WorkflowRun → status；signalType 仅 SignalLog tab 用。时间范围为 ISO8601
 * 串；WorkflowRun tab 由 fetchWorkflowRuns 映射到 startedAt（自动 filter 无 insertedAt）。
 */
export interface AuditFilters {
  status?: string;
  signalType?: string;
  insertedAfter?: string;
  insertedBefore?: string;
}

/** 平台管理员：MCP 工具调用审计（R10；workspaceId 按 params JSONB 过滤，D5） */
export async function fetchToolCallLogs(
  workspaceId?: string,
  filters?: AuditFilters,
  opts?: AdminListArgs,
): Promise<AdminToolCallLog[]> {
  return adminList(
    LIST_TOOL_CALL_LOGS,
    {
      workspaceId: workspaceId ?? null,
      status: filters?.status ?? null,
      insertedAfter: filters?.insertedAfter ?? null,
      insertedBefore: filters?.insertedBefore ?? null,
    },
    "listToolCallLogs",
    opts,
  );
}

/** 平台管理员：MCP 待确认操作审计（R10；workspaceId 按 params JSONB 过滤，D5） */
export async function fetchPendingOperations(
  workspaceId?: string,
  filters?: AuditFilters,
  opts?: AdminListArgs,
): Promise<AdminPendingOperation[]> {
  return adminList(
    LIST_PENDING_OPERATIONS,
    {
      workspaceId: workspaceId ?? null,
      status: filters?.status ?? null,
      insertedAfter: filters?.insertedAfter ?? null,
      insertedBefore: filters?.insertedBefore ?? null,
    },
    "listPendingOperations",
    opts,
  );
}

/** 平台管理员：workflow 信号日志审计（R10；workspaceId 按真实列过滤） */
export async function fetchSignalLogs(
  workspaceId?: string,
  filters?: AuditFilters,
  opts?: AdminListArgs,
): Promise<AdminSignalLog[]> {
  return adminList(
    LIST_SIGNAL_LOGS,
    {
      workspaceId: workspaceId ?? null,
      signalType: filters?.signalType ?? null,
      insertedAfter: filters?.insertedAfter ?? null,
      insertedBefore: filters?.insertedBefore ?? null,
    },
    "listSignalLogs",
    opts,
  );
}

/** 平台管理员：治理操作审计（R10；action 枚举过滤，无 workspace 维度） */
export async function fetchAdminActionLogs(
  action?: string,
  filters?: AuditFilters,
  opts?: AdminListArgs,
): Promise<AdminActionLog[]> {
  return adminList(
    LIST_ADMIN_ACTION_LOGS,
    {
      action: action ?? null,
      insertedAfter: filters?.insertedAfter ?? null,
      insertedBefore: filters?.insertedBefore ?? null,
    },
    "listAdminActionLogs",
    opts,
  );
}

/* E-10 #125 对账扫描过滤条件（空值 = 不过滤；rule/entityType 为枚举串） */
export interface ReconciliationFilters {
  rule?: string;
  entityType?: string;
  workspaceId?: string;
  /** KTD5：成对下发给 entityType（单独下发后端 invalid_input 拒绝） */
  entityId?: string;
}

/** 平台管理员：对账扫描发现（E-10 #125；rule/entityType/entityId/workspace 过滤） */
export async function fetchReconciliationFindings(
  filters?: ReconciliationFilters,
  opts?: AdminListArgs,
): Promise<AdminReconciliationFinding[]> {
  return adminList(
    RECONCILIATION_FINDINGS,
    {
      rule: filters?.rule ?? null,
      entityType: filters?.entityType ?? null,
      entityId: filters?.entityId ?? null,
      workspaceId: filters?.workspaceId ?? null,
    },
    "reconciliationFindings",
    opts,
  );
}

/** 审批通过工作台创建申请（R7；platform_admin，自动创建 workspace + applicant 为 Owner）。
 *  列表刷新由页面 load(status) 承担——fetchApplications 已 network-only（P3 根治）。 */
export async function approveApplication(
  id: string,
): Promise<ApproveApplicationResultData> {
  const { data } = await client.mutate({
    mutation: APPROVE_WORKSPACE_APPLICATION,
    variables: { id },
  });
  return (
    data?.approveWorkspaceApplication ?? {
      result: null,
      errors: [],
    }
  );
}

/** 拒绝工作台创建申请（R7；可选拒绝原因）。
 *  列表刷新由页面 load(status) 承担——fetchApplications 已 network-only（P3 根治）。 */
export async function rejectApplication(
  id: string,
  rejectionReason?: string | null,
): Promise<RejectApplicationResultData> {
  const { data } = await client.mutate({
    mutation: REJECT_WORKSPACE_APPLICATION,
    variables: { id, input: { rejectionReason: rejectionReason ?? null } },
  });
  return (
    data?.rejectWorkspaceApplication ?? {
      result: null,
      errors: [],
    }
  );
}

/** 提升用户为 platform_admin（R9） */
export async function promoteUser(
  id: string,
): Promise<AdminUserPayload | null> {
  const { data } = await client.mutate({
    mutation: PROMOTE_USER,
    variables: { id },
  });
  return data?.promoteUser ?? null;
}

/** 降级用户 platform_admin（R9；≥1 admin 约束 + 自降级检查在后端） */
export async function demoteUser(id: string): Promise<AdminUserPayload | null> {
  const { data } = await client.mutate({
    mutation: DEMOTE_USER,
    variables: { id },
  });
  return data?.demoteUser ?? null;
}

/**
 * 创建工作台并指定 Owner（R3/R4/R5）。
 * ownerUserId：选择已有用户；ownerEmail：邀请新用户（返回 ownerInvitationToken）。
 * 两者都缺省时后端回退 actor.id 为 Owner。
 */
export async function createWorkspaceWithOwner(
  input: CreateWorkspaceInput,
): Promise<CreateWorkspaceResultData> {
  const { data } = await client.mutate({
    mutation: CREATE_WORKSPACE,
    variables: { input },
  });
  return (
    data?.createWorkspace ?? {
      result: null,
      errors: [],
    }
  );
}

/**
 * 重指派 pending-owner 工作台的 Owner（#114；platform_admin，已有 Owner 时后端报错）。
 * ownerUserId：改指现有用户直接入座；ownerEmail：原子撤销当前 active Owner 邀请 +
 * 改发新 pending-owner 邀请（7 天有效期，ownerInvitationToken 仅展示一次）。
 * 两者须且只能提供一个（都空或都给后端均报错）。
 */
export async function reassignWorkspaceOwner(
  id: string,
  input: ReassignWorkspaceOwnerInput,
): Promise<ReassignWorkspaceOwnerResultData> {
  const { data } = await client.mutate({
    mutation: REASSIGN_WORKSPACE_OWNER,
    variables: { id, input },
  });
  // 重指派改变 invitations 列表（撤销旧邀请/发新邀请）→ evict 根字段强制重查（同 createInvitation 惯例）
  client.cache.evict({ fieldName: "invitations" });
  client.cache.gc();
  return (
    data?.reassignWorkspaceOwner ?? {
      result: null,
      errors: [],
    }
  );
}

/** 闪念间看板：四率 + 分线（U11/R24/KTD10）。 */
export async function fetchFlashbackAdminStats(): Promise<FlashbackAdminStats | null> {
  const { data } = await client.query({
    query: FLASHBACK_ADMIN_STATS,
    fetchPolicy: "network-only",
  });
  return data?.flashbackAdminStats ?? null;
}

/** 闪念间兑换申请队列（U11/R25）：倒序封顶，channel_note 为用户提交的收款渠道。 */
export async function fetchFlashbackAdminRedemptions(
  limit?: number,
): Promise<FlashbackRedemption[]> {
  const { data } = await client.query({
    query: FLASHBACK_ADMIN_REDEMPTIONS,
    variables: { limit: limit ?? null },
    fetchPolicy: "network-only",
  });
  return data?.flashbackAdminRedemptions ?? [];
}

/** 兑换状态流转（U11/R25，platform_admin）：非法转移由后端 fail-closed 拒绝。 */
export async function updateFlashbackRedemption(
  id: string,
  status: string,
  handledNote?: string,
): Promise<{ id: string; status: string } | null> {
  const { data } = await client.mutate({
    mutation: FLASHBACK_ADMIN_UPDATE_REDEMPTION,
    variables: { id, status, handledNote: handledNote ?? null },
  });
  return data?.flashbackAdminUpdateRedemption ?? null;
}

/** 触达预览（R4/R7）：批量发送前的影响面——三档分布、退订剔除、短信腿就绪位。 */
export async function fetchFlashbackOutreachPreview(
	archiveKey: string,
	channel?: string,
): Promise<FlashbackOutreachPreview | null> {
	const { data } = await client.query({
		query: FLASHBACK_OUTREACH_PREVIEW,
		variables: { archiveKey, channel: channel ?? null },
		fetchPolicy: "network-only",
	});
	return data?.flashbackOutreachPreview ?? null;
}

/** 批次历史（R8）：按批次聚合发送计数，含单人重发批次。 */
export async function fetchFlashbackOutreachBatches(
	archiveKey: string,
): Promise<FlashbackOutreachBatch[]> {
	const { data } = await client.query({
		query: FLASHBACK_OUTREACH_BATCHES,
		variables: { archiveKey },
		fetchPolicy: "network-only",
	});
	return data?.flashbackOutreachBatches ?? [];
}

/** 场次名册（R9）：档案 + 最近触达结果 + 完整联系方式（platform_admin 门控）。 */
export async function fetchFlashbackOutreachRoster(
	archiveKey: string,
	filter?: string,
	search?: string,
): Promise<FlashbackOutreachRosterEntry[]> {
	const { data } = await client.query({
		query: FLASHBACK_OUTREACH_ROSTER,
		variables: { archiveKey, filter: filter ?? null, search: search ?? null },
		fetchPolicy: "network-only",
	});
	return data?.flashbackOutreachRoster ?? [];
}

/** 场次列表（R7 发送入口数据源，platform_admin）。 */
export async function fetchFlashbackAdminArchives(): Promise<FlashbackAdminArchive[]> {
	const { data } = await client.query({
		query: FLASHBACK_ADMIN_ARCHIVES,
		fetchPolicy: "network-only",
	});
	return data?.flashbackAdminArchives ?? [];
}

/** 批量发送（R7/R23，platform_admin）：幂等——同批次重复发送零重复。 */
export async function sendFlashbackOutreach(
	archiveKey: string,
	template: string,
	channel?: string,
): Promise<{ queued: number; skipped: number } | null> {
	const { data } = await client.mutate({
		mutation: FLASHBACK_ADMIN_SEND_OUTREACH,
		variables: { archiveKey, template, channel: channel ?? null },
	});
	return data?.flashbackAdminSendOutreach ?? null;
}

/** 单人重发（R2/R10，platform_admin）：不可重发者由后端带原因拒绝（R5）。 */
export async function resendFlashbackOutreach(
	personId: string,
	template: string,
	channel?: string,
): Promise<{ queued: number; skipped: number; batch: string } | null> {
	const { data } = await client.mutate({
		mutation: FLASHBACK_ADMIN_RESEND_OUTREACH,
		variables: { personId, template, channel: channel ?? null },
	});
	return data?.flashbackAdminResendOutreach ?? null;
}

// ── wish2 愿望管理（U5/KTD5）─────────────────────────────────────────────

/** 「说给主办方听」收件箱：private 愿望 + 作者登录账号联系方式（platform admin） */
export async function fetchFlashbackAdminWishInbox(): Promise<FlashbackAdminWishInboxEntry[]> {
  const { data } = await client.query({
    query: FLASHBACK_ADMIN_WISH_INBOX,
    fetchPolicy: "network-only",
  });
  return data?.flashbackAdminWishInbox ?? [];
}

/** 举报队列（status=pending 按时间正序） */
export async function fetchFlashbackAdminWishReports(): Promise<FlashbackAdminReportEntry[]> {
  const { data } = await client.query({
    query: FLASHBACK_ADMIN_WISH_REPORTS,
    fetchPolicy: "network-only",
  });
  return data?.flashbackAdminWishReports ?? [];
}

/** 驳回举报 */
export async function dismissFlashbackWishReport(
  reportId: string,
): Promise<{ reportId: string; status: string } | null> {
  const { data } = await client.mutate({
    mutation: FLASHBACK_ADMIN_DISMISS_REPORT,
    variables: { reportId },
  });
  return data?.flashbackAdminDismissReport ?? null;
}

/** 批准举报（联动下架目标愿望 + 作者信用置位） */
export async function approveFlashbackWishReport(
  reportId: string,
): Promise<{ reportId: string; status: string } | null> {
  const { data } = await client.mutate({
    mutation: FLASHBACK_ADMIN_APPROVE_REPORT,
    variables: { reportId },
  });
  return data?.flashbackAdminApproveReport ?? null;
}

/** 下架/恢复愿望（hidden=true 联动作者信用置位；false 只清 hidden_at） */
export async function setFlashbackWishHidden(
  wishId: string,
  hidden: boolean,
): Promise<{ wishId: string; hidden: boolean } | null> {
  const { data } = await client.mutate({
    mutation: FLASHBACK_ADMIN_SET_WISH_HIDDEN,
    variables: { wishId, hidden },
  });
  return data?.flashbackAdminSetWishHidden ?? null;
}

// ── 愿望回响（#834/#835，platform_admin）─────────────────────────────────────

/** 某愿望的全部回响 + 当前可通知附议数 */
export async function fetchFlashbackAdminWishEchoes(
  wishId: string,
): Promise<FlashbackAdminWishEchoesResult | null> {
  const { data } = await client.query({
    query: FLASHBACK_ADMIN_WISH_ECHOES,
    variables: { wishId },
    fetchPolicy: "network-only",
  });
  return data?.flashbackAdminWishEchoes ?? null;
}

/** 创建回响草稿 */
export async function createFlashbackWishEcho(
  wishId: string,
  content: string,
): Promise<FlashbackAdminWishEcho | null> {
  const { data } = await client.mutate({
    mutation: FLASHBACK_ADMIN_CREATE_WISH_ECHO,
    variables: { wishId, content },
  });
  return data?.flashbackAdminCreateWishEcho ?? null;
}

/** 修改回响草稿（仅 draft） */
export async function updateFlashbackWishEchoDraft(
  echoId: string,
  content: string,
): Promise<FlashbackAdminWishEcho | null> {
  const { data } = await client.mutate({
    mutation: FLASHBACK_ADMIN_UPDATE_WISH_ECHO_DRAFT,
    variables: { echoId, content },
  });
  return data?.flashbackAdminUpdateWishEchoDraft ?? null;
}

/** 首次发布回响（会触发附议者通知） */
export async function publishFlashbackWishEcho(
  echoId: string,
): Promise<FlashbackAdminWishEcho | null> {
  const { data } = await client.mutate({
    mutation: FLASHBACK_ADMIN_PUBLISH_WISH_ECHO,
    variables: { echoId },
  });
  return data?.flashbackAdminPublishWishEcho ?? null;
}

/** 原地更正已发布回响（不重新通知） */
export async function correctFlashbackWishEcho(
  echoId: string,
  content: string,
): Promise<FlashbackAdminWishEcho | null> {
  const { data } = await client.mutate({
    mutation: FLASHBACK_ADMIN_CORRECT_WISH_ECHO,
    variables: { echoId, content },
  });
  return data?.flashbackAdminCorrectWishEcho ?? null;
}

/** 撤回已发布回响（终态） */
export async function revokeFlashbackWishEcho(
  echoId: string,
): Promise<FlashbackAdminWishEcho | null> {
  const { data } = await client.mutate({
    mutation: FLASHBACK_ADMIN_REVOKE_WISH_ECHO,
    variables: { echoId },
  });
  return data?.flashbackAdminRevokeWishEcho ?? null;
}

/** 回响管理队列：公开树可见愿望 + 回响计数 */
export async function fetchFlashbackAdminListedWishes(): Promise<FlashbackAdminListedWishEntry[]> {
  const { data } = await client.query({
    query: FLASHBACK_ADMIN_LISTED_WISHES,
    fetchPolicy: "network-only",
  });
  return data?.flashbackAdminListedWishes ?? [];
}
