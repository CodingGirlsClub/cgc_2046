import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, waitFor } from "@testing-library/react";
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
	fetchOnboardingDismissal,
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

describe("session 旗标（KTD4：cgc:onboarding-invite-shown）", () => {
	beforeEach(() => {
		sessionStorage.clear();
	});

	it("默认未展示；markInviteShown 后同 session 读取为真", () => {
		expect(hasInviteShownThisSession()).toBe(false);
		markInviteShown();
		expect(hasInviteShownThisSession()).toBe(true);
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
			expect(() => markInviteShown()).not.toThrow();
			expect(hasInviteShownThisSession()).toBe(false);
		} finally {
			Object.defineProperty(window, "sessionStorage", {
				configurable: true,
				value: real,
			});
		}
	});
});

describe("fetchOnboardingDismissal / dismissOnboardingInvitation（fetchers）", () => {
	beforeEach(() => {
		queryMock.mockReset();
		mutateMock.mockReset();
	});

	it("me 返回拒绝时间戳 → 透传；查询用 ME_ONBOARDING", async () => {
		queryMock.mockResolvedValue({
			data: {
				me: { id: "u1", onboardingInvitationDismissedAt: "2026-08-22T01:00:00Z" },
			},
		});
		await expect(fetchOnboardingDismissal()).resolves.toBe(
			"2026-08-22T01:00:00Z",
		);
		expect(queryMock).toHaveBeenCalledWith({ query: ME_ONBOARDING });
	});

	it("me 为 null（未登录）或字段为 null → null", async () => {
		queryMock.mockResolvedValue({ data: { me: null } });
		await expect(fetchOnboardingDismissal()).resolves.toBeNull();

		queryMock.mockResolvedValue({
			data: { me: { id: "u1", onboardingInvitationDismissedAt: null } },
		});
		await expect(fetchOnboardingDismissal()).resolves.toBeNull();
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
	});

	afterEach(() => {
		cleanup();
	});

	it("初始 loading=true；两源就绪 → 派生态正确、error=null", async () => {
		queryMock.mockResolvedValue({
			data: {
				me: { id: "u1", onboardingInvitationDismissedAt: "2026-08-22T01:00:00Z" },
			},
		});
		fetchMyMcpTokensMock.mockResolvedValue([token({ status: "active" })]);

		const { result } = renderHook(() => useOnboardingState());
		expect(result.current.loading).toBe(true);

		await waitFor(() => expect(result.current.loading).toBe(false));
		expect(result.current).toEqual({
			dismissed: true,
			hasActiveToken: true,
			connected: false,
			loading: false,
			error: null,
		});
	});

	it("me 查询 reject → error 态（布尔全 false，loading=false）", async () => {
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
		});
	});
});
