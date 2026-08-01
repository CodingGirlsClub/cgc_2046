import { describe, it, expect } from "vitest";
import { mapRoleObjectsToNames, mapWorkspaceMembers } from "./workspaces";

describe("mapRoleObjectsToNames（后端 roles{id,name} → 角色名并集）", () => {
  it("合法角色名原样返回", () => {
    expect(
      mapRoleObjectsToNames([
        { id: "r1", name: "owner" },
        { id: "r2", name: "member" },
      ]),
    ).toEqual(["owner", "member"]);
  });

  it("未知角色名被过滤（仅保留 owner/admin/member）", () => {
    expect(
      mapRoleObjectsToNames([
        { id: "r1", name: "teacher" },
        { id: "r2", name: "admin" },
      ]),
    ).toEqual(["admin"]);
  });

  it("null/undefined/空数组 → []", () => {
    expect(mapRoleObjectsToNames(null)).toEqual([]);
    expect(mapRoleObjectsToNames(undefined)).toEqual([]);
    expect(mapRoleObjectsToNames([])).toEqual([]);
  });
});

describe("mapWorkspaceMembers（后端分页对象 count/results → 前端成员列表）", () => {
  it("单成员多角色并集映射", () => {
    const conn = {
      count: 1,
      results: [
        {
          id: "wm_1",
          workspaceId: "ws_1",
          userId: "u_1",
          roles: [
            { id: "r1", name: "admin" },
            { id: "r2", name: "member" },
          ],
        },
      ],
    };
    const list = mapWorkspaceMembers(conn);
    expect(list).toHaveLength(1);
    expect(list[0]).toEqual({
      membershipId: "wm_1",
      userId: "u_1",
      email: "u_1", // 后端未返回 email 时以 userId 兜底
      displayName: undefined,
      roles: ["admin", "member"],
    });
  });

  it("roles 缺失时映射为空角色数组", () => {
    const conn = {
      count: 2,
      results: [
        { id: "wm_1", workspaceId: "ws_1", userId: "u_1" },
        { id: "wm_2", workspaceId: "ws_1", userId: "u_2", roles: null },
      ],
    };
    const list = mapWorkspaceMembers(conn);
    expect(list.map((m) => m.roles)).toEqual([[], []]);
  });

  it("null/undefined/空 results → []", () => {
    expect(mapWorkspaceMembers(null)).toEqual([]);
    expect(mapWorkspaceMembers(undefined)).toEqual([]);
    expect(mapWorkspaceMembers({ count: 0, results: [] })).toEqual([]);
  });
});
