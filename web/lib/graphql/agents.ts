import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";

/**
 * plan 020 U2.1 Agents 工作面活动流 GraphQL 契约。
 *
 * 后端手写查询（graphql_schema.ex）：myWorkspaceToolCalls(workspaceId, first) →
 * [WorkspaceToolCall!]!；policy = workspace 成员 + 仅本人（非成员 forbidden）。
 * 返回摘要字段（tool/status/latencyMs/insertedAt/errorMessage），**无 params**
 * （隐私最小面，即便 params 已 redact 也不返回）。
 */

export interface WorkspaceToolCall {
	id: string;
	tool: string;
	status: string;
	latencyMs: number | null;
	insertedAt: string;
	errorMessage: string | null;
}

/** 本人 MCP 工具调用活动流（新→旧，first 默认 50） */
export const MY_WORKSPACE_TOOL_CALLS: TypedDocumentNode<
	{ myWorkspaceToolCalls: WorkspaceToolCall[] },
	{ workspaceId: string; first?: number }
> = gql`
	query MyWorkspaceToolCalls($workspaceId: ID!, $first: Int) {
		myWorkspaceToolCalls(workspaceId: $workspaceId, first: $first) {
			id
			tool
			status
			latencyMs
			insertedAt
			errorMessage
		}
	}
`;
