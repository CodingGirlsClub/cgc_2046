import { describe, it, expect, vi, beforeEach } from "vitest";

vi.mock("./apollo-client", () => ({
	client: { query: vi.fn(), mutate: vi.fn() },
}));

import { client } from "./apollo-client";
import {
	mapJoinRequest,
	mapJoinRequestPage,
	fetchJoinRequests,
	createJoinRequest,
	approveJoinRequest,
	rejectJoinRequest,
	joinWorkspace,
	fetchWorkspaceBySlug,
} from "./requests";
import {
	JOIN_REQUESTS,
	CREATE_JOIN_REQUEST,
	APPROVE_JOIN_REQUEST,
	REJECT_JOIN_REQUEST,
	JOIN_WORKSPACE,
} from "./graphql/join";
import { GET_WORKSPACE } from "./graphql/workspace";

describe("mapJoinRequest（后端 JoinRequest → 前端 JoinRequestItem）", () => {
	it("pending 状态映射", () => {
		const item = mapJoinRequest({
			id: "jr_1",
			workspaceId: "ws_1",
			userId: "u_1",
			status: "pending",
			message: "我想加入学习",
			approvalDeadline: "2026-08-11T03:00:00Z",
		});
		expect(item).toEqual({
			id: "jr_1",
			workspaceId: "ws_1",
			userId: "u_1",
			status: "pending",
			message: "我想加入学习",
			approvedBy: null,
			approvedAt: null,
			rejectionReason: null,
			approvalDeadline: "2026-08-11T03:00:00Z",
			expiredAt: null,
		});
	});

	it("approved 状态映射（含审批人/时间）", () => {
		const item = mapJoinRequest({
			id: "jr_2",
			workspaceId: "ws_1",
			userId: "u_2",
			status: "approved",
			approvedBy: "admin_1",
			approvedAt: "2026-08-05T10:00:00Z",
		});
		expect(item.status).toBe("approved");
		expect(item.approvedBy).toBe("admin_1");
		expect(item.approvedAt).toBe("2026-08-05T10:00:00Z");
	});

	it("rejected 状态映射（含拒绝原因）", () => {
		const item = mapJoinRequest({
			id: "jr_3",
			workspaceId: "ws_1",
			userId: "u_3",
			status: "rejected",
			rejectionReason: "名额已满",
		});
		expect(item.status).toBe("rejected");
		expect(item.rejectionReason).toBe("名额已满");
	});

	it("expired 状态映射", () => {
		const item = mapJoinRequest({
			id: "jr_4",
			workspaceId: "ws_1",
			userId: "u_4",
			status: "expired",
			expiredAt: "2026-08-10T03:00:00Z",
		});
		expect(item.status).toBe("expired");
		expect(item.expiredAt).toBe("2026-08-10T03:00:00Z");
	});

	it("null/undefined 可选字段 → null", () => {
		const item = mapJoinRequest({
			id: "jr_5",
			workspaceId: "ws_1",
			userId: "u_5",
			status: "pending",
		});
		expect(item.message).toBeNull();
		expect(item.approvedBy).toBeNull();
		expect(item.approvedAt).toBeNull();
		expect(item.rejectionReason).toBeNull();
		expect(item.approvalDeadline).toBeNull();
		expect(item.expiredAt).toBeNull();
	});
});

describe("mapJoinRequestPage（后端分页对象 → 前端 JoinRequestPage）", () => {
	it("正常分页映射", () => {
		const page = mapJoinRequestPage({
			count: 2,
			results: [
				{ id: "jr_1", workspaceId: "ws_1", userId: "u_1", status: "pending" },
				{ id: "jr_2", workspaceId: "ws_1", userId: "u_2", status: "approved" },
			],
			endKeyset: "keyset_2",
		});
		expect(page.items).toHaveLength(2);
		expect(page.endKeyset).toBe("keyset_2");
		expect(page.count).toBe(2);
	});

	it("null/undefined/空 results → 空页", () => {
		expect(mapJoinRequestPage(null)).toEqual({
			items: [],
			endKeyset: null,
			count: 0,
		});
		expect(mapJoinRequestPage(undefined)).toEqual({
			items: [],
			endKeyset: null,
			count: 0,
		});
		expect(mapJoinRequestPage({ count: 0, results: [] })).toEqual({
			items: [],
			endKeyset: null,
			count: 0,
		});
	});
});

describe("fetchJoinRequests", () => {
	const queryMock = vi.mocked(client.query);

	beforeEach(() => {
		queryMock.mockReset();
	});

	it("默认调用传 filter workspaceId + first: 50", async () => {
		queryMock.mockImplementation(({ query, variables }) => {
			expect(query).toBe(JOIN_REQUESTS);
			expect(variables).toEqual({
				filter: { workspaceId: { eq: "ws_1" } },
				first: 50,
			});
			return Promise.resolve({
				data: {
					joinRequests: { count: 0, results: [], endKeyset: null },
				},
			} as never);
		});

		await fetchJoinRequests("ws_1");
	});

	it("带 status 过滤", async () => {
		queryMock.mockImplementation(({ variables }) => {
			expect(variables).toEqual({
				filter: {
					workspaceId: { eq: "ws_1" },
					status: { eq: "pending" },
				},
				first: 50,
			});
			return Promise.resolve({
				data: {
					joinRequests: { count: 0, results: [], endKeyset: null },
				},
			} as never);
		});

		await fetchJoinRequests("ws_1", { status: "pending" });
	});

	it("透传 after 游标", async () => {
		queryMock.mockImplementation(({ variables }) => {
			expect(variables!.after).toBe("keyset_prev");
			return Promise.resolve({
				data: {
					joinRequests: { count: 0, results: [], endKeyset: null },
				},
			} as never);
		});

		await fetchJoinRequests("ws_1", { after: "keyset_prev" });
	});
});

describe("createJoinRequest", () => {
	const mutateMock = vi.mocked(client.mutate);

	beforeEach(() => {
		mutateMock.mockReset();
	});

	it("提交 CreateJoinRequest mutation 并返回 JoinRequestItem", async () => {
		mutateMock.mockImplementation(({ mutation, variables }) => {
			expect(mutation).toBe(CREATE_JOIN_REQUEST);
			expect(variables).toEqual({
				input: {
					workspaceId: "ws_1",
					userId: "u_1",
					message: "我想加入学习",
				},
			});
			return Promise.resolve({
				data: {
					createJoinRequest: {
						result: {
							id: "jr_new",
							workspaceId: "ws_1",
							userId: "u_1",
							status: "pending",
							message: "我想加入学习",
							approvalDeadline: "2026-08-11T03:00:00Z",
						},
						errors: [],
					},
				},
			} as never);
		});

		const item = await createJoinRequest("ws_1", "u_1", "我想加入学习");
		expect(item.id).toBe("jr_new");
		expect(item.status).toBe("pending");
	});

	it("mutation 返回 errors → 抛错", async () => {
		mutateMock.mockResolvedValue({
			data: {
				createJoinRequest: {
					result: null,
					errors: [{ message: "duplicate request" }],
				},
			},
		} as never);

		await expect(createJoinRequest("ws_1", "u_1")).rejects.toThrow(
			"duplicate request",
		);
	});
});

describe("approveJoinRequest", () => {
	const mutateMock = vi.mocked(client.mutate);

	beforeEach(() => {
		mutateMock.mockReset();
	});

	it("提交 ApproveJoinRequest mutation（默认 roleNames=[member]）", async () => {
		mutateMock.mockImplementation(({ mutation, variables }) => {
			expect(mutation).toBe(APPROVE_JOIN_REQUEST);
			expect(variables).toEqual({
				id: "jr_1",
				input: { roleNames: ["member"] },
			});
			return Promise.resolve({
				data: {
					approveJoinRequest: {
						result: {
							id: "jr_1",
							status: "approved",
							approvedBy: "admin_1",
							approvedAt: "2026-08-05T10:00:00Z",
						},
						errors: [],
					},
				},
			} as never);
		});

		const item = await approveJoinRequest("jr_1");
		expect(item.status).toBe("approved");
	});

	it("指定 roleNames", async () => {
		mutateMock.mockImplementation(({ variables }) => {
			expect(variables).toEqual({
				id: "jr_1",
				input: { roleNames: ["member", "tutor"] },
			});
			return Promise.resolve({
				data: {
					approveJoinRequest: {
						result: { id: "jr_1", status: "approved" },
						errors: [],
					},
				},
			} as never);
		});

		await approveJoinRequest("jr_1", ["member", "tutor"]);
	});
});

describe("rejectJoinRequest", () => {
	const mutateMock = vi.mocked(client.mutate);

	beforeEach(() => {
		mutateMock.mockReset();
	});

	it("提交 RejectJoinRequest mutation（含拒绝原因）", async () => {
		mutateMock.mockImplementation(({ mutation, variables }) => {
			expect(mutation).toBe(REJECT_JOIN_REQUEST);
			expect(variables).toEqual({
				id: "jr_1",
				input: { rejectionReason: "名额已满" },
			});
			return Promise.resolve({
				data: {
					rejectJoinRequest: {
						result: {
							id: "jr_1",
							status: "rejected",
							rejectionReason: "名额已满",
						},
						errors: [],
					},
				},
			} as never);
		});

		const item = await rejectJoinRequest("jr_1", "名额已满");
		expect(item.status).toBe("rejected");
		expect(item.rejectionReason).toBe("名额已满");
	});

	it("无拒绝原因", async () => {
		mutateMock.mockResolvedValue({
			data: {
				rejectJoinRequest: {
					result: { id: "jr_1", status: "rejected" },
					errors: [],
				},
			},
		} as never);

		const item = await rejectJoinRequest("jr_1");
		expect(item.status).toBe("rejected");
	});
});

describe("joinWorkspace", () => {
	const queryMock = vi.mocked(client.query);

	beforeEach(() => {
		queryMock.mockReset();
	});

	it("提交 JoinWorkspace query", async () => {
		queryMock.mockImplementation(({ query, variables }) => {
			expect(query).toBe(JOIN_WORKSPACE);
			expect(variables).toEqual({ workspaceId: "ws_1" });
			return Promise.resolve({
				data: {
					joinWorkspace: { id: "ws_1", slug: "test", name: "Test" },
				},
			} as never);
		});

		const result = await joinWorkspace("ws_1");
		expect(result.slug).toBe("test");
	});
});

describe("fetchWorkspaceBySlug", () => {
	const queryMock = vi.mocked(client.query);

	beforeEach(() => {
		queryMock.mockReset();
	});

	it("调 GET_WORKSPACE query", async () => {
		queryMock.mockImplementation(({ query, variables }) => {
			expect(query).toBe(GET_WORKSPACE);
			expect(variables).toEqual({ slug: "test-ws" });
			return Promise.resolve({
				data: {
					getWorkspace: {
						id: "ws_1",
						slug: "test-ws",
						name: "Test WS",
						joinPolicy: "open",
						sponsorshipEnabled: true,
					},
				},
			} as never);
		});

		const ws = await fetchWorkspaceBySlug("test-ws");
		expect(ws?.slug).toBe("test-ws");
		expect(ws?.joinPolicy).toBe("open");
	});

	it("workspace 不存在 → null", async () => {
		queryMock.mockResolvedValue({
			data: { getWorkspace: null },
		} as never);

		const ws = await fetchWorkspaceBySlug("no-such-ws");
		expect(ws).toBeNull();
	});
});
