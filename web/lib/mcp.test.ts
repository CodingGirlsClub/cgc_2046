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
