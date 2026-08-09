import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import type { MutationError } from "./shared";

/**
 * 切片 D（#44）MCP 连接 token GraphQL 契约（对齐 backend graphql_schema.ex 手写三入口）。
 *
 * 与登录 token 是两种凭证：本契约管理的是 MCP 客户端（OpenClacky/omp/opencode）
 * 调 /mcp 端点用的 Bearer token，绑用户不绑工作区（D13）。
 *
 * 安全约束（D-D4/D-D10）：
 * - 明文仅 createMcpToken 响应的 plainToken 一次性返回；McpToken 类型不含明文/hash
 * - 撤销 = 置 revokedAt（保留审计行，不删除）
 */

/* ---------------- 类型 ---------------- */

export interface McpToken {
	id: string;
	name: string;
	lastUsedAt: string | null;
	revokedAt: string | null;
	insertedAt: string;
}

/** createMcpToken 返回包装：result + 一次性明文 + 结构化错误 */
export interface CreateMcpTokenPayload {
	result: McpToken | null;
	plainToken: string | null;
	errors: MutationError[];
}

/* ---------------- Query / Mutation TypedDocumentNode ---------------- */

/** myMcpTokens：当前用户 token 列表（新→旧，policy 仅见本人） */
export const MY_MCP_TOKENS: TypedDocumentNode<
	{ myMcpTokens: McpToken[] },
	Record<string, never>
> = gql`
	query MyMcpTokens {
		myMcpTokens {
			id
			name
			lastUsedAt
			revokedAt
			insertedAt
		}
	}
`;

/** createMcpToken：签发连接 token（明文仅本次返回） */
export const CREATE_MCP_TOKEN: TypedDocumentNode<
	{ createMcpToken: CreateMcpTokenPayload },
	{ name: string }
> = gql`
	mutation CreateMcpToken($name: String!) {
		createMcpToken(name: $name) {
			result {
				id
				name
				lastUsedAt
				revokedAt
				insertedAt
			}
			plainToken
			errors {
				message
				code
			}
		}
	}
`;

/** revokeMcpToken：撤销连接 token（仅本人；他人/不存在一律 not_found） */
export const REVOKE_MCP_TOKEN: TypedDocumentNode<
	{ revokeMcpToken: McpToken },
	{ id: string }
> = gql`
	mutation RevokeMcpToken($id: ID!) {
		revokeMcpToken(id: $id) {
			id
			name
			lastUsedAt
			revokedAt
			insertedAt
		}
	}
`;
