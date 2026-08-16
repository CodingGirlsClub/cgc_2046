import { client } from "./apollo-client";
import {
	MY_WORKSPACE_TOOL_CALLS,
	type WorkspaceToolCall,
} from "./graphql/agents";

/**
 * plan 020 U2.1 Agents 工作面活动流数据源。
 *
 * 唯一真实路径：GraphQL myWorkspaceToolCalls（本人 + workspace 双过滤在查询面）。
 */

export interface AgentActivityItem {
	id: string;
	tool: string;
	/** ok | error | needs_confirmation | forbidden（后端 result_status 字符串化） */
	status: string;
	latencyMs: number | null;
	insertedAt: string;
	errorMessage: string | null;
}

/** 后端 WorkspaceToolCall → 前端展示项（形状一致，直映射） */
export function mapAgentActivity(t: WorkspaceToolCall): AgentActivityItem {
	return {
		id: t.id,
		tool: t.tool,
		status: t.status,
		latencyMs: t.latencyMs ?? null,
		insertedAt: t.insertedAt,
		errorMessage: t.errorMessage ?? null,
	};
}

/** 本人在某工作台的 MCP 工具调用活动流（新→旧；非成员查询面直接 forbidden） */
export async function fetchMyWorkspaceToolCalls(
	workspaceId: string,
	first = 50,
): Promise<AgentActivityItem[]> {
	const { data } = await client.query({
		query: MY_WORKSPACE_TOOL_CALLS,
		variables: { workspaceId, first },
	});
	return (data?.myWorkspaceToolCalls ?? []).map(mapAgentActivity);
}
