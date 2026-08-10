import { client } from "./apollo-client";
import {
	MY_MCP_TOKENS,
	CREATE_MCP_TOKEN,
	REVOKE_MCP_TOKEN,
	type McpToken,
} from "./graphql/mcp-token";

/**
 * 切片 D（#44）MCP 连接 token 数据源。
 *
 * 唯一真实路径：GraphQL（graphql/mcp-token.ts 契约）。
 */

/* ---------------- Token 数据 ---------------- */

export type McpTokenStatus = "active" | "revoked";

export interface McpTokenItem {
	id: string;
	name: string;
	lastUsedAt: string | null;
	revokedAt: string | null;
	insertedAt: string;
	status: McpTokenStatus;
}

export function mapMcpToken(t: McpToken): McpTokenItem {
	return {
		id: t.id,
		name: t.name,
		lastUsedAt: t.lastUsedAt ?? null,
		revokedAt: t.revokedAt ?? null,
		insertedAt: t.insertedAt,
		status: t.revokedAt ? "revoked" : "active",
	};
}

/** 当前用户的连接 token 列表（新→旧） */
export async function fetchMyMcpTokens(): Promise<McpTokenItem[]> {
	const { data } = await client.query({ query: MY_MCP_TOKENS });
	return (data?.myMcpTokens ?? []).map(mapMcpToken);
}

/** 签发连接 token；明文仅本次返回，调用方负责一次性展示 */
export async function issueMcpToken(
	name: string,
): Promise<{ token: McpTokenItem; plainToken: string }> {
	const { data } = await client.mutate({
		mutation: CREATE_MCP_TOKEN,
		variables: { name },
	});
	const payload = data?.createMcpToken;
	if (!payload?.result || !payload.plainToken) {
		const msg = payload?.errors?.[0]?.message ?? "签发失败，请稍后重试";
		throw new Error(msg);
	}
	return { token: mapMcpToken(payload.result), plainToken: payload.plainToken };
}

/** 撤销连接 token（置 revokedAt，保留审计行） */
export async function revokeMcpToken(id: string): Promise<McpTokenItem> {
	const { data } = await client.mutate({
		mutation: REVOKE_MCP_TOKEN,
		variables: { id },
	});
	const result = data?.revokeMcpToken;
	if (!result) {
		throw new Error("撤销失败，请稍后重试");
	}
	return mapMcpToken(result);
}
