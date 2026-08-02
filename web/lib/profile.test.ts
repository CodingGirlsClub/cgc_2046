import { describe, it, expect, vi, beforeEach } from "vitest";

vi.mock("./apollo-client", () => ({
  client: { query: vi.fn(), mutate: vi.fn(), cache: { evict: vi.fn(), gc: vi.fn() } },
}));

import { client } from "./apollo-client";
import {
  MOCK_CURRENT_PROFILE,
  MOCK_PROFILE_PORTFOLIO,
  createPortfolioItem,
  deletePortfolioItem,
  fetchCurrentProfile,
  fetchPortfolioItems,
  fetchProfileRoleSummary,
  updateCurrentProfile,
  updatePortfolioItem,
} from "./profile";

/**
 * 个人资料数据源测试（#69/#P1，真实分支）。
 *
 * USE_MOCK_WORKSPACES = false（后端 #64/#66/#68/#P1 契约已定稿），
 * fetchCurrentProfile / updateCurrentProfile / fetchProfileRoleSummary /
 * Portfolio CRUD 均走真实 GraphQL。此处 vi.mock apollo-client 的 client，
 * 按 operationName 返回后端契约形状的数据，验证前端映射。
 *
 * mock 数据（MOCK_CURRENT_PROFILE 等）保留作兜底，此处仅断言形状。
 */

const queryMock = vi.mocked(client.query);
const mutateMock = vi.mocked(client.mutate);
const cacheMock = vi.mocked(client.cache);

function opName(query: unknown): string | undefined {
  const q = query as {
    definitions?: Array<{ name?: { value?: string } }>;
  };
  return q.definitions?.[0]?.name?.value;
}

beforeEach(() => {
  queryMock.mockReset();
  mutateMock.mockReset();
  cacheMock.evict.mockReset();
  cacheMock.gc.mockReset();
});

/** P1 契约形状：me 返回扩展字段 */
const meShape = {
  id: "u_999",
  email: "real@example.com",
  displayName: "真实用户",
  avatarUrl: null,
  isPlatformAdmin: true,
  location: "杭州",
  about: "P1 个人简介",
  skills: ["GraphQL", "Elixir"],
  visibility: "workspace",
  memberNumber: "CGC-000042",
  joinedAt: "2026-08-02T03:00:00Z",
};

describe("lib/profile 真实分支（#68 me / updateProfile + P1 扩展）", () => {
  it("fetchCurrentProfile：me query 返回 → 映射为 CurrentProfile（含 P1 扩展字段）", async () => {
    queryMock.mockImplementation(({ query }) => {
      expect(opName(query)).toBe("MeProfile");
      return Promise.resolve({ data: { me: meShape } } as never);
    });

    const p = await fetchCurrentProfile();
    expect(p).toEqual({
      id: "u_999",
      email: "real@example.com",
      displayName: "真实用户",
      avatarUrl: null,
      isPlatformAdmin: true,
      location: "杭州",
      about: "P1 个人简介",
      skills: ["GraphQL", "Elixir"],
      visibility: "workspace",
      memberNumber: "CGC-000042",
      joinedAt: "2026-08-02T03:00:00Z",
    });
  });

  it("fetchCurrentProfile：me 为 null（异常兜底）→ 返回空资料不崩溃", async () => {
    queryMock.mockResolvedValue({ data: { me: null } } as never);
    const p = await fetchCurrentProfile();
    expect(p.id).toBe("");
    expect(p.displayName).toBeNull();
    expect(p.isPlatformAdmin).toBe(false);
  });

  it("updateCurrentProfile：updateProfile mutation 返回 → 映射更新后资料（含 P1 扩展）", async () => {
    mutateMock.mockImplementation(({ mutation }) => {
      expect(opName(mutation)).toBe("UpdateProfile");
      return Promise.resolve({
        data: {
          updateProfile: {
            ...meShape,
            displayName: "新名字",
            location: "深圳",
            skills: ["TS", "React"],
            visibility: "only_me",
          },
        },
      } as never);
    });

    const updated = await updateCurrentProfile({
      displayName: "新名字",
      avatarUrl: null,
      location: "深圳",
      about: "P1 个人简介",
      skills: ["TS", "React"],
      visibility: "only_me",
    });
    expect(updated.displayName).toBe("新名字");
    expect(updated.location).toBe("深圳");
    expect(updated.skills).toEqual(["TS", "React"]);
    expect(updated.visibility).toBe("only_me");
  });

  it("fetchProfileRoleSummary：meWorkspaces query 返回 → 映射角色并集（P1-3 确定性排序）", async () => {
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
                myMembershipId: "wm_1",
                canAccess: true,
              },
              {
                id: "ws_real_2",
                slug: "real-ws-2",
                name: "真实工作台二",
                joinPolicy: "request",
                sponsorshipEnabled: true,
                myRoleNames: ["admin", "member"],
                myMembershipId: "wm_2",
                canAccess: true,
              },
              {
                id: "ws_real_3",
                slug: "real-ws-3",
                name: "待审批工作台",
                joinPolicy: "request",
                sponsorshipEnabled: true,
                myRoleNames: ["tutor"],
                myMembershipId: "wm_3",
                canAccess: false,
              },
            ],
          },
        } as never);
      }
      return Promise.resolve({ data: {} } as never);
    });

    const roles = await fetchProfileRoleSummary();
    // P1-3：active 优先（ws_1/ws_2 在 ws_3 前），再按角色权重降序（owner 6 > admin 5）
    expect(roles).toHaveLength(3);
    expect(roles[0]).toMatchObject({
      workspaceId: "ws_real_1",
      workspaceSlug: "real-ws",
      myRoleNames: ["owner"],
    });
    expect(roles[1].myRoleNames).toEqual(["admin", "member"]);
    expect(roles[2].workspaceId).toBe("ws_real_3");
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

describe("lib/profile Portfolio CRUD 真实分支（P1 myPortfolio 契约）", () => {
  it("fetchPortfolioItems：myPortfolio query 返回 → 映射为前端条目（network-only 防旧缓存）", async () => {
    queryMock.mockImplementation(({ query, fetchPolicy }) => {
      expect(opName(query)).toBe("MyPortfolio");
      // P2-3：保存后重新拉取必须绕过 cache-first 旧缓存
      expect(fetchPolicy).toBe("network-only");
      return Promise.resolve({
        data: {
          myPortfolio: [
            {
              id: "pf_1",
              userId: "u_999",
              title: "AI 课程大纲",
              description: "描述",
              url: "https://example.com/ai",
              icon: "document",
            },
            {
              id: "pf_2",
              userId: "u_999",
              title: "导师手册",
              description: null,
              url: null,
              icon: "book",
            },
          ],
        },
      } as never);
    });

    const items = await fetchPortfolioItems();
    expect(items).toHaveLength(2);
    expect(items[0]).toEqual({
      id: "pf_1",
      title: "AI 课程大纲",
      description: "描述",
      url: "https://example.com/ai",
      icon: "document",
    });
    expect(items[1].description).toBe("");
    expect(items[1].url).toBeNull();
    expect(items[1].icon).toBe("book");
  });

  it("fetchPortfolioItems：空数组 → []", async () => {
    queryMock.mockResolvedValue({ data: { myPortfolio: [] } } as never);
    expect(await fetchPortfolioItems()).toEqual([]);
  });

  it("createPortfolioItem：createPortfolioItem mutation → 返回后端生成条目", async () => {
    mutateMock.mockImplementation(({ mutation }) => {
      expect(opName(mutation)).toBe("CreatePortfolioItem");
      return Promise.resolve({
        data: {
          createPortfolioItem: {
            result: {
              id: "pf_new",
              userId: "u_999",
              title: "新作品",
              description: "新描述",
              url: null,
              icon: "guide",
            },
            errors: [],
          },
        },
      } as never);
    });

    const item = await createPortfolioItem({
      title: "新作品",
      description: "新描述",
      icon: "guide",
    });
    expect(item.id).toBe("pf_new");
    expect(item.title).toBe("新作品");
    expect(item.icon).toBe("guide");
    // P2-3：成功后失效 myPortfolio 缓存
    expect(cacheMock.evict).toHaveBeenCalledWith({ fieldName: "myPortfolio" });
    expect(cacheMock.gc).toHaveBeenCalledTimes(1);
  });

  it("createPortfolioItem：errors 返回 → 抛错", async () => {
    mutateMock.mockResolvedValue({
      data: {
        createPortfolioItem: {
          result: null,
          errors: [{ message: "title 不能为空" }],
        },
      },
    } as never);
    await expect(createPortfolioItem({ title: "" })).rejects.toThrow("title 不能为空");
    expect(cacheMock.evict).not.toHaveBeenCalled();
  });

  it("updatePortfolioItem：updatePortfolioItem mutation → 返回更新后条目", async () => {
    mutateMock.mockImplementation(({ mutation }) => {
      expect(opName(mutation)).toBe("UpdatePortfolioItem");
      return Promise.resolve({
        data: {
          updatePortfolioItem: {
            result: {
              id: "pf_1",
              userId: "u_999",
              title: "改名",
              description: "描述",
              url: null,
              icon: "document",
            },
            errors: [],
          },
        },
      } as never);
    });

    const item = await updatePortfolioItem("pf_1", { title: "改名" });
    expect(item.title).toBe("改名");
    // P2-3：成功后失效 myPortfolio 缓存
    expect(cacheMock.evict).toHaveBeenCalledWith({ fieldName: "myPortfolio" });
    expect(cacheMock.gc).toHaveBeenCalledTimes(1);
  });

  it("deletePortfolioItem：deletePortfolioItem mutation 成功不抛错", async () => {
    mutateMock.mockImplementation(({ mutation }) => {
      expect(opName(mutation)).toBe("DeletePortfolioItem");
      return Promise.resolve({
        data: {
          deletePortfolioItem: {
            result: { id: "pf_1", userId: "u_999", title: "x", description: null, url: null, icon: "document" },
            errors: [],
          },
        },
      } as never);
    });

    await expect(deletePortfolioItem("pf_1")).resolves.toBeUndefined();
    // P2-3：成功后失效 myPortfolio 缓存
    expect(cacheMock.evict).toHaveBeenCalledWith({ fieldName: "myPortfolio" });
    expect(cacheMock.gc).toHaveBeenCalledTimes(1);
  });

  it("deletePortfolioItem：errors 返回 → 抛错", async () => {
    mutateMock.mockResolvedValue({
      data: {
        deletePortfolioItem: {
          result: null,
          errors: [{ message: "forbidden" }],
        },
      },
    } as never);
    await expect(deletePortfolioItem("pf_x")).rejects.toThrow("forbidden");
    expect(cacheMock.evict).not.toHaveBeenCalled();
  });

  it("mock 兜底：MOCK_PROFILE_PORTFOLIO 是设计稿演示数据（10 条、三图标齐全）", () => {
    expect(MOCK_PROFILE_PORTFOLIO).toHaveLength(10);
    const icons = new Set(MOCK_PROFILE_PORTFOLIO.map((item) => item.icon));
    expect(icons.has("document")).toBe(true);
    expect(icons.has("book")).toBe(true);
    expect(icons.has("guide")).toBe(true);
  });
});
