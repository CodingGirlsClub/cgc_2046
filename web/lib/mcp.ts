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

export type McpTokenStatus = "active" | "idle_expired" | "revoked";

export interface McpTokenItem {
	id: string;
	name: string;
	lastUsedAt: string | null;
	revokedAt: string | null;
	insertedAt: string;
	status: McpTokenStatus;
}

/**
 * 闲置过期判定（#226，本地派生）：连续 90 天未使用即失效——与 backend
 * `Cgc2046.Mcp.Token @idle_expiry_days`（token.ex:23）对齐，双侧改须同步。
 * UTC 绝对毫秒差取整天数（>= 90），防本地时区日历计算 ±1 天漂移；
 * 锚点 = lastUsedAt ?? insertedAt，与 backend idle_expired?/1 一致。
 */
const IDLE_EXPIRY_DAYS = 90;
const DAY_MS = 86_400_000;

export function mapMcpToken(t: McpToken): McpTokenItem {
	const anchor = t.lastUsedAt ?? t.insertedAt;
	const idleDays = Math.floor((Date.now() - new Date(anchor).getTime()) / DAY_MS);
	const idleExpired = !t.revokedAt && idleDays >= IDLE_EXPIRY_DAYS;
	return {
		id: t.id,
		name: t.name,
		lastUsedAt: t.lastUsedAt ?? null,
		revokedAt: t.revokedAt ?? null,
		insertedAt: t.insertedAt,
		status: t.revokedAt ? "revoked" : idleExpired ? "idle_expired" : "active",
	};
}

/** 当前用户的连接 token 列表（新→旧）；network-only——签发/撤销后不得读缓存旧列表 */
export async function fetchMyMcpTokens(): Promise<McpTokenItem[]> {
	const { data } = await client.query({
		query: MY_MCP_TOKENS,
		fetchPolicy: "network-only",
	});
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
		throw new Error("errors.issueMcpTokenFailed");
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
		throw new Error("errors.revokeMcpTokenFailed");
	}
	return mapMcpToken(result);
}
