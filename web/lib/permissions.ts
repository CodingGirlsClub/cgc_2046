import type { MembershipRoleName } from "./graphql/workspace";
import {
	ROLE_NAMES,
} from "./graphql/workspace";
import {
	PERMISSION_MATRIX,
	type RbacAbility,
	type RbacPermissionMatrixRow,
} from "./graphql/permissions";
import { client } from "./apollo-client";

/**
 * #67 权限映射页的数据模型（#1 能力接口收敛后）。
 *
 * 单一数据源 = 后端 RBAC 真实能力（Rbac.abilities_list/0 + Rbac.matrix/0，
 * 经 permissionMatrix GraphQL 契约下发）：abilities 为通用 [{name, allowed}]
 * 列表，前端不再显式挑选六个字段 —— 新增能力自动透传。
 *
 * 矩阵以五个默认角色展示：Owner / Admin / Tutor / Volunteer / Learner。
 * 基准行 = 任意 membership（无标签成员能力 view_workspace + access_invite_only）；
 * tutor/volunteer/learner 是差异标签，当前能力等同，用于工作流步骤授权与分工。
 *
 * 静态展示词汇（PERMISSION_ABILITIES 标签键 / PERMISSION_ROLE_ORDER）由契约测试
 * permissions.contract.test.ts 对照后端 rbac_contract.json 守卫同步。
 */

/** 能力 ID：与后端 RbacAbility 对齐（静态展示词汇，契约测试守卫）。 */
export type PermissionAbility = RbacAbility;

export interface PermissionAbilityDef {
	id: PermissionAbility;
	label: string;
	description: string;
}

export interface PermissionMatrixRow {
	role: MembershipRoleName;
	abilities: Record<PermissionAbility, boolean>;
	note?: string;
}

/**
 * 设计稿固定的默认角色顺序（五角色差异标签）。
 * 由 ROLE_NAMES 单源派生；无独立 member 行——基准能力属于成员资格本身。
 */
export const PERMISSION_ROLE_ORDER: MembershipRoleName[] = [...ROLE_NAMES];

export const PERMISSION_ABILITIES: PermissionAbilityDef[] = [
	{
		id: "view_workspace",
		label: "permissions.ability.view_workspace.label",
		description: "permissions.ability.view_workspace.description",
	},
	{
		id: "access_invite_only",
		label: "permissions.ability.access_invite_only.label",
		description: "permissions.ability.access_invite_only.description",
	},
	{
		id: "list_members",
		label: "permissions.ability.list_members.label",
		description: "permissions.ability.list_members.description",
	},
	{
		id: "manage_members",
		label: "permissions.ability.manage_members.label",
		description: "permissions.ability.manage_members.description",
	},
	{
		id: "assign_roles",
		label: "permissions.ability.assign_roles.label",
		description: "permissions.ability.assign_roles.description",
	},
	{
		id: "update_join_policy",
		label: "permissions.ability.update_join_policy.label",
		description: "permissions.ability.update_join_policy.description",
	},
	{
		id: "manage_events",
		label: "permissions.ability.manage_events.label",
		description: "permissions.ability.manage_events.description",
	},
	{
		id: "create_workspace",
		label: "permissions.ability.create_workspace.label",
		description: "permissions.ability.create_workspace.description",
	},
];

const ROLE_NOTES: Partial<Record<MembershipRoleName, string>> = {
	owner: "permissions.roleNote.owner",
	admin: "permissions.roleNote.admin",
	tutor: "permissions.roleNote.tutor",
	volunteer: "permissions.roleNote.volunteer",
	learner: "permissions.roleNote.learner",
};

/**
 * 将后端 permissionMatrix 映射为五角色展示矩阵：按 ROLE_NAMES 顺序取行，
 * 未知角色被过滤，缺行不伪造。
 * 不做语义推断（#1：无字段挑选 —— 能力透传后端返回值）。
 */
export function mapPermissionMatrixRows(
	rows: RbacPermissionMatrixRow[] | null | undefined,
): PermissionMatrixRow[] {
	if (!rows || !Array.isArray(rows) || rows.length === 0) return [];

	const byName = new Map(rows.map((row) => [row.name, row]));

	return PERMISSION_ROLE_ORDER.flatMap((role) => {
		const backendRow = byName.get(role);
		if (!backendRow) return [];
		const abilities = Object.fromEntries(
			backendRow.abilities.map((grant) => [grant.name, grant.allowed]),
		) as Record<PermissionAbility, boolean>;
		return [{ role, abilities, note: ROLE_NOTES[role] }];
	});
}

/** 获取角色 → 能力矩阵（#1：唯一真实路径，GraphQL 契约消费端）。 */
export async function fetchPermissionsMatrix(): Promise<PermissionMatrixRow[]> {
	const { data } = await client.query({ query: PERMISSION_MATRIX });
	return mapPermissionMatrixRows(data?.permissionMatrix?.roles);
}
