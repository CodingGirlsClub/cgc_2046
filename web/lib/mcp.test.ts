import { describe, it, expect, vi, beforeEach } from "vitest";

vi.mock("./apollo-client", () => ({
	client: { query: vi.fn(), mutate: vi.fn() },
}));

import { client } from "./apollo-client";
import { mapMcpToken, issueMcpToken } from "./mcp";
import { CREATE_MCP_TOKEN, type McpToken } from "./graphql/mcp-token";

const BASE: McpToken = {
	id: "tok_1",
	name: "我的 Mac",
	kind: "TERMINAL",
	lastUsedAt: null,
	revokedAt: null,
	insertedAt: "2026-08-08T10:00:00Z",
};

describe("issueMcpToken", () => {
	const mutate = vi.mocked(client.mutate);

	beforeEach(() => mutate.mockReset());

	it("不传 kind（既有调用方）→ 变量里没有 kind，由后端按 TERMINAL 签发", async () => {
		mutate.mockResolvedValue({
			data: { createMcpToken: { result: BASE, plainToken: "cgc_x", errors: [] } },
		});

		await issueMcpToken("我的 Mac");

		expect(mutate).toHaveBeenCalledWith({ mutation: CREATE_MCP_TOKEN, variables: { name: "我的 Mac" } });
	});

	it("kind: LEARNING_HOST 透传给签发", async () => {
		mutate.mockResolvedValue({
			data: {
				createMcpToken: {
					result: { ...BASE, kind: "LEARNING_HOST" },
					plainToken: "cgch_x",
					errors: [],
				},
			},
		});

		const { plainToken } = await issueMcpToken("我的 Mac", "LEARNING_HOST");

		expect(mutate).toHaveBeenCalledWith({
			mutation: CREATE_MCP_TOKEN,
			variables: { name: "我的 Mac", kind: "LEARNING_HOST" },
		});
		expect(plainToken).toBe("cgch_x");
	});

	it("达有效 token 上限 → errors.mcp_token_limit_reached；其余失败 → 通用文案", async () => {
		mutate.mockResolvedValueOnce({
			data: {
				createMcpToken: {
					result: null,
					plainToken: null,
					errors: [{ message: "active connection token limit reached", code: "mcp_token_limit_reached" }],
				},
			},
		});
		await expect(issueMcpToken("我的 Mac", "LEARNING_HOST")).rejects.toThrow(
			"errors.mcp_token_limit_reached",
		);

		mutate.mockResolvedValueOnce({
			data: {
				createMcpToken: { result: null, plainToken: null, errors: [{ message: "is required", code: "required" }] },
			},
		});
		await expect(issueMcpToken("")).rejects.toThrow("errors.issueMcpTokenFailed");
	});
});

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

	it("kind 原样带出（「已配对的电脑」据此只列学习凭证）", () => {
		expect(mapMcpToken(BASE).kind).toBe("TERMINAL");
		expect(mapMcpToken({ ...BASE, kind: "LEARNING_HOST" }).kind).toBe("LEARNING_HOST");
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
