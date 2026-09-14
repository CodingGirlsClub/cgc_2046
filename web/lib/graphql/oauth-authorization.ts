import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";

/**
 * U5（KTD3）OAuth 授权 GraphQL 契约（对齐 backend graphql_schema.ex 手写两入口）。
 *
 * 与 `mcp-token.ts` 是两类凭证：连接 token 是手工粘贴的 Bearer 凭证，本契约管理的是
 * 宿主经平台 OAuth 授权拿到的凭证（同样绑用户、不绑工作区）。web 侧「已接入」判定
 * 由两者共同支撑（见 lib/onboarding.ts）。
 *
 * 安全约束：撤销 = 整链撤销 + 撤回同意行（保留链头审计行）；协议端点不可经此契约触达。
 */

/* ---------------- 类型 ---------------- */

/** 授权状态（后端派生：令牌链活跃性 + 同意行） */
export type OauthAuthorizationStatus =
	| "active"
	| "idle_expired"
	| "revoked"
	| "pending";

export interface OauthAuthorization {
	clientId: string;
	/** 客户端显示名（client 行缺失时为 null，前端降级展示） */
	clientName: string | null;
	scope: string;
	/** 授权时间（同意行撤回后为 null——撤销后的审计回看） */
	grantedAt: string | null;
	/** 最近一次 MCP 调用时间（与连接 token 的 lastUsedAt 同源语义） */
	lastUsedAt: string | null;
	status: OauthAuthorizationStatus;
}

/* ---------------- Query / Mutation TypedDocumentNode ---------------- */

/** myOauthAuthorizations：当前用户授权列表（新→旧，仅本人） */
export const MY_OAUTH_AUTHORIZATIONS: TypedDocumentNode<
	{ myOauthAuthorizations: OauthAuthorization[] },
	Record<string, never>
> = gql`
	query MyOauthAuthorizations {
		myOauthAuthorizations {
			clientId
			clientName
			scope
			grantedAt
			lastUsedAt
			status
		}
	}
`;

/** revokeOauthAuthorization：撤销一条授权（仅本人；他人/不存在 clientId 一律 not_found） */
export const REVOKE_OAUTH_AUTHORIZATION: TypedDocumentNode<
	{ revokeOauthAuthorization: OauthAuthorization },
	{ clientId: string }
> = gql`
	mutation RevokeOauthAuthorization($clientId: ID!) {
		revokeOauthAuthorization(clientId: $clientId) {
			clientId
			clientName
			scope
			grantedAt
			lastUsedAt
			status
		}
	}
`;
