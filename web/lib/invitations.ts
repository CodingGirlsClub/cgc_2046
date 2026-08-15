import { client } from "./apollo-client";
import {
	INVITATIONS,
	CREATE_INVITATION,
	REVOKE_INVITATION,
	ACCEPT_INVITATION,
	VALIDATE_INVITATION,
	type Invitation,
	type InvitationStatus,
	type InvitationsFilter,
	type InvitationConnection,
} from "./graphql/invitation";
import { ME_WORKSPACES } from "./graphql/workspace";

/**
 * B-3 邀请数据源。
 *
 * 唯一真实路径：GraphQL；映射函数纯单测覆盖三态 + expired。
 */

export interface InvitationItem {
	id: string;
	workspaceId: string;
	tokenHash: string;
	plainToken?: string | null;
	/**
	 * 明文邀请令牌。仅 createInvitation 返回时携带（来自 mutation metadata），
	 * 列表/validate/revoke/accept 返回的 InvitationItem 恒为 null。
	 */
	inviterId: string;
	targetEmail?: string | null;
	preauthorizedRoleNames?: string[] | null;
	expiresAt?: string | null;
	status: InvitationStatus;
	acceptedBy?: string | null;
	acceptedAt?: string | null;
	/** validateInvitation 返回的工作台预览字段 */
	workspaceName?: string | null;
	workspaceSlug?: string | null;
	workspaceJoinPolicy?: string | null;
}

export interface InvitationPage {
	items: InvitationItem[];
	endKeyset: string | null;
	count: number;
}

export function invitationRoleLabel(role: string): string {
	return role === "member" ? "成员（无标签）" : role;
}

/**
 * 将后端 Invitation 映射为前端 InvitationItem。
 */
export function mapInvitation(inv: Invitation): InvitationItem {
	return {
		id: inv.id,
		workspaceId: inv.workspaceId,
		tokenHash: inv.tokenHash,
		plainToken: null,
		inviterId: inv.inviterId,
		targetEmail: inv.targetEmail ?? null,
		preauthorizedRoleNames:
			inv.preauthorizedRoleNames?.map(invitationRoleLabel) ?? null,
		expiresAt: inv.expiresAt ?? null,
		status: inv.effectiveStatus ?? inv.status,
		acceptedBy: inv.acceptedBy ?? null,
		acceptedAt: inv.acceptedAt ?? null,
		workspaceName: inv.workspaceName ?? null,
		workspaceSlug: inv.workspaceSlug ?? null,
		workspaceJoinPolicy: inv.workspaceJoinPolicy ?? null,
	};
}

/**
 * 将后端分页对象映射为前端 InvitationPage。
 */
export function mapInvitationPage(
	conn: InvitationConnection | null | undefined,
): InvitationPage {
	if (!conn || !Array.isArray(conn.results)) {
		return { items: [], endKeyset: null, count: 0 };
	}
	return {
		items: conn.results.map(mapInvitation),
		endKeyset: conn.endKeyset ?? null,
		count: conn.count ?? conn.results.length,
	};
}

/**
 * 获取某 workspace 的邀请列表（Owner/Admin 见全部）。
 */
export async function fetchInvitations(
	workspaceId: string,
	opts?: {
		status?: InvitationStatus;
		first?: number;
		after?: string;
	},
): Promise<InvitationPage> {
	const filter: InvitationsFilter = { workspaceId: { eq: workspaceId } };
	if (opts?.status) {
		filter.status = { eq: opts.status };
	}
	const first = opts?.first ?? 50;
	const variables: {
		filter: InvitationsFilter;
		first?: number;
		after?: string;
	} = { filter, first };
	if (opts?.after) {
		variables.after = opts.after;
	}

	const { data } = await client.query({
		query: INVITATIONS,
		variables,
	});

	return mapInvitationPage(data?.invitations);
}

/**
 * 创建邀请（Owner/Admin/Volunteer）。
 */
export async function createInvitation(input: {
	workspaceId: string;
	inviterId: string;
	targetEmail?: string | null;
	preauthorizedRoleNames?: string[] | null;
	expiresAt?: string | null;
}): Promise<InvitationItem> {
	const { data } = await client.mutate({
		mutation: CREATE_INVITATION,
		variables: { input },
	});
	const result = data?.createInvitation?.result;
	if (!result) {
		const msg =
			data?.createInvitation?.errors?.[0]?.message ?? "createInvitation failed";
		throw new Error(msg);
	}
	// 明文 token 仅在创建时通过 mutation metadata 一次性返回，注入到 InvitationItem 供前端即时拼链接
	const plainToken = data?.createInvitation?.metadata?.plainToken ?? null;
	// 新建邀请改变 invitations 列表 → evict 根字段强制重查
	client.cache.evict({ fieldName: "invitations" });
	client.cache.gc();
	return { ...mapInvitation(result), plainToken };
}

/**
 * 撤销邀请（邀请人本人或 Owner/Admin）。
 */
export async function revokeInvitation(id: string): Promise<InvitationItem> {
	const { data } = await client.mutate({
		mutation: REVOKE_INVITATION,
		variables: { id },
	});
	const result = data?.revokeInvitation?.result;
	if (!result) {
		const msg =
			data?.revokeInvitation?.errors?.[0]?.message ?? "revokeInvitation failed";
		throw new Error(msg);
	}
	// 撤销邀请改变 invitations 列表 → evict 根字段强制重查
	client.cache.evict({ fieldName: "invitations" });
	client.cache.gc();
	return mapInvitation(result);
}

/**
 * 校验邀请 token，返回邀请信息 + 工作台预览。
 */
export async function validateInvitation(
	token: string,
): Promise<InvitationItem | null> {
	const { data } = await client.query({
		query: VALIDATE_INVITATION,
		variables: { token },
	});
	const result = data?.validateInvitation;
	if (!result) return null;
	return mapInvitation(result);
}

/**
 * 接受邀请→建 Membership + 预授权角色入座（须传明文 token，后端复验持 token）。
 */
export async function acceptInvitation(
	id: string,
	token: string,
): Promise<InvitationItem> {
	const { data } = await client.mutate({
		mutation: ACCEPT_INVITATION,
		variables: { id, token },
	});
	const result = data?.acceptInvitation?.result;
	if (!result) {
		const msg =
			data?.acceptInvitation?.errors?.[0]?.message ?? "acceptInvitation failed";
		throw new Error(msg);
	}
	// 接受邀请后当前用户成为新成员 → 刷新 meWorkspaces 缓存（/ 立即出现新工作台）
	await client.refetchQueries({ include: [ME_WORKSPACES] });
	return mapInvitation(result);
}
