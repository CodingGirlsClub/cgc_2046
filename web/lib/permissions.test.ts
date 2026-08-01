import { describe, it, expect } from "vitest";
import { mapPermissionMatrixRows } from "./permissions";
import type { RbacPermissionMatrixRow } from "./graphql/permissions";

/**
 * #67/#66 权限矩阵 lib 测试。
 * 纯函数测试 mapPermissionMatrixRows（后端 permissionMatrix roles → 前端行）。
 * fetchPermissionsMatrix/fetchMyAbilities 的 GraphQL 分支由页面测试 mock 覆盖
 * （USE_MOCK 模式保持 mock 矩阵）。
 */

describe("mapPermissionMatrixRows（后端 permissionMatrix roles → 前端行）", () => {
  const backendRows: RbacPermissionMatrixRow[] = [
    {
      name: "owner",
      abilities: {
        view_workspace: true,
        access_invite_only: true,
        list_members: true,
        manage_members: true,
        assign_roles: true,
        create_workspace: false,
      },
    },
    {
      name: "admin",
      abilities: {
        view_workspace: true,
        access_invite_only: true,
        list_members: true,
        manage_members: true,
        assign_roles: true,
        create_workspace: false,
      },
    },
    {
      name: "member",
      abilities: {
        view_workspace: true,
        access_invite_only: true,
        list_members: false,
        manage_members: false,
        assign_roles: false,
        create_workspace: false,
      },
    },
  ];

  it("三角色映射完整，abilities 字段名与前端 PermissionAbility 一致", () => {
    const rows = mapPermissionMatrixRows(backendRows);
    expect(rows).toHaveLength(3);
    expect(rows.map((r) => r.role)).toEqual(["owner", "admin", "member"]);
    // owner/admin 管理能力全 true
    expect(rows[0].abilities).toEqual({
      view_workspace: true,
      access_invite_only: true,
      list_members: true,
      manage_members: true,
      assign_roles: true,
      create_workspace: false,
    });
    expect(rows[1].abilities).toEqual(rows[0].abilities);
    // member 仅 view/access
    expect(rows[2].abilities).toEqual({
      view_workspace: true,
      access_invite_only: true,
      list_members: false,
      manage_members: false,
      assign_roles: false,
      create_workspace: false,
    });
  });

  it("未知角色名被过滤（仅保留 owner/admin/member）", () => {
    const rows = mapPermissionMatrixRows([
      { name: "teacher", abilities: backendRows[0].abilities },
      ...backendRows,
    ]);
    expect(rows.map((r) => r.role)).toEqual(["owner", "admin", "member"]);
  });

  it("null/undefined/空数组 → []", () => {
    expect(mapPermissionMatrixRows(null)).toEqual([]);
    expect(mapPermissionMatrixRows(undefined)).toEqual([]);
    expect(mapPermissionMatrixRows([])).toEqual([]);
  });
});
