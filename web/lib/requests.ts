import { client } from "./apollo-client";
import {
	JOIN_REQUESTS,
	CREATE_JOIN_REQUEST,
	APPROVE_JOIN_REQUEST,
	REJECT_JOIN_REQUEST,
	JOIN_WORKSPACE,
	type JoinRequest,
	type JoinRequestStatus,
	type JoinRequestsFilter,
	type JoinRequestConnection,
} from "./graphql/join-request";
import { GET_WORKSPACE, ME_WORKSPACES } from "./graphql/workspace";
import type { Workspace } from "./graphql/workspace";
import { graphqlErrorMessage } from "./graphql/auth";

/**
 * B-3 加入申请数据源。
 *
 * 唯一真实路径：GraphQL；映射函数纯单测覆盖三态 + expired。
 */

export interface JoinRequestItem {
	id: string;
	workspaceId: string;
	userId: string;
	status: JoinRequestStatus;
	message?: string | null;
	approvedBy?: string | null;
	approvedAt?: string | null;
	rejectionReason?: string | null;
	approvalDeadline?: string | null;
	expiredAt?: string | null;
}

export interface JoinRequestPage {
	items: JoinRequestItem[];
	endKeyset: string | null;
	count: number;
}

/**
 * 将后端 JoinRequest 映射为前端 JoinRequestItem。
 */
export function mapJoinRequest(jr: JoinRequest): JoinRequestItem {
	return {
		id: jr.id,
		workspaceId: jr.workspaceId,
		userId: jr.userId,
		status: jr.status,
		message: jr.message ?? null,
		approvedBy: jr.approvedBy ?? null,
		approvedAt: jr.approvedAt ?? null,
		rejectionReason: jr.rejectionReason ?? null,
		approvalDeadline: jr.approvalDeadline ?? null,
		expiredAt: jr.expiredAt ?? null,
	};
}

/**
 * 将后端分页对象映射为前端 JoinRequestPage。
 */
export function mapJoinRequestPage(
	conn: JoinRequestConnection | null | undefined,
): JoinRequestPage {
	if (!conn || !Array.isArray(conn.results)) {
		return { items: [], endKeyset: null, count: 0 };
	}
	return {
		items: conn.results.map(mapJoinRequest),
		endKeyset: conn.endKeyset ?? null,
		count: conn.count ?? conn.results.length,
	};
}

/**
 * 获取某 workspace 的加入申请列表（Owner/Admin 见全部 pending）。
 */
export async function fetchJoinRequests(
	workspaceId: string,
	opts?: {
		status?: JoinRequestStatus;
		first?: number;
		after?: string;
	},
): Promise<JoinRequestPage> {
	const filter: JoinRequestsFilter = { workspaceId: { eq: workspaceId } };
	if (opts?.status) {
		filter.status = { eq: opts.status };
	}
	const first = opts?.first ?? 50;
	const variables: {
		filter: JoinRequestsFilter;
		first?: number;
		after?: string;
	} = { filter, first };
	if (opts?.after) {
		variables.after = opts.after;
	}

	const { data } = await client.query({
		query: JOIN_REQUESTS,
		variables,
	});

	return mapJoinRequestPage(data?.joinRequests);
}

/**
 * 提交加入申请。
 */
export async function createJoinRequest(
	workspaceId: string,
	userId: string,
	message?: string | null,
): Promise<JoinRequestItem> {
	const { data } = await client.mutate({
		mutation: CREATE_JOIN_REQUEST,
		variables: {
			input: { workspaceId, userId, message: message ?? null },
		},
	});
	const result = data?.createJoinRequest?.result;
	if (!result) {
		const msg =
			data?.createJoinRequest?.errors?.[0]?.message ??
			"createJoinRequest failed";
		throw new Error(msg);
	}
	return mapJoinRequest(result);
}

/**
 * 审批通过加入申请（Owner/Admin）。
 */
export async function approveJoinRequest(
	id: string,
	roleNames?: string[],
): Promise<JoinRequestItem> {
	const { data } = await client.mutate({
		mutation: APPROVE_JOIN_REQUEST,
		variables: {
			id,
			input: { roleNames: roleNames ?? ["member"] },
		},
	});
	const result = data?.approveJoinRequest?.result;
	if (!result) {
		const msg =
			data?.approveJoinRequest?.errors?.[0]?.message ??
			"approveJoinRequest failed";
		throw new Error(msg);
	}
	// 审批通过会改变 joinRequests 与 workspaceMembers 两个列表 → evict 根字段强制重查
	client.cache.evict({ fieldName: "joinRequests" });
	client.cache.evict({ fieldName: "workspaceMembers" });
	client.cache.gc();
	return mapJoinRequest(result);
}

/**
 * 拒绝加入申请（Owner/Admin）。
 */
export async function rejectJoinRequest(
	id: string,
	rejectionReason?: string | null,
): Promise<JoinRequestItem> {
	const { data } = await client.mutate({
		mutation: REJECT_JOIN_REQUEST,
		variables: {
			id,
			input: { rejectionReason: rejectionReason ?? null },
		},
	});
	const result = data?.rejectJoinRequest?.result;
	if (!result) {
		const msg =
			data?.rejectJoinRequest?.errors?.[0]?.message ??
			"rejectJoinRequest failed";
		throw new Error(msg);
	}
	// 拒绝会改变 joinRequests 列表 → evict 根字段强制重查
	client.cache.evict({ fieldName: "joinRequests" });
	client.cache.gc();
	return mapJoinRequest(result);
}

/**
 * 直接加入公开工作台（join_policy==:open）。
 * 后端为 generic action mutation，返回裸 Workspace（无 result/errors 包装）；
 * 失败时后端返回的 Ash error 转成 top-level GraphQL error，Apollo v4 抛
 * CombinedGraphQLErrors（持 .errors 数组），v3 抛 ApolloError（持 .graphQLErrors）。
 * 从中提取首条 message；非 GraphQL 错误（网络异常等）回退兜底文案。
 */
export async function joinWorkspace(
	workspaceId: string,
): Promise<{ id: string; slug: string; name: string }> {
	try {
		const { data } = await client.mutate({
			mutation: JOIN_WORKSPACE,
			variables: { workspaceId },
		});
		const result = data?.joinWorkspace;
		if (!result) {
			throw new Error("joinWorkspace failed");
		}
		// 加入后刷新 meWorkspaces 缓存 —— / 概览页立即出现新工作台（与 updateWorkspaceJoinPolicy 同模式）
		await client.refetchQueries({ include: [ME_WORKSPACES] });
		return result;
	} catch (e) {
		throw new Error(graphqlErrorMessage(e, "joinWorkspace failed"));
	}
}

/**
 * 按 slug 获取工作台（join 页专用，不复用 useWorkspaceBySlug）。
 * 后端 get_workspace query 对 open/request 策略允许已认证用户读取。
 */
export async function fetchWorkspaceBySlug(
	slug: string,
): Promise<Workspace | null> {
	const { data } = await client.query({
		query: GET_WORKSPACE,
		variables: { slug },
	});
	return data?.getWorkspace ?? null;
}
