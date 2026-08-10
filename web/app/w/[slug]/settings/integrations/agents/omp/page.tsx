"use client";

/**
 * 集成 - OMP（手动配置）页 /w/[slug]/settings/integrations/agents/omp。
 *
 * omp 客户端接入 CGC-2046 的手动配置说明：
 * 项目 .mcp.json 写入 cgc-2046 条目（mcpServers + type http +
 * Bearer ${CGC_TOKEN}），token 从 MCP 页签发。
 */

import Link from "next/link";
import { useParams } from "next/navigation";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import WorkspaceShell from "@/components/workspace-shell";
import IntegrationsAgentsTabs from "@/components/integrations-agents-tabs";

const OMP_CONFIG = `{
  "mcpServers": {
    "cgc-2046": {
      "type": "http",
      "url": "<MCP_URL>",
      "headers": { "Authorization": "Bearer \${CGC_TOKEN}" }
    }
  }
}`;

export default function AgentsOmpPage() {
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
					<strong>OMP</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>OMP</h1>
						<p>omp 客户端接入 CGC-2046 平台。</p>
					</div>
				</header>

				<IntegrationsAgentsTabs slug={slug} current="agents-omp" abilities={[]} />

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
						<h2>2. 写入 .mcp.json</h2>
						<p className="connect-step-card__desc">
							在项目根目录的 <code>.mcp.json</code>（或{" "}
							<code>~/.clacky/mcp.json</code>）中加入以下配置：
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
							<code>{OMP_CONFIG}</code>
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
							omp 支持环境变量插值：设置 <code>CGC_TOKEN</code> 环境变量后可直接使用；
							也可把 <code>{"${CGC_TOKEN}"}</code> 替换为实际 token。
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
