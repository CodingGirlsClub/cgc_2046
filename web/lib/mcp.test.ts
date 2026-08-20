import { describe, it, expect } from "vitest";
import { mapMcpToken } from "./mcp";
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
