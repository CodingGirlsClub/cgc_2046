import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { act, cleanup, waitFor } from "@testing-library/react";
import { renderHook } from "@/test-utils";

/**
 * 首公里 onboarding 数据层测试（U2：KTD2 拒绝态服务端持久化 /
 * KTD3 客户端派生零新查询 / KTD4 session 旗标静默降级 / KTD5 消费方 fail-closed）。
 *
 * mock 风格仿 lib/profile.test.ts：vi.mock apollo-client 的 client +
 * vi.mock 数据源模块（./mcp），验证派生矩阵、旗标语义与 hook 三态。
 */

// vi.mock 工厂会被提升（hoist），mock 函数必须用 vi.hoisted 定义
const { queryMock, mutateMock, fetchMyMcpTokensMock } = vi.hoisted(() => ({
	queryMock: vi.fn(),
	mutateMock: vi.fn(),
	fetchMyMcpTokensMock: vi.fn(),
}));

vi.mock("./apollo-client", () => ({
	client: { query: queryMock, mutate: mutateMock },
}));

vi.mock("./mcp", () => ({
	fetchMyMcpTokens: fetchMyMcpTokensMock,
}));

import {
	deriveOnboardingState,
	dismissOnboardingInvitation,
	fetchOnboardingMe,
	hasInviteShownThisSession,
	markInviteShown,
	useOnboardingState,
} from "./onboarding";
import {
	ME_ONBOARDING,
	DISMISS_ONBOARDING_INVITATION,
} from "./graphql/onboarding";
import type { McpTokenItem } from "./mcp";

/** token 测试夹具：默认 active 未使用，按需覆盖 */
function token(over: Partial<McpTokenItem>): McpTokenItem {
	return {
		id: "tok_1",
		name: "我的 Mac",
		lastUsedAt: null,
		revokedAt: null,
		insertedAt: "2026-08-01T10:00:00Z",
		status: "active",
		...over,
	};
}

describe("deriveOnboardingState（R1/R8 派生矩阵）", () => {
	it("无 token + 未拒绝 → 全 false（新成员，弹邀请）", () => {
		expect(deriveOnboardingState([], null)).toEqual({
			dismissed: false,
			hasActiveToken: false,
			connected: false,
		});
	});

	it("全 revoked → 视同未接入（hasActiveToken=false，per R1 回归成员规则）", () => {
		const tokens = [
			token({ status: "revoked", revokedAt: "2026-08-10T00:00:00Z" }),
			token({ id: "tok_2", status: "revoked", revokedAt: "2026-08-11T00:00:00Z" }),
		];
		const s = deriveOnboardingState(tokens, null);
		expect(s.hasActiveToken).toBe(false);
		expect(s.connected).toBe(false);
		expect(s.dismissed).toBe(false);
	});

	it("全 idle_expired → 视同未接入（90 天规则派生态不算接入）", () => {
		const tokens = [token({ status: "idle_expired" })];
		const s = deriveOnboardingState(tokens, null);
		expect(s.hasActiveToken).toBe(false);
		expect(s.connected).toBe(false);
	});

	it("有 active 无 lastUsedAt → 已签发未通联（hasActiveToken=true，connected=false）", () => {
		const s = deriveOnboardingState([token({ status: "active" })], null);
		expect(s.hasActiveToken).toBe(true);
		expect(s.connected).toBe(false);
	});

	it("有 token lastUsedAt != null → connected=true（R8：首次调用后卡消失）", () => {
		const s = deriveOnboardingState(
			[token({ status: "active", lastUsedAt: "2026-08-20T08:00:00Z" })],
			null,
		);
		expect(s.connected).toBe(true);
		expect(s.hasActiveToken).toBe(true);
	});

	it("connected 只看 lastUsedAt：revoked 但历史用过 → connected=true（曾达成首联）", () => {
		const s = deriveOnboardingState(
			[
				token({
					status: "revoked",
					revokedAt: "2026-08-21T00:00:00Z",
					lastUsedAt: "2026-08-15T00:00:00Z",
				}),
			],
			null,
		);
		expect(s.hasActiveToken).toBe(false);
		expect(s.connected).toBe(true);
	});

	it("dismissedAt 非 null → dismissed=true（KTD2 拒绝态）", () => {
		const s = deriveOnboardingState([], "2026-08-22T01:00:00Z");
		expect(s.dismissed).toBe(true);
	});
});

describe("session 旗标（KTD4：cgc:onboarding-invite-shown:{userId}）", () => {
	beforeEach(() => {
		sessionStorage.clear();
	});

	it("默认未展示；markInviteShown 后同 session 同用户读取为真", () => {
		expect(hasInviteShownThisSession("u1")).toBe(false);
		markInviteShown("u1");
		expect(hasInviteShownThisSession("u1")).toBe(true);
	});

	it("按 userId 命名空间：A 的已展示不抑制 B（共享机器同 tab 换账号）", () => {
		markInviteShown("u_a");
		expect(hasInviteShownThisSession("u_a")).toBe(true);
		expect(hasInviteShownThisSession("u_b")).toBe(false);
	});

	it("userId 缺失：读落 false、写为 no-op（fail toward showing，不写全局旗标）", () => {
		expect(hasInviteShownThisSession(null)).toBe(false);
		markInviteShown(null);
		expect(sessionStorage.length).toBe(0);
	});

	it("sessionStorage 抛错（隐私模式）：写不 throw、读为假", () => {
		const real = window.sessionStorage;
		const throwing: Storage = {
			get length(): number {
				throw new Error("private mode");
			},
			clear: () => {
				throw new Error("private mode");
			},
			getItem: () => {
				throw new Error("private mode");
			},
			key: () => {
				throw new Error("private mode");
			},
			removeItem: () => {
				throw new Error("private mode");
			},
			setItem: () => {
				throw new Error("private mode");
			},
		};
		Object.defineProperty(window, "sessionStorage", {
			configurable: true,
			value: throwing,
		});
		try {
			expect(() => markInviteShown("u1")).not.toThrow();
			expect(hasInviteShownThisSession("u1")).toBe(false);
		} finally {
			Object.defineProperty(window, "sessionStorage", {
				configurable: true,
				value: real,
			});
		}
	});
});

describe("fetchOnboardingMe / dismissOnboardingInvitation（fetchers）", () => {
	beforeEach(() => {
		queryMock.mockReset();
		mutateMock.mockReset();
	});

	it("me 返回 onboarding 片段（id + 拒绝时间戳）→ 透传；查询用 ME_ONBOARDING", async () => {
		const me = {
			id: "u1",
			onboardingInvitationDismissedAt: "2026-08-22T01:00:00Z",
		};
		queryMock.mockResolvedValue({ data: { me } });
		await expect(fetchOnboardingMe()).resolves.toEqual(me);
		// network-only 钉住：拒绝态同 session 内不得读缓存旧值（隔壁 review HIGH）
		expect(queryMock).toHaveBeenCalledWith({
			query: ME_ONBOARDING,
			fetchPolicy: "network-only",
		});
	});

	it("me 为 null（未登录）→ null", async () => {
		queryMock.mockResolvedValue({ data: { me: null } });
		await expect(fetchOnboardingMe()).resolves.toBeNull();
	});

	it("dismissOnboardingInvitation 调 DISMISS_ONBOARDING_INVITATION mutation", async () => {
		mutateMock.mockResolvedValue({
			data: {
				dismissOnboardingInvitation: {
					id: "u1",
					onboardingInvitationDismissedAt: "2026-08-22T01:00:00Z",
				},
			},
		});
		await expect(dismissOnboardingInvitation()).resolves.toBeUndefined();
		expect(mutateMock).toHaveBeenCalledWith({
			mutation: DISMISS_ONBOARDING_INVITATION,
		});
	});
});

describe("useOnboardingState（KTD5：loading/error fail-closed）", () => {
	beforeEach(() => {
		queryMock.mockReset();
		fetchMyMcpTokensMock.mockReset();
		sessionStorage.clear();
	});

	afterEach(() => {
		cleanup();
	});

	it("初始 loading=true；两源就绪 → 派生态正确、error=null、userId 透传", async () => {
		queryMock.mockResolvedValue({
			data: {
				me: { id: "u1", onboardingInvitationDismissedAt: "2026-08-22T01:00:00Z" },
			},
		});
		fetchMyMcpTokensMock.mockResolvedValue([token({ status: "active" })]);

		const { result } = renderHook(() => useOnboardingState());
		expect(result.current.loading).toBe(true);

		await waitFor(() => expect(result.current.loading).toBe(false));
		expect(result.current).toMatchObject({
			dismissed: true,
			hasActiveToken: true,
			connected: false,
			loading: false,
			error: null,
			userId: "u1",
			inviteShownThisSession: false,
		});
		// tokens 原始列表透传（向导页 hasTokenHistory 由此派生，不二次 fetch）
		expect(result.current.tokens).toHaveLength(1);
		expect(typeof result.current.reload).toBe("function");
	});

	it("userId 就绪时快照 KTD4 旗标：本 session 该用户已展示 → inviteShownThisSession=true", async () => {
		sessionStorage.setItem("cgc:onboarding-invite-shown:u1", "1");
		queryMock.mockResolvedValue({
			data: { me: { id: "u1", onboardingInvitationDismissedAt: null } },
		});
		fetchMyMcpTokensMock.mockResolvedValue([]);

		const { result } = renderHook(() => useOnboardingState());
		await waitFor(() => expect(result.current.loading).toBe(false));
		expect(result.current.userId).toBe("u1");
		expect(result.current.inviteShownThisSession).toBe(true);
	});

	it("me 为 null（未登录）→ userId=null、旗标 false（fail toward showing）", async () => {
		queryMock.mockResolvedValue({ data: { me: null } });
		fetchMyMcpTokensMock.mockResolvedValue([]);

		const { result } = renderHook(() => useOnboardingState());
		await waitFor(() => expect(result.current.loading).toBe(false));
		expect(result.current.error).toBeNull();
		expect(result.current.userId).toBeNull();
		expect(result.current.inviteShownThisSession).toBe(false);
	});

	it("me 查询 reject → error 态（布尔全 false，loading=false，userId=null）", async () => {
		queryMock.mockRejectedValue(new Error("network down"));
		fetchMyMcpTokensMock.mockResolvedValue([
			token({ status: "active", lastUsedAt: "2026-08-20T08:00:00Z" }),
		]);

		const { result } = renderHook(() => useOnboardingState());
		await waitFor(() => expect(result.current.loading).toBe(false));
		expect(result.current.error).toBeInstanceOf(Error);
		expect(result.current).toMatchObject({
			dismissed: false,
			hasActiveToken: false,
			connected: false,
			userId: null,
			inviteShownThisSession: false,
		});
	});

	it("fetchMyMcpTokens reject → error 态", async () => {
		queryMock.mockResolvedValue({ data: { me: null } });
		fetchMyMcpTokensMock.mockRejectedValue(new Error("tokens failed"));

		const { result } = renderHook(() => useOnboardingState());
		await waitFor(() => expect(result.current.loading).toBe(false));
		expect(result.current.error).toBeInstanceOf(Error);
		expect(result.current).toMatchObject({
			dismissed: false,
			hasActiveToken: false,
			connected: false,
			userId: null,
			inviteShownThisSession: false,
		});
	});

	it("reload 重试：error 态 → reload() → 两源重拉恢复（入口页内联 alert 的重试按钮）", async () => {
		queryMock.mockRejectedValueOnce(new Error("network down"));
		fetchMyMcpTokensMock.mockResolvedValue([]);

		const { result } = renderHook(() => useOnboardingState());
		await waitFor(() => expect(result.current.error).toBeInstanceOf(Error));

		queryMock.mockResolvedValue({
			data: { me: { id: "u1", onboardingInvitationDismissedAt: null } },
		});
		act(() => result.current.reload());

		await waitFor(() => expect(result.current.loading).toBe(false));
		expect(result.current).toMatchObject({
			error: null,
			userId: "u1",
			tokens: [],
		});
		expect(queryMock).toHaveBeenCalledTimes(2);
	});
});

describe("useOnboardingState refreshSilently（P2 等待首联态静默刷新）", () => {
	beforeEach(() => {
		queryMock.mockReset();
		fetchMyMcpTokensMock.mockReset();
		sessionStorage.clear();
	});

	afterEach(() => {
		cleanup();
	});

	it("成功：拉取期间 loading 保持 false（卡不闪烁），新数据原地落地", async () => {
		queryMock.mockResolvedValue({
			data: { me: { id: "u1", onboardingInvitationDismissedAt: null } },
		});
		fetchMyMcpTokensMock.mockResolvedValue([token({ status: "active" })]);

		const { result } = renderHook(() => useOnboardingState());
		await waitFor(() => expect(result.current.loading).toBe(false));
		expect(result.current.connected).toBe(false);

		// 宿主完成首联：下一轮拉取 lastUsedAt 非空
		fetchMyMcpTokensMock.mockResolvedValue([
			token({ status: "active", lastUsedAt: "2026-08-22T20:00:00Z" }),
		]);
		act(() => result.current.refreshSilently());
		// 静默轮次不置 loading（区别 reload）——拉取期间旧数据保持展示
		expect(result.current.loading).toBe(false);

		await waitFor(() => expect(result.current.connected).toBe(true));
		expect(result.current.error).toBeNull();
		expect(fetchMyMcpTokensMock).toHaveBeenCalledTimes(2);
	});

	it("失败：保留上次成功快照（瞬时网络错误不经 fail-closed 撤卡），error 不置位", async () => {
		queryMock.mockResolvedValue({
			data: { me: { id: "u1", onboardingInvitationDismissedAt: null } },
		});
		fetchMyMcpTokensMock.mockResolvedValue([token({ status: "active" })]);

		const { result } = renderHook(() => useOnboardingState());
		await waitFor(() => expect(result.current.loading).toBe(false));
		expect(result.current.hasActiveToken).toBe(true);

		// 静默轮次两源之一拒绝
		queryMock.mockRejectedValueOnce(new Error("flaky network"));
		act(() => result.current.refreshSilently());
		await waitFor(() => expect(queryMock).toHaveBeenCalledTimes(2));
		// 等拒绝链 settle（catch 在微任务里跑完）再断言状态原样保持
		await act(async () => {});

		expect(result.current).toMatchObject({
			dismissed: false,
			hasActiveToken: true,
			connected: false,
			loading: false,
			error: null,
			userId: "u1",
		});
		expect(result.current.tokens).toHaveLength(1);
	});

	it("reload 复位静默标记：静默轮后再 reload，失败仍进 error 态（fail-closed 不被污染）", async () => {
		queryMock.mockResolvedValue({
			data: { me: { id: "u1", onboardingInvitationDismissedAt: null } },
		});
		fetchMyMcpTokensMock.mockResolvedValue([]);

		const { result } = renderHook(() => useOnboardingState());
		await waitFor(() => expect(result.current.loading).toBe(false));

		// 先静默一轮（置位 silent 标记）
		act(() => result.current.refreshSilently());
		await waitFor(() => expect(queryMock).toHaveBeenCalledTimes(2));

		// reload 必须复位静默标记：其失败照常 fail-closed
		queryMock.mockRejectedValueOnce(new Error("network down"));
		act(() => result.current.reload());
		await waitFor(() => expect(result.current.error).toBeInstanceOf(Error));
		expect(result.current).toMatchObject({
			hasActiveToken: false,
			userId: null,
			tokens: [],
		});
	});
});
