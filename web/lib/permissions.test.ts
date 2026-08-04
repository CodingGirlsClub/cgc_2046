import { describe, expect, it } from "vitest";
import {
	mapPermissionMatrixRows,
	PERMISSION_ABILITIES,
	PERMISSION_ROLE_ORDER,
} from "./permissions";
import type { RbacPermissionMatrixRow } from "./graphql/permissions";

/** 后端通用 abilities 列表 fixture（#1 能力接口：[{name, allowed}]） */
function grants(
	abilities: Record<string, boolean>,
): { name: string; allowed: boolean }[] {
	return Object.entries(abilities).map(([name, allowed]) => ({
		name,
		allowed,
	}));
}

const MANAGER_ABILITIES = {
	view_workspace: true,
	access_invite_only: true,
	list_members: true,
	manage_members: true,
	assign_roles: true,
	update_join_policy: true,
	create_workspace: false,
};

const MEMBER_ABILITIES = {
	view_workspace: true,
	access_invite_only: true,
	list_members: false,
	manage_members: false,
	assign_roles: false,
	update_join_policy: false,
	create_workspace: false,
};

const backendRows: RbacPermissionMatrixRow[] = [
	{ name: "owner", abilities: grants(MANAGER_ABILITIES) },
	{ name: "admin", abilities: grants(MANAGER_ABILITIES) },
	{ name: "member", abilities: grants(MEMBER_ABILITIES) },
	{ name: "tutor", abilities: grants(MEMBER_ABILITIES) },
	{ name: "volunteer", abilities: grants(MEMBER_ABILITIES) },
	{ name: "learner", abilities: grants(MEMBER_ABILITIES) },
];

describe("mapPermissionMatrixRows（后端六角色矩阵 → 五角色展示矩阵，#1 通用列表）", () => {
	it("总是返回五个设计角色，member 行隐藏，能力完整透传", () => {
		const rows = mapPermissionMatrixRows(backendRows);
		expect(rows).toHaveLength(5);
		expect(rows.map((row) => row.role)).toEqual(PERMISSION_ROLE_ORDER);
		expect(
			rows.every((row) =>
				PERMISSION_ABILITIES.every((ability) => ability.id in row.abilities),
			),
		).toBe(true);
		expect(rows.find((row) => row.role === "owner")?.abilities).toMatchObject({
			view_workspace: true,
			access_invite_only: true,
			list_members: true,
			manage_members: true,
			assign_roles: true,
			update_join_policy: true,
			create_workspace: false,
		});
		expect(rows.find((row) => row.role === "admin")?.abilities).toMatchObject({
			manage_members: true,
			assign_roles: true,
			create_workspace: false,
		});
		expect(rows.find((row) => row.role === "learner")?.abilities).toMatchObject(
			{
				view_workspace: true,
				access_invite_only: true,
				list_members: false,
				manage_members: false,
				assign_roles: false,
				create_workspace: false,
			},
		);
		// member 行不参与展示（隐藏而非映射）
		expect(rows.find((row) => row.role === "member")).toBeUndefined();
	});

	it("未知角色被过滤，缺失角色不伪造（仅渲染后端返回的行）", () => {
		const rows = mapPermissionMatrixRows([
			{ name: "teacher", abilities: grants(MANAGER_ABILITIES) },
			{ name: "tutor", abilities: grants(MANAGER_ABILITIES) },
			...backendRows.slice(0, 1),
		]);
		expect(rows.map((row) => row.role)).toEqual(["owner", "tutor"]);
		// tutor 后端行直取能力（传入 owner 的能力 → manage_members 为 true）
		expect(
			rows.find((row) => row.role === "tutor")?.abilities.manage_members,
		).toBe(true);
		// learner 等缺失角色不再被伪造，直接不渲染
		expect(rows.find((row) => row.role === "learner")).toBeUndefined();
		expect(rows).toHaveLength(2);
	});

	it("后端仅返回 member 行时：隐藏（#1 无 member→learner 回退语义）", () => {
		const rows = mapPermissionMatrixRows([
			{ name: "member", abilities: grants(MEMBER_ABILITIES) },
		]);
		expect(rows).toEqual([]);
	});

	it("新增能力自动透传（通用列表不再固定六字段）", () => {
		const rows = mapPermissionMatrixRows([
			{
				name: "owner",
				abilities: grants({ ...MANAGER_ABILITIES, view_audit_log: true }),
			},
		]);
		expect(rows).toHaveLength(1);
		// 类型 = 静态展示词汇（PERMISSION_ABILITIES 已知键）；运行时额外键透传、
		// 由 UI 决定是否展示（矩阵/演示卡只迭代已知能力）——此处 cast 证明运行时行为
		expect((rows[0].abilities as Record<string, boolean>).view_audit_log).toBe(
			true,
		);
	});

	it("null/undefined/空数组 → []，避免空 API payload 被伪造为完整矩阵", () => {
		expect(mapPermissionMatrixRows(null)).toEqual([]);
		expect(mapPermissionMatrixRows(undefined)).toEqual([]);
		expect(mapPermissionMatrixRows([])).toEqual([]);
	});
});

describe("myRolesHaveAbility（判定示例卡展示用，多角色并集）", () => {
	const matrix = mapPermissionMatrixRows(backendRows);

	it("任一角色支持即支持（并集）", () => {
		expect(
			myRolesHaveAbility(["member", "admin"], matrix, "manage_members"),
		).toBe(true);
		expect(
			myRolesHaveAbility(["member", "tutor"], matrix, "manage_members"),
		).toBe(false);
	});

	it("无角色 / 空数组 → false；非模板角色（member）不参与判定", () => {
		expect(myRolesHaveAbility([], matrix, "view_workspace")).toBe(false);
		expect(myRolesHaveAbility(null, matrix, "view_workspace")).toBe(false);
		expect(myRolesHaveAbility(["member"], matrix, "view_workspace")).toBe(
			false,
		);
	});

	it("矩阵缺行时该角色判定为 false", () => {
		expect(myRolesHaveAbility(["learner"], [], "view_workspace")).toBe(false);
	});
});

import { myRolesHaveAbility } from "./permissions";
