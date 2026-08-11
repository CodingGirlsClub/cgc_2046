import { client } from "./apollo-client";
import type {
	AdminApplicationStatus,
	AdminListArgs,
	AdminPendingOperation,
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
	LIST_PENDING_OPERATIONS,
	LIST_SIGNAL_LOGS,
	LIST_TOOL_CALL_LOGS,
	LIST_USERS,
	LIST_WORKSPACE_APPLICATIONS,
	LIST_WORKSPACES,
	MY_WORKSPACE_APPLICATIONS,
	PROMOTE_USER,
	REJECT_WORKSPACE_APPLICATION,
	type CreateWorkspaceApplicationInput,
	type CreateWorkspaceApplicationResultData,
} from "./graphql/admin";
import {
	CREATE_WORKSPACE,
	type CreateWorkspaceInput,
	type CreateWorkspaceResultData,
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

/** 平台管理员：用户列表（R8；search 匹配 email/display_name） */
export async function fetchUsers(
	search?: string,
	opts?: AdminListArgs,
): Promise<AdminUser[]> {
	const { data } = await client.query({
		query: LIST_USERS,
		variables: listVars({ search: search || null }, opts),
	});
	return data?.listUsers ?? [];
}

/** 平台管理员：工作台列表（R13；search 匹配 name/slug） */
export async function fetchWorkspaces(
	search?: string,
	opts?: AdminListArgs,
): Promise<AdminWorkspace[]> {
	const { data } = await client.query({
		query: LIST_WORKSPACES,
		variables: listVars({ search: search || null }, opts),
	});
	return data?.listWorkspaces ?? [];
}

/** 平台管理员：工作台创建申请列表（R7；status 过滤） */
export async function fetchApplications(
	status?: AdminApplicationStatus,
	opts?: AdminListArgs,
): Promise<AdminWorkspaceApplication[]> {
	const { data } = await client.query({
		query: LIST_WORKSPACE_APPLICATIONS,
		variables: listVars({ status: status ?? null }, opts),
	});
	return data?.listWorkspaceApplications ?? [];
}

/** 当前用户（申请人）自己的工作台创建申请（R7a） */
export async function fetchMyApplications(): Promise<AdminWorkspaceApplication[]> {
	const { data } = await client.query({
		query: MY_WORKSPACE_APPLICATIONS,
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
		// 提交成功后刷新「我的申请」列表（Apollo cache-first 不会自动失效）
		refetchQueries: [{ query: MY_WORKSPACE_APPLICATIONS }],
	});
	return (
		data?.createWorkspaceApplication ?? {
			result: null,
			errors: [{ message: "提交申请失败", code: "no_data" }],
		}
	);
}

/** 平台管理员：MCP 工具调用审计（R10；workspaceId 按 params JSONB 过滤，D5） */
export async function fetchToolCallLogs(
	workspaceId?: string,
	opts?: AdminListArgs,
): Promise<AdminToolCallLog[]> {
	const { data } = await client.query({
		query: LIST_TOOL_CALL_LOGS,
		variables: listVars({ workspaceId: workspaceId ?? null }, opts),
	});
	return data?.listToolCallLogs ?? [];
}

/** 平台管理员：MCP 待确认操作审计（R10；workspaceId 按 params JSONB 过滤，D5） */
export async function fetchPendingOperations(
	workspaceId?: string,
	opts?: AdminListArgs,
): Promise<AdminPendingOperation[]> {
	const { data } = await client.query({
		query: LIST_PENDING_OPERATIONS,
		variables: listVars({ workspaceId: workspaceId ?? null }, opts),
	});
	return data?.listPendingOperations ?? [];
}

/** 平台管理员：workflow 信号日志审计（R10；workspaceId 按真实列过滤） */
export async function fetchSignalLogs(
	workspaceId?: string,
	opts?: AdminListArgs,
): Promise<AdminSignalLog[]> {
	const { data } = await client.query({
		query: LIST_SIGNAL_LOGS,
		variables: listVars({ workspaceId: workspaceId ?? null }, opts),
	});
	return data?.listSignalLogs ?? [];
}

/** 审批通过工作台创建申请（R7；platform_admin，自动创建 workspace + applicant 为 Owner）。
 *  成功后 refetch LIST_WORKSPACE_APPLICATIONS（P3：审批后列表自动刷新，不依赖手动刷新）。 */
export async function approveApplication(
	id: string,
): Promise<ApproveApplicationResultData> {
	const { data } = await client.mutate({
		mutation: APPROVE_WORKSPACE_APPLICATION,
		variables: { id },
		refetchQueries: [{ query: LIST_WORKSPACE_APPLICATIONS, variables: listVars({ status: null }) }],
	});
	return (
		data?.approveWorkspaceApplication ?? {
			result: null,
			errors: [{ message: "审批请求失败", code: "no_data" }],
		}
	);
}

/** 拒绝工作台创建申请（R7；可选拒绝原因）。
 *  成功后 refetch LIST_WORKSPACE_APPLICATIONS（P3：审批后列表自动刷新）。 */
export async function rejectApplication(
	id: string,
	rejectionReason?: string | null,
): Promise<RejectApplicationResultData> {
	const { data } = await client.mutate({
		mutation: REJECT_WORKSPACE_APPLICATION,
		variables: { id, input: { rejectionReason: rejectionReason ?? null } },
		refetchQueries: [{ query: LIST_WORKSPACE_APPLICATIONS, variables: listVars({ status: null }) }],
	});
	return (
		data?.rejectWorkspaceApplication ?? {
			result: null,
			errors: [{ message: "拒绝请求失败", code: "no_data" }],
		}
	);
}

/** 提升用户为 platform_admin（R9） */
export async function promoteUser(id: string): Promise<AdminUserPayload | null> {
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
			errors: [{ message: "创建工作台失败", code: "no_data" }],
		}
	);
}
