import { describe, it, expect, vi, beforeEach } from "vitest";

vi.mock("./apollo-client", () => ({
	client: { query: vi.fn(), mutate: vi.fn(), refetchQueries: vi.fn() },
}));

import { client } from "./apollo-client";
import { ME_WORKSPACES } from "./graphql/workspace";
import {
	mapRoleObjectsToNames,
	mapWorkspaceMembers,
	mapAssignRolesResult,
	mapMembershipStatus,
	currentUserCanAssignRoles,
	currentUserCanUpdateJoinPolicy,
	fetchMyWorkspaces,
	fetchWorkspaceMembers,
	updateWorkspaceJoinPolicy,
} from "./workspaces";

describe("mapRoleObjectsToNames（后端 roles{id,name} → 角色名并集）", () => {
	it("合法角色名原样返回", () => {
		expect(
			mapRoleObjectsToNames([
				{ id: "r1", name: "owner" },
				{ id: "r2", name: "member" },
				{ id: "r3", name: "tutor" },
			]),
		).toEqual(["owner", "member", "tutor"]);
	});

	it("未知角色名被过滤，但保留设计稿默认角色", () => {
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

	it("P1 平铺字段：userEmail/userDisplayName/joinedAt 直接映射（不再嵌套 user）", () => {
		const conn = {
			count: 1,
			results: [
				{
					id: "wm_2",
					workspaceId: "ws_1",
					userId: "u_2",
					userEmail: "linxi@cgc2046.org",
					userDisplayName: "林溪",
					joinedAt: "2026-08-02T03:00:00Z",
					roles: [{ id: "r1", name: "tutor" }],
				},
			],
		};
		const list = mapWorkspaceMembers(conn);
		expect(list[0]).toEqual({
			membershipId: "wm_2",
			userId: "u_2",
			email: "linxi@cgc2046.org",
			displayName: "林溪",
			joinedAt: "2026-08-02T03:00:00Z",
			roles: ["tutor"],
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
		expect(
			mapMembershipStatus({
				canAccess: true,
				myMembershipId: "m1",
				myRoleNames: ["member"],
			}),
		).toBe("active");
		expect(
			mapMembershipStatus({
				canAccess: true,
				myMembershipId: null,
				myRoleNames: [],
			}),
		).toBe("active");
	});

	it("持有角色（myRoleNames 非空）即使 canAccess 未定义 → active", () => {
		expect(
			mapMembershipStatus({
				canAccess: undefined,
				myMembershipId: "m1",
				myRoleNames: ["admin"],
			}),
		).toBe("active");
	});

	it("有成员资格但不可访问 → pending（申请审批中）", () => {
		expect(
			mapMembershipStatus({
				canAccess: false,
				myMembershipId: "m1",
				myRoleNames: [],
			}),
		).toBe("pending");
	});

	it("无资格/无角色/不可访问 → invited（待凭据加入）", () => {
		expect(
			mapMembershipStatus({
				canAccess: false,
				myMembershipId: null,
				myRoleNames: [],
			}),
		).toBe("invited");
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

	it("meWorkspaces 返回 → 映射 slug/name/myRoleNames + membershipStatus=active + memberCount", async () => {
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
							memberCount: 12,
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
							memberCount: 5,
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
			memberCount: 12, // P1：meWorkspaces 计算字段透传
		});
		expect(list[1].membershipStatus).toBe("active");
		expect(list[1].memberCount).toBe(5);
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

describe("fetchWorkspaceMembers（#10：分页 + 搜索 + 角色过滤）", () => {
	const queryMock = vi.mocked(client.query);
	const opName = (query: unknown): string | undefined => {
		const q = query as { definitions?: Array<{ name?: { value?: string } }> };
		return q.definitions?.[0]?.name?.value;
	};

	beforeEach(() => {
		queryMock.mockReset();
	});

	it("默认调用传 first: 50、无 after、filter 只含 workspaceId", async () => {
		queryMock.mockImplementation(({ query, variables }) => {
			expect(opName(query)).toBe("WorkspaceMembers");
			expect(variables).toEqual({
				filter: { workspaceId: { eq: "ws_1" } },
				first: 50,
			});
			return Promise.resolve({
				data: {
					workspaceMembers: {
						count: 2,
						results: [
							{
								id: "wm_1",
								workspaceId: "ws_1",
								userId: "u_1",
								roles: [{ id: "r1", name: "member" }],
							},
							{
								id: "wm_2",
								workspaceId: "ws_1",
								userId: "u_2",
								roles: [{ id: "r2", name: "admin" }],
							},
						],
						endKeyset: "keyset_2",
					},
				},
			} as never);
		});

		const page = await fetchWorkspaceMembers("ws_1");
		expect(page.members).toHaveLength(2);
		expect(page.endKeyset).toBe("keyset_2");
		expect(page.count).toBe(2); // read policy 过滤后的可见总数
	});

	it("带 search 时 filter 含 or（userEmail/userDisplayName ilike）", async () => {
		queryMock.mockImplementation(({ variables }) => {
			expect(variables).toEqual({
				filter: {
					and: [
						{ workspaceId: { eq: "ws_1" } },
						{
							or: [
								{ userEmail: { ilike: "%Linxi%" } },
								{ userDisplayName: { ilike: "%Linxi%" } },
							],
						},
					],
				},
				first: 50,
			});
			return Promise.resolve({
				data: {
					workspaceMembers: {
						count: 1,
						results: [
							{
								id: "wm_1",
								workspaceId: "ws_1",
								userId: "u_1",
								userEmail: "linxi@cgc2046.org",
								userDisplayName: "林溪",
								roles: [{ id: "r1", name: "tutor" }],
							},
						],
						endKeyset: "keyset_1",
					},
				},
			} as never);
		});

		const page = await fetchWorkspaceMembers("ws_1", { search: "Linxi" });
		expect(page.members).toHaveLength(1);
		expect(page.members[0].email).toBe("linxi@cgc2046.org");
	});

	it("带 role（非 all）时 filter 含 roles.name.eq", async () => {
		queryMock.mockImplementation(({ variables }) => {
			expect(variables).toEqual({
				filter: {
					and: [
						{ workspaceId: { eq: "ws_1" } },
						{ roles: { name: { eq: "admin" } } },
					],
				},
				first: 50,
			});
			return Promise.resolve({
				data: {
					workspaceMembers: {
						count: 1,
						results: [
							{
								id: "wm_1",
								workspaceId: "ws_1",
								userId: "u_1",
								roles: [{ id: "r1", name: "admin" }],
							},
						],
						endKeyset: "keyset_1",
					},
				},
			} as never);
		});

		const page = await fetchWorkspaceMembers("ws_1", { role: "admin" });
		expect(page.members).toHaveLength(1);
	});

	it("search + role 同时存在时 and 含三个子句", async () => {
		queryMock.mockImplementation(({ variables }) => {
			expect(variables).toEqual({
				filter: {
					and: [
						{ workspaceId: { eq: "ws_1" } },
						{
							or: [
								{ userEmail: { ilike: "%test%" } },
								{ userDisplayName: { ilike: "%test%" } },
							],
						},
						{ roles: { name: { eq: "member" } } },
					],
				},
				first: 50,
			});
			return Promise.resolve({
				data: {
					workspaceMembers: {
						count: 0,
						results: [],
						endKeyset: null,
					},
				},
			} as never);
		});

		const page = await fetchWorkspaceMembers("ws_1", {
			search: "test",
			role: "member",
		});
		expect(page.members).toHaveLength(0);
		expect(page.endKeyset).toBeNull();
		expect(page.count).toBe(0);
	});

	it("role=all 时忽略角色过滤", async () => {
		queryMock.mockImplementation(({ variables }) => {
			expect(variables).toEqual({
				filter: { workspaceId: { eq: "ws_1" } },
				first: 50,
			});
			return Promise.resolve({
				data: {
					workspaceMembers: {
						count: 2,
						results: [
							{
								id: "wm_1",
								workspaceId: "ws_1",
								userId: "u_1",
								roles: [{ id: "r1", name: "member" }],
							},
							{
								id: "wm_2",
								workspaceId: "ws_1",
								userId: "u_2",
								roles: [{ id: "r2", name: "admin" }],
							},
						],
						endKeyset: "keyset_2",
					},
				},
			} as never);
		});

		const page = await fetchWorkspaceMembers("ws_1", { role: "all" });
		expect(page.members).toHaveLength(2);
	});

	it("透传 count（满页且 count>本页时，调用方据此判断 hasMore）", async () => {
		queryMock.mockResolvedValue({
			data: {
				workspaceMembers: {
					count: 60,
					results: Array.from({ length: 50 }, (_, i) => ({
						id: `wm_${i}`,
						workspaceId: "ws_1",
						userId: `u_${i}`,
						roles: [{ id: "r1", name: "member" }],
					})),
					endKeyset: "keyset_50",
				},
			},
		} as never);

		const page = await fetchWorkspaceMembers("ws_1", { first: 50 });
		expect(page.members).toHaveLength(50);
		expect(page.endKeyset).toBe("keyset_50");
		expect(page.count).toBe(60); // 60 > 50 → 调用方 hasMore=true
	});

	it("末页满页时 count=已加载数（调用方 hasMore=false，消除 endKeyset 误报）", async () => {
		queryMock.mockResolvedValue({
			data: {
				workspaceMembers: {
					count: 30,
					results: Array.from({ length: 30 }, (_, i) => ({
						id: `wm_${i}`,
						workspaceId: "ws_1",
						userId: `u_${i}`,
						roles: [{ id: "r1", name: "member" }],
					})),
					endKeyset: "keyset_30", // 非 null（末条 keyset），但 count=30=已加载 → 无更多
				},
			},
		} as never);

		const page = await fetchWorkspaceMembers("ws_1", { first: 50 });
		expect(page.members).toHaveLength(30);
		expect(page.endKeyset).toBe("keyset_30");
		expect(page.count).toBe(30); // 30 >= 30 → 调用方 hasMore=false（旧 endKeyset 启发式会误报 true）
	});

	it("透传 after 游标到查询变量", async () => {
		queryMock.mockImplementation(({ variables }) => {
			expect(variables!.after).toBe("keyset_prev");
			return Promise.resolve({
				data: {
					workspaceMembers: {
						count: 1,
						results: [
							{
								id: "wm_next",
								workspaceId: "ws_1",
								userId: "u_next",
								roles: [{ id: "r1", name: "member" }],
							},
						],
						endKeyset: "keyset_next",
					},
				},
			} as never);
		});

		const page = await fetchWorkspaceMembers("ws_1", {
			after: "keyset_prev",
		});
		expect(page.members).toHaveLength(1);
		expect(page.endKeyset).toBe("keyset_next");
	});
});

describe("currentUserCanAssignRoles（#1 能力接口：消费 ws.myAbilities 而非角色名推断）", () => {
	it("myAbilities 含 assign_roles → 可分配", () => {
		expect(
			currentUserCanAssignRoles({
				id: "ws_1",
				slug: "s",
				name: "n",
				joinPolicy: "open",
				sponsorshipEnabled: true,
				myAbilities: ["view_workspace", "assign_roles"],
			}),
		).toBe(true);
	});

	it("myAbilities 不含 assign_roles（普通成员）→ 不可分配", () => {
		expect(
			currentUserCanAssignRoles({
				id: "ws_1",
				slug: "s",
				name: "n",
				joinPolicy: "open",
				sponsorshipEnabled: true,
				myAbilities: ["view_workspace", "access_invite_only"],
			}),
		).toBe(false);
	});

	it("myAbilities 缺失 / ws undefined → 不可分配（保守兜底）", () => {
		expect(currentUserCanAssignRoles(undefined)).toBe(false);
		expect(
			currentUserCanAssignRoles({
				id: "ws_1",
				slug: "s",
				name: "n",
				joinPolicy: "open",
				sponsorshipEnabled: true,
			}),
		).toBe(false);
	});
});

describe("currentUserCanUpdateJoinPolicy（#78：myAbilities 门控）", () => {
	it("myAbilities 含 update_join_policy → 可修改加入策略", () => {
		expect(
			currentUserCanUpdateJoinPolicy({
				id: "ws_1",
				slug: "s",
				name: "n",
				joinPolicy: "open",
				sponsorshipEnabled: true,
				myAbilities: ["view_workspace", "update_join_policy"],
			}),
		).toBe(true);
	});

	it("myAbilities 不含 update_join_policy（普通成员）→ 不可修改", () => {
		expect(
			currentUserCanUpdateJoinPolicy({
				id: "ws_1",
				slug: "s",
				name: "n",
				joinPolicy: "open",
				sponsorshipEnabled: true,
				myAbilities: ["view_workspace", "access_invite_only"],
			}),
		).toBe(false);
	});

	it("myAbilities 缺失 / ws undefined → 不可修改（保守兜底）", () => {
		expect(currentUserCanUpdateJoinPolicy(undefined)).toBe(false);
		expect(
			currentUserCanUpdateJoinPolicy({
				id: "ws_1",
				slug: "s",
				name: "n",
				joinPolicy: "open",
				sponsorshipEnabled: true,
			}),
		).toBe(false);
	});
});

describe("updateWorkspaceJoinPolicy（#78：mutation + 跨页缓存刷新）", () => {
	const mutateMock = vi.mocked(client.mutate);
	const refetchMock = vi.mocked(client.refetchQueries);

	const opName = (query: unknown): string | undefined => {
		const q = query as { definitions?: Array<{ name?: { value?: string } }> };
		return q.definitions?.[0]?.name?.value;
	};

	beforeEach(() => {
		mutateMock.mockReset();
		refetchMock.mockReset();
	});

	it("提交 UpdateWorkspace mutation 并携带 id + joinPolicy，成功后刷新 meWorkspaces 缓存", async () => {
		mutateMock.mockImplementation(({ mutation, variables }) => {
			expect(opName(mutation)).toBe("UpdateWorkspace");
			expect(variables).toEqual({
				id: "ws_1",
				input: { joinPolicy: "invite_only" },
			});
			return Promise.resolve({
				data: {
					updateWorkspace: {
						result: {
							id: "ws_1",
							slug: "s",
							name: "n",
							joinPolicy: "invite_only",
							sponsorshipEnabled: true,
						},
						errors: [],
					},
				},
			} as never);
		});
		refetchMock.mockResolvedValue({ data: {} } as never);

		const result = await updateWorkspaceJoinPolicy("ws_1", "invite_only");

		expect(result.joinPolicy).toBe("invite_only");
		// 锁死刷新目标查询（跨页同步契约：#78 review SUGGESTED-3）
		expect(refetchMock).toHaveBeenCalledWith({ include: [ME_WORKSPACES] });
		expect(refetchMock).toHaveBeenCalledTimes(1);
	});

	it("mutation 返回 errors（无 result）→ 抛错且不刷新缓存", async () => {
		mutateMock.mockResolvedValue({
			data: {
				updateWorkspace: {
					result: null,
					errors: [{ message: "forbidden" }],
				},
			},
		} as never);

		await expect(updateWorkspaceJoinPolicy("ws_1", "open")).rejects.toThrow(
			"forbidden",
		);
		expect(refetchMock).not.toHaveBeenCalled();
	});
});
