import { describe, expect, it } from "vitest";
import {
  mapPermissionMatrixRows,
  PERMISSION_ABILITIES,
  PERMISSION_ROLE_ORDER,
} from "./permissions";
import type { RbacPermissionMatrixRow } from "./graphql/permissions";

describe("mapPermissionMatrixRows（后端旧矩阵 → Slice A 设计矩阵）", () => {
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

  it("总是返回五个设计角色，并将旧 member 映射为 Learner", () => {
    const rows = mapPermissionMatrixRows(backendRows);
    expect(rows).toHaveLength(5);
    expect(rows.map((row) => row.role)).toEqual(PERMISSION_ROLE_ORDER);
    expect(rows.every((row) => PERMISSION_ABILITIES.every((ability) => ability.id in row.abilities))).toBe(true);
    expect(rows.find((row) => row.role === "owner")?.abilities).toMatchObject({
      view_members: true,
      manage_members: true,
      assign_roles: true,
      change_join_policy: true,
      view_profile: true,
      edit_own_profile: true,
      cross_workspace_access: false,
    });
    expect(rows.find((row) => row.role === "admin")?.abilities).toMatchObject({
      manage_members: true,
      assign_roles: true,
      change_join_policy: false,
    });
    expect(rows.find((row) => row.role === "learner")?.abilities).toMatchObject({
      view_members: true,
      manage_members: false,
      assign_roles: false,
      edit_own_profile: true,
      cross_workspace_access: false,
    });
  });

  it("保留后端已知角色，未知角色被过滤，缺失角色用默认能力补齐", () => {
    const rows = mapPermissionMatrixRows([
      { name: "teacher", abilities: backendRows[0].abilities },
      { name: "tutor", abilities: backendRows[0].abilities },
      ...backendRows.slice(0, 1),
    ]);
    expect(rows.map((row) => row.role)).toEqual(PERMISSION_ROLE_ORDER);
    expect(rows.find((row) => row.role === "tutor")?.abilities.manage_members).toBe(false);
  });

  it("null/undefined/空数组 → []，避免空 API payload 被伪造为完整矩阵", () => {
    expect(mapPermissionMatrixRows(null)).toEqual([]);
    expect(mapPermissionMatrixRows(undefined)).toEqual([]);
    expect(mapPermissionMatrixRows([])).toEqual([]);
  });
});
