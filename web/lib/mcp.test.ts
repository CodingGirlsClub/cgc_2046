import { describe, it, expect } from "vitest";
import {
	mapMcpToken,
	buildConfigSnippet,
	MCP_CLIENTS,
	MCP_SERVER_URL,
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

describe("buildConfigSnippet（research §5b 三客户端差异）", () => {
	const url = "https://cgc.example.com/mcp";

	it("openclacky：mcpServers + type http + 手动替换占位符 + description", () => {
		const snippet = buildConfigSnippet("openclacky", url);
		const parsed = JSON.parse(snippet);
		expect(parsed.mcpServers.cgc.type).toBe("http");
		expect(parsed.mcpServers.cgc.url).toBe(url);
		expect(parsed.mcpServers.cgc.headers.Authorization).toBe(
			"Bearer <CGC_TOKEN>",
		);
		expect(parsed.mcpServers.cgc.description).toBe(
			"CGC-2046 platform capabilities",
		);
	});

	it("omp：mcpServers + type http + ${CGC_TOKEN} 环境变量插值", () => {
		const parsed = JSON.parse(buildConfigSnippet("omp", url));
		expect(parsed.mcpServers.cgc.type).toBe("http");
		expect(parsed.mcpServers.cgc.url).toBe(url);
		expect(parsed.mcpServers.cgc.headers.Authorization).toBe(
			"Bearer ${CGC_TOKEN}",
		);
		// omp 片段无顶层 mcp 键（与 opencode 区分）
		expect(parsed.mcp).toBeUndefined();
	});

	it("opencode：顶层 mcp 键 + type remote + oauth:false + {env:CGC_TOKEN}", () => {
		const parsed = JSON.parse(buildConfigSnippet("opencode", url));
		expect(parsed.mcp.cgc.type).toBe("remote");
		expect(parsed.mcp.cgc.url).toBe(url);
		expect(parsed.mcp.cgc.oauth).toBe(false);
		expect(parsed.mcp.cgc.headers.Authorization).toBe(
			"Bearer {env:CGC_TOKEN}",
		);
		// opencode 片段无 mcpServers 键
		expect(parsed.mcpServers).toBeUndefined();
	});

	it("默认 URL 取 NEXT_PUBLIC_MCP_URL 或 localhost:4000/mcp", () => {
		expect(MCP_SERVER_URL).toMatch(/\/mcp$/);
		expect(buildConfigSnippet("omp")).toContain(MCP_SERVER_URL);
	});

	it("三客户端片段均为合法 JSON 且不含真实 token 形状", () => {
		for (const { key } of MCP_CLIENTS) {
			const snippet = buildConfigSnippet(key, url);
			expect(() => JSON.parse(snippet)).not.toThrow();
			// D-D10：片段内只允许占位符，不出现真实 token 前缀
			expect(snippet).not.toMatch(/cgc_[A-Za-z0-9_-]{20,}/);
		}
	});
});
