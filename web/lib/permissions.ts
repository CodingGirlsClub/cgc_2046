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
 * 后端返回六角色（含 member），member 行仅作展示隐藏（成员资格仍可持有，
 * 徽章/筛选继续显示 member）；不做任何语义推断与回退（#1：member→learner
 * 优先级逻辑已删除，真实模式只渲染后端返回行）。
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
 * 设计稿固定的默认角色顺序（五角色，不含 member）。
 * 由 ROLE_NAMES 单源过滤派生，避免重复六角色字面量；member 仅作兼容输入，不出现在正式矩阵。
 */
export const PERMISSION_ROLE_ORDER: MembershipRoleName[] = ROLE_NAMES.filter(
	(role) => role !== "member",
);

export const PERMISSION_ABILITIES: PermissionAbilityDef[] = [
	{
		id: "view_workspace",
		label: "查看工作台",
		description: "查看当前 Workspace 的概览与基本信息。",
	},
	{
		id: "access_invite_only",
		label: "访问仅邀请",
		description: "访问 invite_only 加入策略的 Workspace。",
	},
	{
		id: "list_members",
		label: "查看成员列表",
		description: "查看当前 Workspace 的成员列表与成员角色并集。",
	},
	{
		id: "manage_members",
		label: "管理成员",
		description: "添加、移除或管理当前 Workspace 的成员关系。",
	},
	{
		id: "assign_roles",
		label: "分配角色",
		description: "在成员页调整 Owner 之外的角色；Owner 走专门指派流程。",
	},
	{
		id: "update_join_policy",
		label: "修改加入策略",
		description:
			"切换当前 Workspace 的加入方式（开放加入 / 申请制 / 邀请制）。",
	},
	{
		id: "create_workspace",
		label: "创建工作台",
		description: "创建新的 Workspace（平台级能力，不随角色在矩阵中授予）。",
	},
];

const ROLE_NOTES: Partial<Record<MembershipRoleName, string>> = {
	owner: "全部 Workspace 管理能力；Owner 变更走专门指派。",
	admin: "可管理成员并行内分配非 Owner 角色。",
	tutor: "可查看成员与 Profile，参与教研协作。",
	volunteer: "可查看成员与 Profile，参与被授权的协作任务。",
	learner: "可查看成员与 Profile，编辑自己的 Profile。",
};

/**
 * 将后端 permissionMatrix（六角色 × 六能力，abilities 通用列表）映射为
 * 五角色展示矩阵：按设计稿角色顺序取行，member 行隐藏，缺行不伪造。
 * 不做语义推断（#1：无 member→learner 回退、无字段挑选 —— 能力透传后端返回值）。
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
