import type {
	JoinPolicy,
	MembershipRoleName,
	Workspace,
} from "./graphql/workspace";
import {
	ROLE_LABEL_ZH,
	ROLE_NAMES,
	WORKSPACE_MEMBERS,
	ME_WORKSPACES,
	ASSIGN_ROLES,
	type WorkspaceMemberConnection,
	type WorkspaceMembership,
	type WorkspaceMembershipRole,
} from "./graphql/workspace";
import { client } from "./apollo-client";

/**
 * #63/#65 工作台与成员角色数据源（#1 能力接口收敛后）。
 *
 * 后端契约已全部定稿：meWorkspaces（含 myRoleNames / myMembershipId / canAccess /
 * myAbilities / memberCount）、workspaceMembers、assignRoles。唯一真实路径 =
 * GraphQL；mock 双轨与 USE_MOCK_WORKSPACES 开关已删除（2026-08-02 决策：
 * 本地联调直接跑后端，测试用 fixture 直测纯映射函数）。
 */

export interface WorkspaceListItem {
	id: string;
	slug: string;
	name: string;
	joinPolicy: JoinPolicy;
	sponsorshipEnabled: boolean;
	/** 当前用户在该工作台的角色名数组（#64 meWorkspaces 的 myRoleNames） */
	myRoleNames?: MembershipRoleName[];
	/** 当前用户在该工作台的能力列表（#1 能力接口，meWorkspaces.myAbilities） */
	myAbilities?: string[];
	/** 当前用户在该工作台的成员资格 ID（#64 meWorkspaces 的 myMembershipId；非成员为 null） */
	myMembershipId?: string | null;
	/** 展示附加字段 */
	description?: string;
	memberCount?: number;
	unreadCount?: number;
	roles?: string[];
	membershipStatus?: "active" | "pending" | "invited";
}

/** 成员条目（#65 成员列表 + 角色分配） */
export interface WorkspaceMember {
	/** WorkspaceMembership ID（assignRoles 的 id 参数） */
	membershipId: string;
	/** 全局用户 ID */
	userId: string;
	/** 邮箱（真实 workspaceMembers 返回可能不含 email，前端以 userId 兜底展示） */
	email?: string;
	/** 展示名 */
	displayName?: string;
	/** 加入时间（后端未返回时由页面显示 —） */
	joinedAt?: string;
	/** 角色并集（同一成员可持多 role；与后端多角色并集语义一致） */
	roles: MembershipRoleName[];
}

/**
 * 将后端 workspaceMembers 返回的 roles { id name } 对象数组映射为角色名并集。
 * 未知角色名（如 teacher）会被过滤；内置角色与旧 member 均保留（展示词汇，ROLE_NAMES 单源）。
 */
export function mapRoleObjectsToNames(
	roles: WorkspaceMembershipRole[] | null | undefined,
): MembershipRoleName[] {
	if (!roles) return [];
	const valid: MembershipRoleName[] = [...ROLE_NAMES];
	return roles
		.map((r) => r.name as MembershipRoleName)
		.filter((n) => valid.includes(n));
}

/**
 * 将后端 workspaceMembers 分页对象（count/results）映射为前端成员列表。
 * P1：平铺字段 userEmail/userDisplayName/joinedAt 直接映射
 * （不再嵌套 user{}；后端 G6 偏离说明——User read policy 只允许本人读自己，
 * 嵌套关系会被过滤为 null，故用 SQL LEFT JOIN 平铺字段）。
 * 后端未返回时以 userId 兜底展示。
 */
export function mapWorkspaceMembers(
	conn: WorkspaceMemberConnection | null | undefined,
): WorkspaceMember[] {
	if (!conn || !Array.isArray(conn.results)) return [];
	return conn.results.map((m: WorkspaceMembership) => ({
		membershipId: m.id,
		userId: m.userId,
		email: m.userEmail ?? m.userId,
		displayName: m.userDisplayName ?? undefined,
		joinedAt: m.joinedAt ?? undefined,
		roles: mapRoleObjectsToNames(m.roles),
	}));
}

/**
 * 将后端 meWorkspaces 的 Workspace 映射为前端 membershipStatus（#70 QA P2）。
 *
 * 对齐后端契约字段：
 * - canAccess === true 或持有角色（myRoleNames 非空）→ "active"（已加入，可进入）；
 * - 有成员资格（myMembershipId）但暂不可访问 → "pending"（申请审批中）；
 * - 仅受邀（无资格、无角色、不可访问）→ "invited"（待凭据加入）。
 * 真实 meWorkspaces 语义为「当前用户可进入的工作台列表」，正常返回均为 active；
 * 映射函数兼容后续后端扩展（邀请/待审批状态）。
 */
export function mapMembershipStatus(
	ws:
		| Pick<Workspace, "canAccess" | "myMembershipId" | "myRoleNames">
		| null
		| undefined,
): WorkspaceListItem["membershipStatus"] {
	if (!ws) return "invited";
	if (ws.canAccess === true || (ws.myRoleNames?.length ?? 0) > 0)
		return "active";
	if (ws.myMembershipId) return "pending";
	return "invited";
}

/**
 * 获取当前用户可进入的 Workspace 列表。
 * 唯一真实路径（#1）：GraphQL meWorkspaces，补齐 membershipStatus 与 myAbilities。
 */
export async function fetchMyWorkspaces(): Promise<WorkspaceListItem[]> {
	const { data } = await client.query({ query: ME_WORKSPACES });
	return (data?.meWorkspaces ?? []).map((ws) => ({
		id: ws.id,
		slug: ws.slug,
		name: ws.name,
		joinPolicy: ws.joinPolicy,
		sponsorshipEnabled: ws.sponsorshipEnabled,
		myRoleNames: ws.myRoleNames ?? [],
		myAbilities: ws.myAbilities ?? [],
		roles: ws.myRoleNames ?? [],
		membershipStatus: mapMembershipStatus(ws),
		myMembershipId: ws.myMembershipId ?? null,
		memberCount: ws.memberCount ?? undefined,
	}));
}

/**
 * 获取某 workspace 的成员列表（#65）。
 * 唯一真实路径：workspaceMembers（分页对象 count/results + roles{id,name}，
 * filter 用 { workspaceId: { eq } } 内层包装）。
 */
export async function fetchWorkspaceMembers(
	workspaceId: string,
): Promise<WorkspaceMember[]> {
	const { data } = await client.query({
		query: WORKSPACE_MEMBERS,
		variables: { filter: { workspaceId: { eq: workspaceId } } },
	});
	return mapWorkspaceMembers(data?.workspaceMembers);
}

/**
 * 分配成员角色（多角色并集，替换整组；仅具备 assign_roles 能力的用户应调用）。
 * 唯一真实路径：assignRoles mutation（id = membershipId，roleNames 替换整组，
 * 空数组 = 清空角色；无权限时后端返回 forbidden error）。
 */
export async function assignMemberRoles(
	membershipId: string,
	roleNames: MembershipRoleName[],
): Promise<WorkspaceMember> {
	const { data } = await client.mutate({
		mutation: ASSIGN_ROLES,
		variables: { id: membershipId, input: { roleNames } },
	});
	const result = data?.assignRoles?.result;
	if (!result) {
		const msg = data?.assignRoles?.errors?.[0]?.message ?? "assignRoles failed";
		throw new Error(msg);
	}
	return mapAssignRolesResult(result);
}

/**
 * 将后端 assignRoles 返回的 WorkspaceMembership 映射为前端成员条目。
 * #65 review 修复：selection 含 roles{id,name}，保存后回填非空（不再显示 []）。
 * P1：平铺 userEmail/userDisplayName/joinedAt 若返回则透传。
 */
export function mapAssignRolesResult(
	result: WorkspaceMembership,
): WorkspaceMember {
	return {
		membershipId: result.id,
		userId: result.userId,
		email: result.userEmail ?? result.userId,
		displayName: result.userDisplayName ?? undefined,
		joinedAt: result.joinedAt ?? undefined,
		roles: mapRoleObjectsToNames(result.roles),
	};
}

/**
 * 当前用户是否可在某 workspace 内分配角色（#1 能力接口：不再由角色名推断，
 * 直接消费后端下发的 assign_roles 能力，与 Rbac.can?/3 语义一致）。
 * ws 可能为 undefined（未知 slug / 未匹配），此时不可分配。
 */
export function currentUserCanAssignRoles(
	ws: WorkspaceListItem | undefined,
): boolean {
	return ws?.myAbilities?.includes("assign_roles") ?? false;
}

/** 角色并集的中文展示（成员卡片徽章文案） */
export function roleLabelsZh(roles: MembershipRoleName[]): string[] {
	return roles.map((r) => ROLE_LABEL_ZH[r] ?? r);
}
