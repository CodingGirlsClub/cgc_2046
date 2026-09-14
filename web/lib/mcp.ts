import { client } from "./apollo-client";
import {
	MY_MCP_TOKENS,
	CREATE_MCP_TOKEN,
	REVOKE_MCP_TOKEN,
	type McpToken,
} from "./graphql/mcp-token";
import {
	MY_OAUTH_AUTHORIZATIONS,
	REVOKE_OAUTH_AUTHORIZATION,
	type OauthAuthorization,
} from "./graphql/oauth-authorization";

/**
 * 切片 D（#44）MCP 连接 token 数据源 + U5（KTD3）OAuth 授权数据源。
 *
 * 两类凭证同一数据源：都绑用户不绑工作区，且都进首公里「已接入」判定
 * （见 lib/onboarding.ts 的 deriveOnboardingState）。
 *
 * 唯一真实路径：GraphQL（graphql/mcp-token.ts 与 graphql/oauth-authorization.ts 契约）。
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

/* ---------------- OAuth 授权（U5，KTD3） ---------------- */

/* 授权载荷直接使用 GraphQL 契约类型 `OauthAuthorization`：曾有一层恒等 DTO 与
   null 归一包装，属无效防线（Absinthe 对可空字段恒返回 null），已删除。 */

/** 当前用户的 OAuth 授权列表（新→旧）；network-only——撤销后不得读缓存旧列表 */
export async function fetchMyOauthAuthorizations(): Promise<
	OauthAuthorization[]
> {
	const { data } = await client.query({
		query: MY_OAUTH_AUTHORIZATIONS,
		fetchPolicy: "network-only",
	});
	return data?.myOauthAuthorizations ?? [];
}

/** 撤销一条授权（整链 + 撤回同意行；仅本人） */
export async function revokeOauthAuthorization(
	clientId: string,
): Promise<OauthAuthorization> {
	const { data } = await client.mutate({
		mutation: REVOKE_OAUTH_AUTHORIZATION,
		variables: { clientId },
	});
	const result = data?.revokeOauthAuthorization;
	if (!result) {
		throw new Error("errors.revokeOauthAuthorizationFailed");
	}
	return result;
}
