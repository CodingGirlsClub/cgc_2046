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
import { useTranslations } from "next-intl";
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
	const t = useTranslations("agentConnect");
	const tCommon = useTranslations("common");

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label={tCommon("breadcrumbAria")}>
					<Link href="/">{t("breadcrumbHome")}</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<Link href={`/w/${slug}/settings/join-policy`}>
						{t("breadcrumbSettings")}
					</Link>
					<span>›</span>
					<strong>{t("titleOpencode")}</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>{t("titleOpencode")}</h1>
						<p>{t("subtitleOpencode")}</p>
					</div>
				</header>

				<IntegrationsAgentsTabs slug={slug} current="agents-opencode" abilities={[]} />

				<div style={{ display: "grid", gap: 16, marginTop: 16 }}>
					<div className="connect-step-card">
						<h2>{t("step1Title")}</h2>
						<p className="connect-step-card__desc">
							{t.rich("step1Desc", {
								link: (chunks) => (
									<Link
										href={`/w/${slug}/settings/integrations/agents/mcp`}
										className="connect-step-card__link"
									>
										{chunks}
									</Link>
								),
							})}
						</p>
					</div>

					<div className="connect-step-card">
						<h2>{t("step2Title", { file: "opencode.json" })}</h2>
						<p className="connect-step-card__desc">
							{t.rich("step2DescPlain", {
								code: (chunks) => <code>{chunks}</code>,
							})}
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
							{t.rich("urlNote", {
								code: (chunks) => <code>{chunks}</code>,
								code2: (chunks) => <code>{chunks}</code>,
								code3: (chunks) => <code>{chunks}</code>,
								code4: (chunks) => <code>{chunks}</code>,
							})}
						</p>
					</div>

					<div className="connect-step-card">
						<h2>{t("step3Title")}</h2>
						<p className="connect-step-card__desc">
							{"opencode "}
							{t.rich("step3DescEnv", {
								code: (chunks) => <code>{chunks}</code>,
								placeholder: "{env:CGC_TOKEN}",
							})}
						</p>
					</div>

					<div className="connect-step-card">
						<h2>{t("notesTitle")}</h2>
						<p className="connect-step-card__desc">
							{t.rich("notesDesc", {
								code: (chunks) => <code>{chunks}</code>,
							})}
						</p>
					</div>
				</div>
			</div>
		</WorkspaceShell>
	);
}
