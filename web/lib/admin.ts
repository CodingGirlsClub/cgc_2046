import type { FetchPolicy, TypedDocumentNode } from "@apollo/client";
import { client } from "./apollo-client";
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
  ApproveApplicationResultData,
  RejectApplicationResultData,
} from "./graphql/admin";
import {
  APPROVE_WORKSPACE_APPLICATION,
  CREATE_WORKSPACE_APPLICATION,
  DEMOTE_USER,
  LIST_ADMIN_ACTION_LOGS,
  LIST_PENDING_OPERATIONS,
  LIST_SIGNAL_LOGS,
  LIST_TOOL_CALL_LOGS,
  LIST_USERS,
  LIST_WORKSPACE_APPLICATIONS,
  LIST_WORKSPACES,
  MY_WORKSPACE_APPLICATIONS,
  PROMOTE_USER,
  RECONCILIATION_FINDINGS,
  REJECT_WORKSPACE_APPLICATION,
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
      errors: [{ message: "errors.submitApplicationFailed", code: "no_data" }],
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

/** E-10 #125 对账扫描过滤条件（空值 = 不过滤；rule/entityType 为枚举串） */
export interface ReconciliationFilters {
  rule?: string;
  entityType?: string;
  workspaceId?: string;
}

/** 平台管理员：对账扫描发现（E-10 #125；rule/entityType/workspace 过滤） */
export async function fetchReconciliationFindings(
  filters?: ReconciliationFilters,
  opts?: AdminListArgs,
): Promise<AdminReconciliationFinding[]> {
  return adminList(
    RECONCILIATION_FINDINGS,
    {
      rule: filters?.rule ?? null,
      entityType: filters?.entityType ?? null,
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
      errors: [{ message: "errors.approveRequestFailed", code: "no_data" }],
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
      errors: [{ message: "errors.rejectRequestFailed", code: "no_data" }],
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
      errors: [{ message: "errors.createWorkspaceFailed", code: "no_data" }],
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
      errors: [{ message: "errors.reassignOwnerFailed", code: "no_data" }],
    }
  );
}
