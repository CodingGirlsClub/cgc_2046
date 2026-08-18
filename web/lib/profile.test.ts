import { describe, it, expect, vi, beforeEach } from "vitest";

vi.mock("./apollo-client", () => ({
	client: {
		query: vi.fn(),
		readQuery: vi.fn(),
		mutate: vi.fn(),
		cache: { evict: vi.fn(), gc: vi.fn() },
	},
}));

import { client } from "./apollo-client";
import {
	createPortfolioItem,
	deletePortfolioItem,
	fetchCurrentProfile,
	fetchPortfolioItems,
	fetchProfileRoleSummary,
	fetchWorkspaceProfile,
	updateDisplayName,
	updatePortfolioItem,
	updateWorkspaceProfile,
} from "./profile";

/**
 * 个人资料数据源测试（ADR-0004 per-workspace，唯一真实路径）。
 *
 * vi.mock apollo-client 的 client，按 operationName 返回后端契约形状的数据，
 * 验证前端映射。
 */

const queryMock = vi.mocked(client.query);
const readQueryMock = vi.mocked(client.readQuery);
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
	readQueryMock.mockReset().mockReturnValue(null);
	mutateMock.mockReset();
	cacheMock.evict.mockReset();
	cacheMock.gc.mockReset();
});

/** 全局身份契约形状（me 收窄） */
const meShape = {
	id: "u_999",
	email: "real@example.com",
	displayName: "真实用户",
	isPlatformAdmin: true,
	memberNumber: "CGC-000042",
	joinedAt: "2026-08-02T03:00:00Z",
};

/** per-workspace 档案契约形状 */
const wsProfileShape = {
	id: "wsp_1",
	workspaceId: "ws_1",
	userId: "u_999",
	avatarUrl: null,
	location: "杭州",
	about: "P1 个人简介",
	skills: ["GraphQL", "Elixir"],
	visibility: "workspace",
	uiThemePreference: "dark",
};

describe("lib/profile 真实分支（ADR-0004 me 收窄 + workspaceProfile）", () => {
	it("fetchCurrentProfile：me query 返回 → 映射为全局身份（无 profile 字段）", async () => {
		queryMock.mockImplementation(({ query }) => {
			expect(opName(query)).toBe("MeProfile");
			return Promise.resolve({ data: { me: meShape } } as never);
		});

		const p = await fetchCurrentProfile();
		expect(p).toEqual({
			id: "u_999",
			email: "real@example.com",
			displayName: "真实用户",
			locale: null,
			isPlatformAdmin: true,
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

	it("fetchCurrentProfile：readQuery 缓存命中 → 零网络请求返回缓存数据", async () => {
		readQueryMock.mockReturnValue({ me: meShape } as never);
		const p = await fetchCurrentProfile();
		expect(p.displayName).toBe("真实用户");
		expect(queryMock).not.toHaveBeenCalled();
	});

	it("fetchWorkspaceProfile：workspaceProfile query 返回 → 映射 per-workspace 档案", async () => {
		queryMock.mockImplementation(({ query, variables }) => {
			expect(opName(query)).toBe("WorkspaceProfile");
			expect(variables).toEqual({ workspaceId: "ws_1" });
			return Promise.resolve({
				data: { workspaceProfile: wsProfileShape },
			} as never);
		});

		const p = await fetchWorkspaceProfile("ws_1");
		expect(p).toEqual({
			id: "wsp_1",
			workspaceId: "ws_1",
			userId: "u_999",
			avatarUrl: null,
			location: "杭州",
			about: "P1 个人简介",
			skills: ["GraphQL", "Elixir"],
			visibility: "workspace",
			uiThemePreference: "dark",
			portfolio: [],
		});
	});

	it("fetchWorkspaceProfile：null → null（档案不存在）", async () => {
		queryMock.mockResolvedValue({ data: { workspaceProfile: null } } as never);
		expect(await fetchWorkspaceProfile("ws_1")).toBeNull();
	});

	it("updateWorkspaceProfile：mutation 返回 → 映射更新后档案", async () => {
		mutateMock.mockImplementation(({ mutation, variables }) => {
			expect(opName(mutation)).toBe("UpdateWorkspaceProfile");
			expect(variables).toEqual({
				workspaceId: "ws_1",
				input: { about: "新简介", visibility: "public" },
			});
			return Promise.resolve({
				data: {
					updateWorkspaceProfile: {
						...wsProfileShape,
						about: "新简介",
						visibility: "public",
					},
				},
			} as never);
		});

		const updated = await updateWorkspaceProfile("ws_1", {
			about: "新简介",
			visibility: "public",
		});
		expect(updated?.about).toBe("新简介");
		expect(updated?.visibility).toBe("public");
	});

	it("updateDisplayName：mutation 返回 → 映射全局身份", async () => {
		mutateMock.mockImplementation(({ mutation, variables }) => {
			expect(opName(mutation)).toBe("UpdateDisplayName");
			expect(variables).toEqual({ displayName: "新名字" });
			return Promise.resolve({
				data: {
					updateDisplayName: { ...meShape, displayName: "新名字" },
				},
			} as never);
		});

		const updated = await updateDisplayName("新名字");
		expect(updated.displayName).toBe("新名字");
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
								myRoleNames: ["admin"],
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
		expect(roles).toHaveLength(3);
		expect(roles[0]).toMatchObject({
			workspaceId: "ws_real_1",
			workspaceSlug: "real-ws",
			myRoleNames: ["owner"],
		});
		expect(roles[1].myRoleNames).toEqual(["admin"]);
		expect(roles[2].workspaceId).toBe("ws_real_3");
	});

	it("fetchProfileRoleSummary：空列表", async () => {
		queryMock.mockResolvedValue({ data: { meWorkspaces: [] } } as never);
		const roles = await fetchProfileRoleSummary();
		expect(roles).toEqual([]);
	});
});

describe("lib/profile Portfolio CRUD 真实分支（ADR-0004 per-workspace）", () => {
	it("fetchPortfolioItems：myWorkspacePortfolio query 返回 → 映射为前端条目（network-only）", async () => {
		queryMock.mockImplementation(({ query, fetchPolicy, variables }) => {
			expect(opName(query)).toBe("MyWorkspacePortfolio");
			expect(fetchPolicy).toBe("network-only");
			expect(variables).toEqual({ workspaceId: "ws_1" });
			return Promise.resolve({
				data: {
					myWorkspacePortfolio: [
						{
							id: "pf_1",
							workspaceId: "ws_1",
							title: "AI 课程大纲",
							description: "描述",
							url: "https://example.com/ai",
							icon: "document",
						},
						{
							id: "pf_2",
							workspaceId: "ws_1",
							title: "导师手册",
							description: null,
							url: null,
							icon: "book",
						},
					],
				},
			} as never);
		});

		const items = await fetchPortfolioItems("ws_1");
		expect(items).toHaveLength(2);
		expect(items[0]).toEqual({
			id: "pf_1",
			workspaceId: "ws_1",
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
		queryMock.mockResolvedValue({
			data: { myWorkspacePortfolio: [] },
		} as never);
		expect(await fetchPortfolioItems("ws_1")).toEqual([]);
	});

	it("createPortfolioItem：mutation → 返回后端生成条目并失效缓存", async () => {
		mutateMock.mockImplementation(({ mutation, variables }) => {
			expect(opName(mutation)).toBe("CreatePortfolioItem");
			expect(variables).toEqual({
				workspaceId: "ws_1",
				input: { title: "新作品", description: "新描述", icon: "guide" },
			});
			return Promise.resolve({
				data: {
					createPortfolioItem: {
						id: "pf_new",
						workspaceId: "ws_1",
						title: "新作品",
						description: "新描述",
						url: null,
						icon: "guide",
					},
				},
			} as never);
		});

		const item = await createPortfolioItem("ws_1", {
			title: "新作品",
			description: "新描述",
			icon: "guide",
		});
		expect(item.id).toBe("pf_new");
		expect(item.title).toBe("新作品");
		expect(cacheMock.evict).toHaveBeenCalledWith({
			fieldName: "myWorkspacePortfolio",
		});
		expect(cacheMock.gc).toHaveBeenCalledTimes(1);
	});

	it("createPortfolioItem：返回 null → 抛错", async () => {
		mutateMock.mockResolvedValue({ data: { createPortfolioItem: null } } as never);
		await expect(
			createPortfolioItem("ws_1", { title: "" }),
		).rejects.toThrow("createPortfolioItem failed");
		expect(cacheMock.evict).not.toHaveBeenCalled();
	});

	it("updatePortfolioItem：mutation → 返回更新后条目", async () => {
		mutateMock.mockImplementation(({ mutation, variables }) => {
			expect(opName(mutation)).toBe("UpdatePortfolioItem");
			expect(variables).toEqual({
				id: "pf_1",
				workspaceId: "ws_1",
				input: { title: "改名" },
			});
			return Promise.resolve({
				data: {
					updatePortfolioItem: {
						id: "pf_1",
						workspaceId: "ws_1",
						title: "改名",
						description: "描述",
						url: null,
						icon: "document",
					},
				},
			} as never);
		});

		const item = await updatePortfolioItem("pf_1", "ws_1", { title: "改名" });
		expect(item.title).toBe("改名");
		expect(cacheMock.evict).toHaveBeenCalledWith({
			fieldName: "myWorkspacePortfolio",
		});
	});

	it("deletePortfolioItem：mutation 成功不抛错", async () => {
		mutateMock.mockImplementation(({ mutation, variables }) => {
			expect(opName(mutation)).toBe("DeletePortfolioItem");
			expect(variables).toEqual({ id: "pf_1", workspaceId: "ws_1" });
			return Promise.resolve({
				data: {
					deletePortfolioItem: {
						id: "pf_1",
						workspaceId: "ws_1",
						title: "x",
						description: null,
						url: null,
						icon: "document",
					},
				},
			} as never);
		});

		await expect(deletePortfolioItem("pf_1", "ws_1")).resolves.toBeUndefined();
		expect(cacheMock.evict).toHaveBeenCalledWith({
			fieldName: "myWorkspacePortfolio",
		});
	});

	it("deletePortfolioItem：返回 null → 抛错", async () => {
		mutateMock.mockResolvedValue({ data: { deletePortfolioItem: null } } as never);
		await expect(deletePortfolioItem("pf_x", "ws_1")).rejects.toThrow(
			"deletePortfolioItem failed",
		);
		expect(cacheMock.evict).not.toHaveBeenCalled();
	});
});
