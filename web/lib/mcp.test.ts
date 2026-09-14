import { describe, it, expect, vi, beforeEach } from "vitest";
import {
	fetchMyOauthAuthorizations,
	mapMcpToken,
	revokeOauthAuthorization,
} from "./mcp";
import type { McpToken } from "./graphql/mcp-token";

const BASE: McpToken = {
	id: "tok_1",
	name: "我的 Mac",
	lastUsedAt: null,
	revokedAt: null,
	insertedAt: "2026-08-08T10:00:00Z",
};

describe("mapMcpToken", () => {
	it("revokedAt 为空 → active", () => {
		const item = mapMcpToken(BASE);
		expect(item.status).toBe("active");
		expect(item.lastUsedAt).toBeNull();
		expect(item.revokedAt).toBeNull();
	});

	it("revokedAt 非空 → revoked", () => {
		const item = mapMcpToken({ ...BASE, revokedAt: "2026-08-08T11:00:00Z" });
		expect(item.status).toBe("revoked");
		expect(item.revokedAt).toBe("2026-08-08T11:00:00Z");
	});
});

const DAY_MS = 86_400_000;
/** daysAgo 天前的 UTC ISO 串（相对 Date.now()，随跑测时间漂移安全） */
const isoDaysAgo = (daysAgo: number) =>
	new Date(Date.now() - daysAgo * DAY_MS).toISOString();

describe("mapMcpToken 闲置过期派生（#226，对齐 backend 90 天窗口）", () => {
	it("从未使用，insertedAt -91 天 → idle_expired", () => {
		const item = mapMcpToken({ ...BASE, insertedAt: isoDaysAgo(91) });
		expect(item.status).toBe("idle_expired");
	});

	it("边界：恰 -90 天 → idle_expired（>= 90 即过期，对齐 backend idle_expired?/1）", () => {
		const item = mapMcpToken({ ...BASE, insertedAt: isoDaysAgo(90) });
		expect(item.status).toBe("idle_expired");
	});

	it("-89 天 → active（未到 90 天窗口）", () => {
		const item = mapMcpToken({ ...BASE, insertedAt: isoDaysAgo(89) });
		expect(item.status).toBe("active");
	});

	it("锚点取 lastUsedAt：insertedAt -100 天 + lastUsedAt -1 天 → active", () => {
		const item = mapMcpToken({
			...BASE,
			insertedAt: isoDaysAgo(100),
			lastUsedAt: isoDaysAgo(1),
		});
		expect(item.status).toBe("active");
	});

	it("revokedAt 优先于闲置判定：旧 anchor + 已撤销 → revoked", () => {
		const item = mapMcpToken({
			...BASE,
			insertedAt: isoDaysAgo(120),
			revokedAt: isoDaysAgo(5),
		});
		expect(item.status).toBe("revoked");
	});
});

/* ---------------- U5：OAuth 授权数据源 ---------------- */

const { queryMock, mutateMock } = vi.hoisted(() => ({
	queryMock: vi.fn(),
	mutateMock: vi.fn(),
}));

vi.mock("./apollo-client", () => ({
	client: { query: queryMock, mutate: mutateMock },
}));

const { MY_OAUTH_AUTHORIZATIONS, REVOKE_OAUTH_AUTHORIZATION } = await import(
	"./graphql/oauth-authorization"
);

describe("授权 fetchers（契约接线）", () => {
	beforeEach(() => {
		queryMock.mockReset();
		mutateMock.mockReset();
	});

	it("fetchMyOauthAuthorizations：network-only 读 MY_OAUTH_AUTHORIZATIONS，空列表降级为 []", async () => {
		queryMock.mockResolvedValueOnce({ data: { myOauthAuthorizations: null } });
		await expect(fetchMyOauthAuthorizations()).resolves.toEqual([]);
		expect(queryMock).toHaveBeenCalledWith({
			query: MY_OAUTH_AUTHORIZATIONS,
			fetchPolicy: "network-only",
		});

		queryMock.mockResolvedValueOnce({ data: { myOauthAuthorizations: [] } });
		await expect(fetchMyOauthAuthorizations()).resolves.toEqual([]);
	});

	it("revokeOauthAuthorization：按 clientId 调 REVOKE_OAUTH_AUTHORIZATION 并返回归一结果", async () => {
		mutateMock.mockResolvedValue({
			data: {
				revokeOauthAuthorization: {
					clientId: "cli_1",
					clientName: "CGC 学习空间",
					scope: "mcp",
					grantedAt: null,
					lastUsedAt: "2026-09-15T11:00:00Z",
					status: "revoked",
				},
			},
		});

		await expect(revokeOauthAuthorization("cli_1")).resolves.toEqual({
			clientId: "cli_1",
			clientName: "CGC 学习空间",
			scope: "mcp",
			grantedAt: null,
			lastUsedAt: "2026-09-15T11:00:00Z",
			status: "revoked",
		});
		expect(mutateMock).toHaveBeenCalledWith({
			mutation: REVOKE_OAUTH_AUTHORIZATION,
			variables: { clientId: "cli_1" },
		});
	});

	it("revokeOauthAuthorization：无 result（GraphQL 错误已抛出/空载荷）→ 抛文案键错误", async () => {
		mutateMock.mockResolvedValue({ data: { revokeOauthAuthorization: null } });
		await expect(revokeOauthAuthorization("cli_1")).rejects.toThrow(
			"errors.revokeOauthAuthorizationFailed",
		);
	});
});
