import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import type { MutationError } from "./shared";

/**
 * 切片 D（#44）MCP 连接 token GraphQL 契约（对齐 backend graphql_schema.ex 手写三入口）。
 *
 * 与登录 token 是两种凭证：本契约管理的是 MCP 客户端（OpenClacky 及用户自配的
 * MCP 客户端）调 /mcp 端点用的 Bearer token，绑用户不绑工作区（D13）。
 *
 * 安全约束（D-D4/D-D10）：
 * - 明文仅 createMcpToken 响应的 plainToken 一次性返回；McpToken 类型不含明文/hash
 * - 撤销 = 置 revokedAt（保留审计行，不删除）
 */

/* ---------------- 类型 ---------------- */

/** 连接 token 类型（ADR-0022）：TERMINAL 用户自建；LEARNING_HOST 配对签发给本机 Host，只能调学习工具 */
export type McpTokenKind = "TERMINAL" | "LEARNING_HOST";

export interface McpToken {
	id: string;
	name: string;
	kind: McpTokenKind;
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
			kind
			lastUsedAt
			revokedAt
			insertedAt
		}
	}
`;

/** createMcpToken：签发连接 token（明文仅本次返回；不传 kind 即 TERMINAL） */
export const CREATE_MCP_TOKEN: TypedDocumentNode<
	{ createMcpToken: CreateMcpTokenPayload },
	{ name: string; kind?: McpTokenKind }
> = gql`
	mutation CreateMcpToken($name: String!, $kind: McpTokenKind) {
		createMcpToken(name: $name, kind: $kind) {
			result {
				id
				name
				kind
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
			kind
			lastUsedAt
			revokedAt
			insertedAt
		}
	}
`;
