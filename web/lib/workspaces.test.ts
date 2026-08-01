import { describe, it, expect } from "vitest";
import {
  mapRoleObjectsToNames,
  mapWorkspaceMembers,
  mapAssignRolesResult,
} from "./workspaces";

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

describe("mapAssignRolesResult（#65 review：保存后回填非空）", () => {
  it("selection 含 roles{id,name} 时回填角色并集非空", () => {
    const member = mapAssignRolesResult({
      id: "wm_0202",
      workspaceId: "ws_02",
      userId: "u_0202",
      roles: [
        { id: "r1", name: "admin" },
        { id: "r2", name: "member" },
      ],
    });
    expect(member.membershipId).toBe("wm_0202");
    expect(member.userId).toBe("u_0202");
    expect(member.roles).toEqual(["admin", "member"]); // 保存后 UI 徽章不再显示 []
    expect(member.email).toBe("u_0202"); // 后端无 email，userId 兜底
  });

  it("roles 缺失（老 schema 未请求）时回填空数组，不崩溃", () => {
    const member = mapAssignRolesResult({
      id: "wm_0202",
      workspaceId: "ws_02",
      userId: "u_0202",
    });
    expect(member.roles).toEqual([]);
  });
});
