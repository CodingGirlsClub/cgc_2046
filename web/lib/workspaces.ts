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
	UPDATE_WORKSPACE,
	type WorkspaceMemberConnection,
	type WorkspaceMembersFilter,
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
	/** 赞助档位配置（JsonString 数组；E-3 #48） */
	sponsorshipTiers?: string[] | null;
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

/** 分页成员列表返回（#10：游标 + count，hasMore 由调用方按累积数 vs count 推断） */
export interface WorkspaceMemberPage {
	members: WorkspaceMember[];
	endKeyset: string | null;
	/** 本页可见总数（read policy 过滤后；Owner/Admin=全部成员，非 Owner/Admin=1） */
	count: number;
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
		sponsorshipTiers: ws.sponsorshipTiers ?? null,
		myRoleNames: ws.myRoleNames ?? [],
		myAbilities: ws.myAbilities ?? [],
		roles: ws.myRoleNames ?? [],
		membershipStatus: mapMembershipStatus(ws),
		myMembershipId: ws.myMembershipId ?? null,
		memberCount: ws.memberCount ?? undefined,
	}));
}

/**
 * 获取某 workspace 的成员列表（#65 + #10 分页）。
 * 唯一真实路径：workspaceMembers（分页对象 count/results + 游标，
 * filter 用 { workspaceId: { eq } } 内层包装）。
 * 支持后端下推搜索（userEmail/userDisplayName ilike）与角色过滤（roles.name eq）。
 */
export async function fetchWorkspaceMembers(
	workspaceId: string,
	opts?: {
		search?: string;
		role?: MembershipRoleName | "all";
		after?: string;
		first?: number;
	},
): Promise<WorkspaceMemberPage> {
	const first = opts?.first ?? 50;
	const filter: WorkspaceMembersFilter = { workspaceId: { eq: workspaceId } };

	const search = opts?.search?.trim();
	if (search) {
		// ilike：PG ILIKE 大小写不敏感，无需 toLowerCase；%search% 匹配子串。
		const pattern = `%${search}%`;
		filter.or = [
			{ userEmail: { ilike: pattern } },
			{ userDisplayName: { ilike: pattern } },
		];
	}

	if (opts?.role && opts.role !== "all") {
		filter.roles = { name: { eq: opts.role } };
	}

	// 当有 search 或 role 时，用 and 组合 workspaceId + or + roles
	let queryFilter: WorkspaceMembersFilter;
	if (filter.or || filter.roles) {
		const andClauses: WorkspaceMembersFilter[] = [
			{ workspaceId: { eq: workspaceId } },
		];
		if (filter.or) andClauses.push({ or: filter.or });
		if (filter.roles) andClauses.push({ roles: filter.roles });
		queryFilter = { and: andClauses };
	} else {
		queryFilter = filter;
	}

	const variables: { filter: WorkspaceMembersFilter; first?: number; after?: string } = {
		filter: queryFilter,
		first,
	};
	if (opts?.after) {
		variables.after = opts.after;
	}

	const { data } = await client.query({
		query: WORKSPACE_MEMBERS,
		variables,
	});

	const conn = data?.workspaceMembers;
	const members = mapWorkspaceMembers(conn);
	const endKeyset = conn?.endKeyset ?? null;
	// #10：count 是 read policy 过滤后的可见总数（Ash fetch_count 含授权 filter），
	// 用于调用方判断 hasMore（累积已加载 >= count 即末页），替代 endKeyset 启发式。
	// Ash GraphQL 非 relay keyset 不下发 more?，endKeyset 满页时无法区分有无后续。
	const count = conn?.count ?? members.length;

	return { members, endKeyset, count };
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
 * 直接消费后端下发的 assign_roles 能力，判定单源为后端 Rbac.abilities_for/2）。
 * ws 可能为 undefined（未知 slug / 未匹配），此时不可分配。
 */
export function currentUserCanAssignRoles(
	ws: WorkspaceListItem | undefined,
): boolean {
	return ws?.myAbilities?.includes("assign_roles") ?? false;
}

/**
 * 更新工作台加入策略（#78 工作区设置页）。
 * 唯一真实路径：updateWorkspace mutation（id = workspace id，input.joinPolicy；
 * 仅具备 update_join_policy 能力的用户应调用，无权限时后端返回 forbidden error）。
 * 成功后刷新 meWorkspaces 缓存 —— 概览页/工作台徽章消费同一查询，跨页同步新策略。
 */
export async function updateWorkspaceJoinPolicy(
	workspaceId: string,
	joinPolicy: JoinPolicy,
): Promise<{ joinPolicy: JoinPolicy }> {
	const { data } = await client.mutate({
		mutation: UPDATE_WORKSPACE,
		variables: { id: workspaceId, input: { joinPolicy } },
	});
	const result = data?.updateWorkspace?.result;
	if (!result) {
		const msg =
			data?.updateWorkspace?.errors?.[0]?.message ?? "updateWorkspace failed";
		throw new Error(msg);
	}
	await client.refetchQueries({ include: [ME_WORKSPACES] });
	return { joinPolicy: result.joinPolicy };
}

/**
 * E-3 #48：保存工作台级赞助档位配置（tiersJson 为每项 JSON.stringify
 * 后的 JsonString 数组，对齐后端 sponsorship_tiers: {:array, :map}）。
 */
export async function updateWorkspaceSponsorshipTiers(
	workspaceId: string,
	tiersJson: string[],
): Promise<void> {
	const { data } = await client.mutate({
		mutation: UPDATE_WORKSPACE,
		variables: { id: workspaceId, input: { sponsorshipTiers: tiersJson } },
	});
	if (!data?.updateWorkspace?.result) {
		const msg =
			data?.updateWorkspace?.errors?.[0]?.message ??
			"updateWorkspace sponsorshipTiers failed";
		throw new Error(msg);
	}
	await client.refetchQueries({ include: [ME_WORKSPACES] });
}

/**
 * 当前用户是否可在某 workspace 内修改加入策略（#78 能力接口：
 * 直接消费后端下发的 update_join_policy 能力，判定单源为后端 Rbac.abilities_for/2）。
 * ws 可能为 undefined（未知 slug / 未匹配），此时不可修改。
 */
export function currentUserCanUpdateJoinPolicy(
	ws: WorkspaceListItem | undefined,
): boolean {
	return ws?.myAbilities?.includes("update_join_policy") ?? false;
}

/** 角色并集的中文展示（成员卡片徽章文案） */
export function roleLabelsZh(roles: MembershipRoleName[]): string[] {
	return roles.map((r) => ROLE_LABEL_ZH[r] ?? r);
}
