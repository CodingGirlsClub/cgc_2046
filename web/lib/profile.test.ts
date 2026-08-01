import { describe, it, expect, vi, beforeEach } from "vitest";

vi.mock("./apollo-client", () => ({
  client: { query: vi.fn(), mutate: vi.fn() },
}));

import { client } from "./apollo-client";
import {
  MOCK_CURRENT_PROFILE,
  fetchCurrentProfile,
  updateCurrentProfile,
  fetchProfileRoleSummary,
} from "./profile";

/**
 * 个人资料数据源测试（#69，真实分支）。
 *
 * USE_MOCK_WORKSPACES = false（后端 #64/#66/#68 契约已定稿），
 * fetchCurrentProfile / updateCurrentProfile / fetchProfileRoleSummary
 * 均走真实 GraphQL。此处 vi.mock apollo-client 的 client，
 * 按 operationName 返回后端契约形状的数据，验证前端映射。
 *
 * mock 数据（MOCK_CURRENT_PROFILE 等）保留作兜底，此处仅断言形状。
 */

const queryMock = vi.mocked(client.query);
const mutateMock = vi.mocked(client.mutate);

function opName(query: unknown): string | undefined {
  const q = query as {
    definitions?: Array<{ name?: { value?: string } }>;
  };
  return q.definitions?.[0]?.name?.value;
}

beforeEach(() => {
  queryMock.mockReset();
  mutateMock.mockReset();
});

describe("lib/profile 真实分支（#68 me / updateProfile 契约）", () => {
  it("fetchCurrentProfile：me query 返回 → 映射为 CurrentProfile", async () => {
    queryMock.mockImplementation(({ query }) => {
      expect(opName(query)).toBe("MeProfile");
      return Promise.resolve({
        data: {
          me: {
            id: "u_999",
            email: "real@example.com",
            displayName: "真实用户",
            avatarUrl: null,
            isPlatformAdmin: true,
          },
        },
      } as never);
    });

    const p = await fetchCurrentProfile();
    expect(p).toEqual({
      id: "u_999",
      email: "real@example.com",
      displayName: "真实用户",
      avatarUrl: null,
      isPlatformAdmin: true,
    });
  });

  it("fetchCurrentProfile：me 为 null（异常兜底）→ 返回空资料不崩溃", async () => {
    queryMock.mockResolvedValue({ data: { me: null } } as never);
    const p = await fetchCurrentProfile();
    expect(p.id).toBe("");
    expect(p.displayName).toBeNull();
    expect(p.isPlatformAdmin).toBe(false);
  });

  it("updateCurrentProfile：updateProfile mutation 返回 → 映射更新后资料", async () => {
    mutateMock.mockImplementation(({ mutation }) => {
      expect(opName(mutation)).toBe("UpdateProfile");
      return Promise.resolve({
        data: {
          updateProfile: {
            id: "u_999",
            email: "real@example.com",
            displayName: "新名字",
            avatarUrl: null,
            isPlatformAdmin: false,
          },
        },
      } as never);
    });

    const updated = await updateCurrentProfile({ displayName: "新名字" });
    expect(updated.displayName).toBe("新名字");
    expect(updated.email).toBe("real@example.com");
  });

  it("fetchProfileRoleSummary：meWorkspaces query 返回 → 映射角色并集", async () => {
    queryMock.mockImplementation(({ query }) => {
      const name = opName(query);
      if (name === "MeWorkspaces") {
        return Promise.resolve({
          data: {
            meWorkspaces: [
              {
                id: "ws_real_1",
                slug: "real-ws",
                name: "真实工作台",
                joinPolicy: "open",
                sponsorshipEnabled: true,
                myRoleNames: ["owner"],
              },
              {
                id: "ws_real_2",
                slug: "real-ws-2",
                name: "真实工作台二",
                joinPolicy: "request",
                sponsorshipEnabled: true,
                myRoleNames: ["admin", "member"],
              },
            ],
          },
        } as never);
      }
      return Promise.resolve({ data: {} } as never);
    });

    const roles = await fetchProfileRoleSummary();
    expect(roles).toHaveLength(2);
    expect(roles[0]).toMatchObject({
      workspaceId: "ws_real_1",
      workspaceSlug: "real-ws",
      workspaceName: "真实工作台",
      myRoleNames: ["owner"],
    });
    expect(roles[1].myRoleNames).toEqual(["admin", "member"]);
  });

  it("fetchProfileRoleSummary：受邀无 membership（后端不返回）→ 空列表", async () => {
    queryMock.mockResolvedValue({ data: { meWorkspaces: [] } } as never);
    const roles = await fetchProfileRoleSummary();
    expect(roles).toEqual([]);
  });

  it("mock 兜底数据形状：MOCK_CURRENT_PROFILE 可作无后端时的降级数据", () => {
    expect(MOCK_CURRENT_PROFILE.id).toBe("u_0202");
    expect(typeof MOCK_CURRENT_PROFILE.email).toBe("string");
    expect(MOCK_CURRENT_PROFILE.isPlatformAdmin).toBe(false);
  });
});
