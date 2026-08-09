import { client } from "./apollo-client";
import {
	MY_MCP_TOKENS,
	CREATE_MCP_TOKEN,
	REVOKE_MCP_TOKEN,
	type McpToken,
} from "./graphql/mcp-token";

/**
 * 切片 D（#44）MCP 连接 token 数据源 + 客户端配置片段生成。
 *
 * 唯一真实路径：GraphQL（graphql/mcp-token.ts 契约）。
 * 配置片段生成是纯函数（buildConfigSnippet），单测锁定三家客户端差异（research §5b）：
 * - OpenClacky / omp：顶层 mcpServers + type "http"；omp 支持 ${VAR} 环境变量插值
 * - opencode：顶层 mcp 键 + type "remote" + oauth:false + {env:VAR} 插值
 * - 片段内一律用占位符，不明文渲染 token（D-D10）；OpenClacky 无环境变量插值，
 *   用 <CGC_TOKEN> 明示手动替换
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

/* ---------------- 客户端配置片段（research §5b） ---------------- */

export type McpClientKey = "openclacky" | "omp" | "opencode";

export interface McpClientInfo {
	key: McpClientKey;
	label: string;
	/** 片段写入的配置文件位置（展示给用户） */
	configPath: string;
	/** 占位符处理说明（占位符本体由 buildConfigSnippet 单一来源生成） */
	note: string;
}

export const MCP_CLIENTS: McpClientInfo[] = [
	{
		key: "openclacky",
		label: "OpenClacky",
		configPath: "~/.clacky/mcp.json",
		note: "片段中的占位符需手动替换为你的连接 token（OpenClacky 暂不支持环境变量插值）。已有其他 MCP server 时，请把 cgc 条目合并进现有配置，勿整体覆盖。",
	},
	{
		key: "omp",
		label: "omp",
		configPath: "项目根目录 .mcp.json",
		note: "omp 支持环境变量插值：设置 CGC_TOKEN 环境变量后可直接使用；也可手动替换片段中的占位符。",
	},
	{
		key: "opencode",
		label: "opencode",
		configPath: "项目根目录 opencode.json",
		note: "opencode 支持环境变量插值：设置 CGC_TOKEN 环境变量后可直接使用；也可手动替换片段中的占位符。",
	},
];

/** MCP 端点 URL（后端 /mcp 不经前端代理，生产经 NEXT_PUBLIC_MCP_URL 配置） */
export const MCP_SERVER_URL =
	process.env.NEXT_PUBLIC_MCP_URL ?? "http://localhost:4000/mcp";

/** 生成指定客户端的配置片段（纯函数；占位符版本，绝不含明文 token） */
export function buildConfigSnippet(
	clientKey: McpClientKey,
	url: string = MCP_SERVER_URL,
): string {
	switch (clientKey) {
		case "openclacky":
			return JSON.stringify(
				{
					mcpServers: {
						cgc: {
							type: "http",
							url,
							headers: { Authorization: "Bearer <CGC_TOKEN>" },
							description: "CGC-2046 platform capabilities",
						},
					},
				},
				null,
				2,
			);
		case "omp":
			return JSON.stringify(
				{
					mcpServers: {
						cgc: {
							type: "http",
							url,
							headers: { Authorization: "Bearer ${CGC_TOKEN}" },
						},
					},
				},
				null,
				2,
			);
		case "opencode":
			return JSON.stringify(
				{
					mcp: {
						cgc: {
							type: "remote",
							url,
							oauth: false,
							headers: { Authorization: "Bearer {env:CGC_TOKEN}" },
						},
					},
				},
				null,
				2,
			);
	}
}
