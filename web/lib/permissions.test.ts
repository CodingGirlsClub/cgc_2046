import { describe, expect, it } from "vitest";
import {
	mapPermissionMatrixRows,
	PERMISSION_ABILITIES,
	PERMISSION_ROLE_ORDER,
} from "./permissions";
import type { RbacPermissionMatrixRow } from "./graphql/permissions";

describe("mapPermissionMatrixRows（后端六能力矩阵 → 五角色展示矩阵）", () => {
	const backendRows: RbacPermissionMatrixRow[] = [
		{
			name: "owner",
			abilities: {
				viewWorkspace: true,
				accessInviteOnly: true,
				listMembers: true,
				manageMembers: true,
				assignRoles: true,
				createWorkspace: false,
			},
		},
		{
			name: "admin",
			abilities: {
				viewWorkspace: true,
				accessInviteOnly: true,
				listMembers: true,
				manageMembers: true,
				assignRoles: true,
				createWorkspace: false,
			},
		},
		{
			name: "member",
			abilities: {
				viewWorkspace: true,
				accessInviteOnly: true,
				listMembers: false,
				manageMembers: false,
				assignRoles: false,
				createWorkspace: false,
			},
		},
		{
			name: "tutor",
			abilities: {
				viewWorkspace: true,
				accessInviteOnly: true,
				listMembers: false,
				manageMembers: false,
				assignRoles: false,
				createWorkspace: false,
			},
		},
		{
			name: "volunteer",
			abilities: {
				viewWorkspace: true,
				accessInviteOnly: true,
				listMembers: false,
				manageMembers: false,
				assignRoles: false,
				createWorkspace: false,
			},
		},
		{
			name: "learner",
			abilities: {
				viewWorkspace: true,
				accessInviteOnly: true,
				listMembers: false,
				manageMembers: false,
				assignRoles: false,
				createWorkspace: false,
			},
		},
	];

	it("总是返回五个设计角色，并将旧 member 映射为 Learner", () => {
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
	});

	it("未知角色被过滤，缺失角色不伪造（仅渲染后端返回的行）", () => {
		const rows = mapPermissionMatrixRows([
			{ name: "teacher", abilities: backendRows[0].abilities },
			{ name: "tutor", abilities: backendRows[0].abilities },
			...backendRows.slice(0, 1),
		]);
		expect(rows.map((row) => row.role)).toEqual(["owner", "tutor"]);
		// tutor 后端行直取六能力（传入 owner 的 abilities → manage_members 为 true）
		expect(
			rows.find((row) => row.role === "tutor")?.abilities.manage_members,
		).toBe(true);
		// learner 等缺失角色不再被模板伪造，直接不渲染
		expect(rows.find((row) => row.role === "learner")).toBeUndefined();
		expect(rows).toHaveLength(2);
	});

	it("null/undefined/空数组 → []，避免空 API payload 被伪造为完整矩阵", () => {
		expect(mapPermissionMatrixRows(null)).toEqual([]);
		expect(mapPermissionMatrixRows(undefined)).toEqual([]);
		expect(mapPermissionMatrixRows([])).toEqual([]);
	});
});
