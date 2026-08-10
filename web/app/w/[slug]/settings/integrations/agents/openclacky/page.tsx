"use client";

/**
 * 集成 - OpenClacky（接入引导）页 /w/[slug]/settings/integrations/agents/openclacky。
 *
 * 三步接入引导（常驻）：
 * ① 安装 OpenClacky（官方下载页 iframe embed）
 * ② 安装 CGC-2046 连接器扩展（OpenClacky 扩展市场）
 * ③ 生成连接 token（跳转 MCP 页签发）
 */

import Link from "next/link";
import { useParams } from "next/navigation";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import WorkspaceShell from "@/components/workspace-shell";
import IntegrationsAgentsTabs from "@/components/integrations-agents-tabs";
import { Icon } from "@/components/icons";

export default function AgentsOpenclackyPage() {
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
					<strong>OpenClacky</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>OpenClacky</h1>
						<p>按步骤把 Agent 接入 CGC-2046 平台。</p>
					</div>
				</header>

				<IntegrationsAgentsTabs slug={slug} current="agents-openclacky" abilities={[]} />

				<div style={{ display: "grid", gap: 16, marginTop: 16 }}>
					<div className="connect-step-card">
						<h2>① 安装 OpenClacky</h2>
						<iframe
							src="https://www.openclacky.com/claw/cgc?embed=1"
							width="100%"
							height={300}
							style={{ border: "none", borderRadius: 12 }}
							allow="clipboard-write"
							loading="lazy"
							title="下载 OpenClacky"
						/>
					</div>

					<div className="connect-step-card">
						<h2>② 安装 CGC-2046 连接器扩展</h2>
						<p className="connect-step-card__desc">
							在 OpenClacky 扩展市场中搜索安装：
						</p>
						<ol
							style={{
								margin: "0 0 0 18px",
								padding: 0,
								display: "grid",
								gap: 6,
								color: "var(--ink-3)",
								fontSize: 13,
								lineHeight: "20px",
								listStyle: "decimal",
							}}
						>
							<li style={{ lineHeight: "20px" }}>
								打开{" "}
								<a
									href="http://localhost:7070/#extensions"
									target="_blank"
									rel="noreferrer"
								>
									http://localhost:7070/#extensions
								</a>
							</li>
							<li style={{ lineHeight: "20px" }}>
								搜索 <code>CGC-2046</code>
							</li>
							<li style={{ lineHeight: "20px" }}>
								点击扩展卡片 → 安装
							</li>
						</ol>
						<p className="connect-step-card__desc">
							安装完成后，侧边栏会出现「CGC-2046」面板，会话列表里会出现「CGC-2046 助手」。
						</p>
					</div>

					<div className="connect-step-card">
						<h2>③ 生成连接 token</h2>
						<p className="connect-step-card__desc">
							在 MCP 页签发一个连接 token（绑用户不绑工作区）。
							生成后复制到剪贴板，在 OpenClacky 的 CGC 助手会话中完成接入——
							助手会安全读取剪贴板，token 不会进入对话记录。
						</p>
						<div className="connect-step-card__actions">
							<Link
								href={`/w/${slug}/settings/integrations/agents/mcp`}
								className="join-button join-button--primary"
							>
								<Icon name="plus" />
								生成 token
							</Link>
						</div>
					</div>
				</div>
			</div>
		</WorkspaceShell>
	);
}
