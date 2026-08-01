import { describe, it, expect, vi, beforeEach } from "vitest";

vi.mock("./apollo-client", () => ({
  client: { query: vi.fn(), mutate: vi.fn() },
}));

import { client } from "./apollo-client";
import {
  mapRoleObjectsToNames,
  mapWorkspaceMembers,
  mapAssignRolesResult,
  mapMembershipStatus,
  fetchMyWorkspaces,
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

describe("mapMembershipStatus（#70 QA P2：真实分支 membershipStatus 映射）", () => {
  it("canAccess=true → active（已加入）", () => {
    expect(mapMembershipStatus({ canAccess: true, myMembershipId: "m1", myRoleNames: ["member"] })).toBe("active");
    expect(mapMembershipStatus({ canAccess: true, myMembershipId: null, myRoleNames: [] })).toBe("active");
  });

  it("持有角色（myRoleNames 非空）即使 canAccess 未定义 → active", () => {
    expect(mapMembershipStatus({ canAccess: undefined, myMembershipId: "m1", myRoleNames: ["admin"] })).toBe("active");
  });

  it("有成员资格但不可访问 → pending（申请审批中）", () => {
    expect(mapMembershipStatus({ canAccess: false, myMembershipId: "m1", myRoleNames: [] })).toBe("pending");
  });

  it("无资格/无角色/不可访问 → invited（待凭据加入）", () => {
    expect(mapMembershipStatus({ canAccess: false, myMembershipId: null, myRoleNames: [] })).toBe("invited");
  });

  it("null/undefined → invited（兜底）", () => {
    expect(mapMembershipStatus(null)).toBe("invited");
    expect(mapMembershipStatus(undefined)).toBe("invited");
  });
});

describe("fetchMyWorkspaces 真实分支（#70 QA P2：补 membershipStatus）", () => {
  const queryMock = vi.mocked(client.query);
  const opName = (query: unknown): string | undefined => {
    const q = query as { definitions?: Array<{ name?: { value?: string } }> };
    return q.definitions?.[0]?.name?.value;
  };

  beforeEach(() => {
    queryMock.mockReset();
  });

  it("meWorkspaces 返回 → 映射 slug/name/myRoleNames + membershipStatus=active", async () => {
    queryMock.mockImplementation(({ query }) => {
      expect(opName(query)).toBe("MeWorkspaces");
      return Promise.resolve({
        data: {
          meWorkspaces: [
            {
              id: "ws_real_1",
              slug: "be-verify-ws-111",
              name: "真实工作区 A",
              joinPolicy: "open",
              sponsorshipEnabled: true,
              myRoleNames: ["owner", "member"],
              myMembershipId: "wm_1",
              canAccess: true,
            },
            {
              id: "ws_real_2",
              slug: "dbg5-ws-222",
              name: "真实工作区 B",
              joinPolicy: "request",
              sponsorshipEnabled: true,
              myRoleNames: ["member"],
              myMembershipId: "wm_2",
              canAccess: true,
            },
          ],
        },
      } as never);
    });

    const list = await fetchMyWorkspaces();
    expect(list).toHaveLength(2);
    expect(list[0]).toMatchObject({
      id: "ws_real_1",
      slug: "be-verify-ws-111",
      name: "真实工作区 A",
      joinPolicy: "open",
      sponsorshipEnabled: true,
      myRoleNames: ["owner", "member"],
      roles: ["owner", "member"],
      membershipStatus: "active", // #70：真实分支补 status，首页统计不再失真
    });
    expect(list[1].membershipStatus).toBe("active");
  });

  it("meWorkspaces 返回 pending/invited 形状 → 状态正确区分", async () => {
    queryMock.mockResolvedValue({
      data: {
        meWorkspaces: [
          {
            id: "ws_p",
            slug: "pending-ws",
            name: "待审批",
            joinPolicy: "request",
            sponsorshipEnabled: false,
            myRoleNames: [],
            myMembershipId: "wm_p",
            canAccess: false,
          },
          {
            id: "ws_i",
            slug: "invite-ws",
            name: "仅邀请",
            joinPolicy: "invite_only",
            sponsorshipEnabled: false,
            myRoleNames: [],
            myMembershipId: null,
            canAccess: false,
          },
        ],
      },
    } as never);

    const list = await fetchMyWorkspaces();
    expect(list[0].membershipStatus).toBe("pending");
    expect(list[1].membershipStatus).toBe("invited");
  });

  it("meWorkspaces 为空 → 返回空数组", async () => {
    queryMock.mockResolvedValue({ data: { meWorkspaces: [] } } as never);
    expect(await fetchMyWorkspaces()).toEqual([]);
  });
});
