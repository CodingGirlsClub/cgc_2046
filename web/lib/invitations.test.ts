import { describe, it, expect, vi, beforeEach } from "vitest";

vi.mock("./apollo-client", () => ({
	client: {
		query: vi.fn(),
		mutate: vi.fn(),
		refetchQueries: vi.fn(),
		cache: { evict: vi.fn(), gc: vi.fn() },
	},
}));

import { client } from "./apollo-client";
import {
	mapInvitation,
	mapInvitationPage,
	fetchInvitations,
	createInvitation,
	revokeInvitation,
	validateInvitation,
	acceptInvitation,
} from "./invitations";
import {
	INVITATIONS,
	CREATE_INVITATION,
	REVOKE_INVITATION,
	ACCEPT_INVITATION,
	VALIDATE_INVITATION,
} from "./graphql/invitation";
import { ME_WORKSPACES } from "./graphql/workspace";

describe("mapInvitation（后端 Invitation → 前端 InvitationItem）", () => {
	it("active 状态映射（列表不含明文 token，plainToken 恒为 null）", () => {
		const item = mapInvitation({
			id: "inv_1",
			workspaceId: "ws_1",
			tokenHash: "hash_abc",
			inviterId: "admin_1",
			targetEmail: "user@test.com",
			preauthorizedRoleNames: ["learner"],
			expiresAt: "2026-08-20T03:00:00Z",
			status: "active",
		});
		expect(item).toEqual({
			id: "inv_1",
			workspaceId: "ws_1",
			tokenHash: "hash_abc",
			plainToken: null,
			inviterId: "admin_1",
			targetEmail: "user@test.com",
			preauthorizedRoleNames: ["learner"],
			expiresAt: "2026-08-20T03:00:00Z",
			status: "active",
			acceptedBy: null,
			acceptedAt: null,
			workspaceName: null,
			workspaceSlug: null,
			workspaceJoinPolicy: null,
		});
	});

	it("存量 member 预授权原样保留（展示标签在渲染层经 invitationRoleLabel 翻译）", () => {
		const item = mapInvitation({
			id: "inv_legacy",
			workspaceId: "ws_1",
			tokenHash: "hash_legacy",
			inviterId: "admin_1",
			preauthorizedRoleNames: ["member"],
			status: "active",
		});

		expect(item.preauthorizedRoleNames).toEqual(["member"]);
	});

	it("used 状态映射（含接受人/时间）", () => {
		const item = mapInvitation({
			id: "inv_2",
			workspaceId: "ws_1",
			tokenHash: "hash_def",
			inviterId: "admin_1",
			status: "used",
			acceptedBy: "u_1",
			acceptedAt: "2026-08-06T10:00:00Z",
		});
		expect(item.status).toBe("used");
		expect(item.acceptedBy).toBe("u_1");
		expect(item.acceptedAt).toBe("2026-08-06T10:00:00Z");
	});

	it("revoked 状态映射", () => {
		const item = mapInvitation({
			id: "inv_3",
			workspaceId: "ws_1",
			tokenHash: "hash_ghi",
			inviterId: "admin_1",
			status: "revoked",
		});
		expect(item.status).toBe("revoked");
	});

	it("expired 状态映射", () => {
		const item = mapInvitation({
			id: "inv_4",
			workspaceId: "ws_1",
			tokenHash: "hash_jkl",
			inviterId: "admin_1",
			status: "expired",
			expiresAt: "2026-08-01T00:00:00Z",
		});
		expect(item.status).toBe("expired");
		expect(item.expiresAt).toBe("2026-08-01T00:00:00Z");
	});

	it("effectiveStatus 覆盖 status（读时派生过期优先于 DB 持久化状态）", () => {
		const item = mapInvitation({
			id: "inv_eff",
			workspaceId: "ws_1",
			tokenHash: "hash_eff",
			inviterId: "admin_1",
			status: "active",
			effectiveStatus: "expired",
			expiresAt: "2026-08-01T00:00:00Z",
		});
		expect(item.status).toBe("expired");
	});

	it("effectiveStatus 缺失时回落 status", () => {
		const item = mapInvitation({
			id: "inv_fallback",
			workspaceId: "ws_1",
			tokenHash: "hash_fb",
			inviterId: "admin_1",
			status: "active",
		});
		expect(item.status).toBe("active");
	});

	it("validateInvitation 返回含 workspace 预览字段", () => {
		const item = mapInvitation({
			id: "inv_5",
			workspaceId: "ws_1",
			tokenHash: "hash_mno",
			inviterId: "admin_1",
			status: "active",
			workspaceName: "测试工作台",
			workspaceSlug: "test-ws",
			workspaceJoinPolicy: "invite_only",
		});
		expect(item.workspaceName).toBe("测试工作台");
		expect(item.workspaceSlug).toBe("test-ws");
		expect(item.workspaceJoinPolicy).toBe("invite_only");
	});
});

describe("mapInvitationPage（后端分页对象 → 前端 InvitationPage）", () => {
	it("正常分页映射", () => {
		const page = mapInvitationPage({
			count: 2,
			results: [
				{
					id: "inv_1",
					workspaceId: "ws_1",
					tokenHash: "hash_a",
					inviterId: "admin_1",
					status: "active",
				},
				{
					id: "inv_2",
					workspaceId: "ws_1",
					tokenHash: "hash_b",
					inviterId: "admin_1",
					status: "used",
				},
			],
			endKeyset: "keyset_2",
		});
		expect(page.items).toHaveLength(2);
		expect(page.endKeyset).toBe("keyset_2");
		expect(page.count).toBe(2);
	});

	it("null/undefined/空 results → 空页", () => {
		expect(mapInvitationPage(null)).toEqual({
			items: [],
			endKeyset: null,
			count: 0,
		});
		expect(mapInvitationPage(undefined)).toEqual({
			items: [],
			endKeyset: null,
			count: 0,
		});
		expect(mapInvitationPage({ count: 0, results: [] })).toEqual({
			items: [],
			endKeyset: null,
			count: 0,
		});
	});
});

describe("fetchInvitations", () => {
	const queryMock = vi.mocked(client.query);

	beforeEach(() => {
		queryMock.mockReset();
	});

	it("默认调用传 filter workspaceId + first: 50", async () => {
		queryMock.mockImplementation(({ query, variables }) => {
			expect(query).toBe(INVITATIONS);
			expect(variables).toEqual({
				filter: { workspaceId: { eq: "ws_1" } },
				first: 50,
			});
			return Promise.resolve({
				data: { invitations: { count: 0, results: [], endKeyset: null } },
			} as never);
		});

		await fetchInvitations("ws_1");
	});

	it("带 status 过滤", async () => {
		queryMock.mockImplementation(({ variables }) => {
			expect(variables).toEqual({
				filter: {
					workspaceId: { eq: "ws_1" },
					status: { eq: "active" },
				},
				first: 50,
			});
			return Promise.resolve({
				data: { invitations: { count: 0, results: [], endKeyset: null } },
			} as never);
		});

		await fetchInvitations("ws_1", { status: "active" });
	});
});

describe("createInvitation", () => {
	const mutateMock = vi.mocked(client.mutate);
	const evictMock = vi.mocked(client.cache.evict);
	const gcMock = vi.mocked(client.cache.gc);

	beforeEach(() => {
		mutateMock.mockReset();
		evictMock.mockReset();
		gcMock.mockReset();
	});

	it("提交 CreateInvitation mutation", async () => {
		mutateMock.mockImplementation(({ mutation, variables }) => {
			expect(mutation).toBe(CREATE_INVITATION);
			expect(variables).toEqual({
				input: {
					workspaceId: "ws_1",
					inviterId: "admin_1",
					targetEmail: "user@test.com",
					preauthorizedRoleNames: ["learner"],
				},
			});
			return Promise.resolve({
				data: {
					createInvitation: {
						result: {
							id: "inv_new",
							workspaceId: "ws_1",
							targetEmail: "user@test.com",
							preauthorizedRoleNames: ["learner"],
							status: "active",
						},
						metadata: { plainToken: "token_new" },
						errors: [],
					},
				},
			} as never);
		});

		const item = await createInvitation({
			workspaceId: "ws_1",
			inviterId: "admin_1",
			targetEmail: "user@test.com",
			preauthorizedRoleNames: ["learner"],
		});
		expect(item.id).toBe("inv_new");
		expect(item.status).toBe("active");
		expect(item.plainToken).toBe("token_new");
	});

	it("mutation 返回 errors → 抛错", async () => {
		mutateMock.mockResolvedValue({
			data: {
				createInvitation: {
					result: null,
					errors: [{ message: "forbidden" }],
				},
			},
		} as never);

		await expect(
			createInvitation({ workspaceId: "ws_1", inviterId: "admin_1" }),
		).rejects.toThrow("forbidden");
	});

	it("成功后 evict invitations 并 gc（列表页即时同步新建邀请）", async () => {
		mutateMock.mockResolvedValue({
			data: {
				createInvitation: {
					result: { id: "inv_new", status: "active" },
					metadata: { plainToken: "tok_1" },
					errors: [],
				},
			},
		} as never);

		await createInvitation({
			workspaceId: "ws_1",
			inviterId: "admin_1",
		});

		expect(evictMock).toHaveBeenCalledWith({ fieldName: "invitations" });
		expect(gcMock).toHaveBeenCalled();
	});
});

describe("revokeInvitation", () => {
	const mutateMock = vi.mocked(client.mutate);

	beforeEach(() => {
		mutateMock.mockReset();
	});

	it("提交 RevokeInvitation mutation", async () => {
		mutateMock.mockImplementation(({ mutation, variables }) => {
			expect(mutation).toBe(REVOKE_INVITATION);
			expect(variables).toEqual({ id: "inv_1" });
			return Promise.resolve({
				data: {
					revokeInvitation: {
						result: { id: "inv_1", status: "revoked" },
						errors: [],
					},
				},
			} as never);
		});

		const item = await revokeInvitation("inv_1");
		expect(item.status).toBe("revoked");
	});
});

describe("validateInvitation", () => {
	const queryMock = vi.mocked(client.query);

	beforeEach(() => {
		queryMock.mockReset();
	});

	it("有效 token → 返回 InvitationItem（含 workspace 预览）", async () => {
		queryMock.mockImplementation(({ query, variables }) => {
			expect(query).toBe(VALIDATE_INVITATION);
			expect(variables).toEqual({ token: "valid_token" });
			return Promise.resolve({
				data: {
					validateInvitation: {
						id: "inv_1",
						workspaceId: "ws_1",
						tokenHash: "hash",
						inviterId: "admin_1",
						status: "active",
						workspaceName: "测试工作台",
						workspaceSlug: "test-ws",
						workspaceJoinPolicy: "invite_only",
					},
				},
			} as never);
		});

		const item = await validateInvitation("valid_token");
		expect(item?.workspaceName).toBe("测试工作台");
		expect(item?.workspaceSlug).toBe("test-ws");
	});

	it("无效 token → null", async () => {
		queryMock.mockResolvedValue({
			data: { validateInvitation: null },
		} as never);

		const item = await validateInvitation("bad_token");
		expect(item).toBeNull();
	});
});

describe("acceptInvitation", () => {
	const mutateMock = vi.mocked(client.mutate);
	const refetchMock = vi.mocked(client.refetchQueries);

	beforeEach(() => {
		mutateMock.mockReset();
		refetchMock.mockReset();
	});

	it("提交 AcceptInvitation mutation", async () => {
		mutateMock.mockImplementation(({ mutation, variables }) => {
			expect(mutation).toBe(ACCEPT_INVITATION);
			expect(variables).toEqual({ id: "inv_1", token: "tok_1" });
			return Promise.resolve({
				data: {
					acceptInvitation: {
						result: {
							id: "inv_1",
							status: "used",
							acceptedBy: "u_1",
							acceptedAt: "2026-08-06T10:00:00Z",
						},
						errors: [],
					},
				},
			} as never);
		});

		const item = await acceptInvitation("inv_1", "tok_1");
		expect(item.status).toBe("used");
		expect(item.acceptedBy).toBe("u_1");
	});

	it("成功后 refetch ME_WORKSPACES（接受邀请后 / 立即出现新工作台）", async () => {
		mutateMock.mockResolvedValue({
			data: {
				acceptInvitation: {
					result: { id: "inv_1", status: "used" },
					errors: [],
				},
			},
		} as never);
		refetchMock.mockResolvedValue({ data: {} } as never);

		await acceptInvitation("inv_1", "tok_1");

		expect(refetchMock).toHaveBeenCalledWith({ include: [ME_WORKSPACES] });
		expect(refetchMock).toHaveBeenCalledTimes(1);
	});
});
