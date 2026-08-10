"use client";

/**
 * 集成 - opencode（手动配置）页 /w/[slug]/settings/integrations/agents/opencode。
 *
 * opencode 客户端接入 CGC-2046 的手动配置说明：
 * 项目根目录 opencode.json 写入 cgc-2046 条目（type remote + oauth:false +
 * Bearer {env:CGC_TOKEN}），token 从 MCP 页签发。
 */

import Link from "next/link";
import { useParams } from "next/navigation";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import WorkspaceShell from "@/components/workspace-shell";
import IntegrationsAgentsTabs from "@/components/integrations-agents-tabs";

const OPCODE_CONFIG = `{
  "mcp": {
    "cgc-2046": {
      "type": "remote",
      "url": "<MCP_URL>",
      "oauth": false,
      "headers": { "Authorization": "Bearer {env:CGC_TOKEN}" }
    }
  }
}`;

export default function AgentsOpencodePage() {
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const { ws } = useWorkspaceBySlug(slug);

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label="页面路径">
					<Link href="/">工作台</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<Link href={`/w/${slug}/settings/join-policy`}>设置</Link>
					<span>›</span>
					<strong>opencode</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>opencode</h1>
						<p>opencode 客户端接入 CGC-2046 平台。</p>
					</div>
				</header>

				<IntegrationsAgentsTabs slug={slug} current="agents-opencode" abilities={[]} />

				<div style={{ display: "grid", gap: 16, marginTop: 16 }}>
					<div className="connect-step-card">
						<h2>1. 获取 token</h2>
						<p className="connect-step-card__desc">
							在{" "}
							<Link
								href={`/w/${slug}/settings/integrations/agents/mcp`}
								className="connect-step-card__link"
							>
								MCP 页
							</Link>{" "}
							签发一个连接 token（绑用户不绑工作区），复制到剪贴板（明文只显示一次）。
						</p>
					</div>

					<div className="connect-step-card">
						<h2>2. 写入 opencode.json</h2>
						<p className="connect-step-card__desc">
							在项目根目录的 <code>opencode.json</code> 中加入以下配置：
						</p>
						<pre
							style={{
								overflowX: "auto",
								padding: "12px 14px",
								borderRadius: "var(--radius-small)",
								background: "var(--soft)",
								margin: 0,
								fontSize: 12.5,
								lineHeight: "18px",
							}}
						>
							<code>{OPCODE_CONFIG}</code>
						</pre>
						<p className="connect-step-card__desc">
							<code>&lt;MCP_URL&gt;</code> 替换为平台 MCP 地址（开发联调默认{" "}
							<code>http://localhost:4102/mcp</code>，与连接器扩展{" "}
							<code>ext.yml</code> <code>config.mcp_url</code> 一致；生产以平台公布为准）。
						</p>
					</div>

					<div className="connect-step-card">
						<h2>3. 配置 token</h2>
						<p className="connect-step-card__desc">
							opencode 支持环境变量插值：设置 <code>CGC_TOKEN</code> 环境变量后可直接使用；
							也可把 <code>{"{env:CGC_TOKEN}"}</code> 替换为实际 token。
						</p>
					</div>

					<div className="connect-step-card">
						<h2>注意事项</h2>
						<p className="connect-step-card__desc">
							已有其它 MCP server 条目时，把 <code>cgc-2046</code> 条目合并进现有配置，
							勿整体覆盖。token 绑用户不绑工作区，加入新工作区无需重新配置。
						</p>
					</div>
				</div>
			</div>
		</WorkspaceShell>
	);
}
