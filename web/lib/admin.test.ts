import { describe, it, expect, vi, beforeEach } from "vitest";

vi.mock("./apollo-client", () => ({
	client: {
		query: vi.fn(),
		mutate: vi.fn(),
		cache: { evict: vi.fn(), gc: vi.fn() },
	},
}));


import { client } from "./apollo-client";
import {
	approveApplication,
	createApplication,
	createWorkspaceWithOwner,
	demoteUser,
	fetchAdminActionLogs,
	fetchApplications,
	fetchMyApplications,
	fetchPendingOperations,
	fetchSignalLogs,
	fetchToolCallLogs,
	fetchUsers,
	fetchWorkspaces,
	promoteUser,
	rejectApplication,
} from "./admin";

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

describe("admin 数据源（Phase 5 GraphQL 契约）", () => {
	it("fetchUsers 返回映射后的 AdminUser 列表", async () => {
		queryMock.mockResolvedValue({
			data: {
				listUsers: [
					{
						id: "u1",
						email: "a@b.c",
						displayName: "Alice",
						isPlatformAdmin: true,
						insertedAt: "2026-08-01T00:00:00Z",
						workspaceMembershipCount: 3,
					},
				],
			},
		} as never);

		const users = await fetchUsers();

		expect(queryMock).toHaveBeenCalledTimes(1);
		expect(opName(queryMock.mock.calls[0][0].query)).toBe("ListUsers");
		expect(users[0]).toMatchObject({
			id: "u1",
			email: "a@b.c",
			displayName: "Alice",
			isPlatformAdmin: true,
			workspaceMembershipCount: 3,
		});
	});

	it("fetchUsers 透传 search/first/after 到 variables", async () => {
		queryMock.mockResolvedValue({ data: { listUsers: [] } } as never);

		await fetchUsers("ali", { first: 20, after: "40" });

		expect(queryMock.mock.calls[0][0].variables).toEqual({
			search: "ali",
			first: 20,
			after: "40",
		});
	});

	it("fetchWorkspaces 返回 AdminWorkspace 列表", async () => {
		queryMock.mockResolvedValue({
			data: {
				listWorkspaces: [
					{
						id: "ws1",
						slug: "cgc-academy",
						name: "CGC 学院",
						joinPolicy: "request",
						sponsorshipEnabled: true,
						insertedAt: "2026-08-01T00:00:00Z",
						memberCount: 12,
					},
				],
			},
		} as never);

		const workspaces = await fetchWorkspaces();

		expect(opName(queryMock.mock.calls[0][0].query)).toBe("ListWorkspaces");
		expect(workspaces[0]).toMatchObject({
			id: "ws1",
			slug: "cgc-academy",
			name: "CGC 学院",
			joinPolicy: "request",
			memberCount: 12,
		});
	});

	it("fetchApplications 透传 status 过滤", async () => {
		queryMock.mockResolvedValue({
			data: {
				listWorkspaceApplications: [
					{
						id: "app1",
						applicantId: "u1",
						name: "新工作台",
						slug: "new-ws",
						purpose: "研究",
						status: "pending",
						rejectionReason: null,
						insertedAt: "2026-08-01T00:00:00Z",
					},
				],
			},
		} as never);

		const apps = await fetchApplications("pending");

		expect(queryMock.mock.calls[0][0].variables).toEqual({
			status: "pending",
			first: 50,
		});
		expect(opName(queryMock.mock.calls[0][0].query)).toBe("ListWorkspaceApplications");
		expect(apps[0].status).toBe("pending");
	});

	it("fetchApplications 始终走网络（P3：network-only，避免 cache-key mismatch 导致审批后列表不刷新）", async () => {
		queryMock.mockResolvedValue({ data: { listWorkspaceApplications: [] } } as never);

		await fetchApplications("pending");

		// 审批后页面 load(status) 重新调用 fetchApplications，必须绕过 cache-first 命中旧缓存
		expect(queryMock.mock.calls[0][0].fetchPolicy).toBe("network-only");
	});

	it("fetchMyApplications 不带变量，返回申请人自己的申请", async () => {
		queryMock.mockResolvedValue({
			data: { myWorkspaceApplications: [] },
		} as never);

		await fetchMyApplications();

		expect(opName(queryMock.mock.calls[0][0].query)).toBe("MyWorkspaceApplications");
	});

	it("审计日志查询返回各自契约形状", async () => {
		queryMock
			.mockResolvedValueOnce({
				data: {
					listToolCallLogs: [
						{
							id: "t1",
							userId: "u1",
							tool: "search",
							resultStatus: "ok",
							errorMessage: null,
							latencyMs: 120,
							insertedAt: "2026-08-01T00:00:00Z",
						},
					],
				},
			} as never)
			.mockResolvedValueOnce({
				data: {
					listPendingOperations: [
						{
							id: "p1",
							userId: "u1",
							tool: "send_email",
							summary: "发送邮件",
							status: "awaiting_confirmation",
							insertedAt: "2026-08-01T00:00:00Z",
						},
					],
				},
			} as never)
			.mockResolvedValueOnce({
				data: {
					listSignalLogs: [
						{
							id: "s1",
							workspaceId: "ws1",
							signalType: "workflow.approval",
							insertedAt: "2026-08-01T00:00:00Z",
						},
					],
				},
			} as never);

		const logs = await fetchToolCallLogs("ws1");
		const ops = await fetchPendingOperations("ws1");
		const signals = await fetchSignalLogs("ws1");

		expect(opName(queryMock.mock.calls[0][0].query)).toBe("ListToolCallLogs");
		expect(queryMock.mock.calls[0][0].variables).toEqual({
			workspaceId: "ws1",
			status: null,
			insertedAfter: null,
			insertedBefore: null,
			first: 50,
		});
		expect(logs[0].resultStatus).toBe("ok");
		expect(opName(queryMock.mock.calls[1][0].query)).toBe("ListPendingOperations");
		expect(ops[0].summary).toBe("发送邮件");
		expect(opName(queryMock.mock.calls[2][0].query)).toBe("ListSignalLogs");
		expect(signals[0].signalType).toBe("workflow.approval");
	});

	it("#117 审计筛选：status/signalType/时间范围透传为 GraphQL 变量", async () => {
		queryMock.mockResolvedValue({ data: {} } as never);

		const filters = {
			status: "forbidden",
			insertedAfter: "2026-08-01T00:00:00Z",
			insertedBefore: "2026-08-10T00:00:00Z",
		};
		await fetchToolCallLogs("ws1", filters);
		expect(queryMock.mock.calls[0][0].variables).toEqual({
			workspaceId: "ws1",
			status: "forbidden",
			insertedAfter: "2026-08-01T00:00:00Z",
			insertedBefore: "2026-08-10T00:00:00Z",
			first: 50,
		});

		await fetchPendingOperations(undefined, { status: "expired" });
		expect(queryMock.mock.calls[1][0].variables).toEqual({
			workspaceId: null,
			status: "expired",
			insertedAfter: null,
			insertedBefore: null,
			first: 50,
		});

		await fetchSignalLogs("ws1", { signalType: "workflow.approval" });
		expect(queryMock.mock.calls[2][0].variables).toEqual({
			workspaceId: "ws1",
			signalType: "workflow.approval",
			insertedAfter: null,
			insertedBefore: null,
			first: 50,
		});

		await fetchAdminActionLogs(undefined, {
			insertedAfter: "2026-08-01T00:00:00Z",
		});
		expect(queryMock.mock.calls[3][0].variables).toEqual({
			action: null,
			insertedAfter: "2026-08-01T00:00:00Z",
			insertedBefore: null,
			first: 50,
		});
	});

	it("approveApplication 调 approveWorkspaceApplication mutation", async () => {
		mutateMock.mockResolvedValue({
			data: {
				approveWorkspaceApplication: {
					result: { id: "app1", status: "approved" },
					errors: [],
				},
			},
		} as never);

		const result = await approveApplication("app1");

		expect(opName(mutateMock.mock.calls[0][0].mutation)).toBe(
			"ApproveWorkspaceApplication",
		);
		expect(mutateMock.mock.calls[0][0].variables).toEqual({ id: "app1" });
		expect(result.result?.status).toBe("approved");
	});

	it("rejectApplication 传 rejectionReason", async () => {
		mutateMock.mockResolvedValue({
			data: {
				rejectWorkspaceApplication: {
					result: { id: "app1", status: "rejected", rejectionReason: "slug 不合适" },
					errors: [],
				},
			},
		} as never);

		const result = await rejectApplication("app1", "slug 不合适");

		expect(opName(mutateMock.mock.calls[0][0].mutation)).toBe(
			"RejectWorkspaceApplication",
		);
		expect(mutateMock.mock.calls[0][0].variables).toEqual({
			id: "app1",
			input: { rejectionReason: "slug 不合适" },
		});
		expect(result.result?.rejectionReason).toBe("slug 不合适");
	});

	it("promoteUser / demoteUser 返回 AdminUserPayload", async () => {
		mutateMock
			.mockResolvedValueOnce({
				data: {
					promoteUser: {
						id: "u1",
						email: "a@b.c",
						isPlatformAdmin: true,
						errors: [],
					},
				},
			} as never)
			.mockResolvedValueOnce({
				data: {
					demoteUser: {
						id: "u1",
						email: "a@b.c",
						isPlatformAdmin: false,
						errors: [],
					},
				},
			} as never);

		const promoted = await promoteUser("u1");
		const demoted = await demoteUser("u1");

		expect(opName(mutateMock.mock.calls[0][0].mutation)).toBe("PromoteUser");
		expect(mutateMock.mock.calls[0][0].variables).toEqual({ id: "u1" });
		expect(promoted?.isPlatformAdmin).toBe(true);
		expect(opName(mutateMock.mock.calls[1][0].mutation)).toBe("DemoteUser");
		expect(demoted?.isPlatformAdmin).toBe(false);
	});

	it("createWorkspaceWithOwner 传 ownerUserId/ownerEmail 并返回 ownerInvitationToken", async () => {
		mutateMock.mockResolvedValue({
			data: {
				createWorkspace: {
					result: {
						id: "ws1",
						slug: "new-ws",
						name: "新工作台",
						joinPolicy: "request",
						sponsorshipEnabled: true,
					},
					metadata: { ownerInvitationToken: "tok123" },
					errors: [],
				},
			},
		} as never);

		const result = await createWorkspaceWithOwner({
			slug: "new-ws",
			name: "新工作台",
			joinPolicy: "request",
			ownerUserId: "u1",
		});

		expect(opName(mutateMock.mock.calls[0][0].mutation)).toBe("CreateWorkspace");
		expect(mutateMock.mock.calls[0][0].variables).toEqual({
			input: {
				slug: "new-ws",
				name: "新工作台",
				joinPolicy: "request",
				ownerUserId: "u1",
			},
		});
		expect(result.result?.id).toBe("ws1");
		expect(result.metadata?.ownerInvitationToken).toBe("tok123");
	});

	it("createWorkspaceWithOwner 支持 ownerEmail 邀请路径", async () => {
		mutateMock.mockResolvedValue({
			data: {
				createWorkspace: {
					result: {
						id: "ws2",
						slug: "invite-ws",
						name: "邀请工作台",
						joinPolicy: "request",
						sponsorshipEnabled: true,
					},
					metadata: { ownerInvitationToken: "tok456" },
					errors: [],
				},
			},
		} as never);

		const result = await createWorkspaceWithOwner({
			slug: "invite-ws",
			name: "邀请工作台",
			ownerEmail: "newbie@example.com",
		});

		expect(mutateMock.mock.calls[0][0].variables).toEqual({
			input: {
				slug: "invite-ws",
				name: "邀请工作台",
				ownerEmail: "newbie@example.com",
			},
		});
		expect(result.metadata?.ownerInvitationToken).toBe("tok456");
	});

	it("createApplication 提交工作台创建申请（R6 /apply；传 applicantId）", async () => {
		mutateMock.mockResolvedValue({
			data: {
				createWorkspaceApplication: {
					result: {
						id: "app1",
						applicantId: "u1",
						name: "研究空间",
						slug: "research",
						purpose: "团队研究",
						status: "pending",
						rejectionReason: null,
						insertedAt: "2026-08-01T00:00:00Z",
					},
					errors: [],
				},
			},
		} as never);

		const result = await createApplication({
			name: "研究空间",
			slug: "research",
			purpose: "团队研究",
			applicantId: "u1",
		});

		expect(opName(mutateMock.mock.calls[0][0].mutation)).toBe(
			"CreateWorkspaceApplication",
		);
		expect(mutateMock.mock.calls[0][0].variables).toEqual({
			input: {
				name: "研究空间",
				slug: "research",
				purpose: "团队研究",
				applicantId: "u1",
			},
		});
		expect(result.result?.status).toBe("pending");
	});
	it("createApplication 失败返回错误信封", async () => {
		mutateMock.mockResolvedValue({
			data: {
				createWorkspaceApplication: {
					result: null,
					errors: [{ message: "slug 已被占用", code: "invalid_attribute" }],
				},
			},
		} as never);

		const result = await createApplication({
			name: "研究空间",
			slug: "taken",
			purpose: "测试",
			applicantId: "u1",
		});

		expect(result.result).toBeNull();
		expect(result.errors[0].message).toBe("slug 已被占用");
	});
});
