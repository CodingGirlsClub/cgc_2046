"use client";

/**
 * 集成 - OMP（手动配置）页 /w/[slug]/settings/integrations/agents/omp。
 *
 * omp 客户端接入 CGC-2046 的手动配置说明：
 * 项目 .mcp.json 写入 cgc-2046 条目（mcpServers + type http +
 * Bearer ${CGC_TOKEN}），token 从 MCP 页签发。
 */

import { Link } from "@/i18n/navigation";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
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
					<strong>{t("titleOmp")}</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>{t("titleOmp")}</h1>
						<p>{t("subtitleOmp")}</p>
					</div>
				</header>

				<IntegrationsAgentsTabs slug={slug} current="agents-omp" abilities={[]} />

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
						<h2>{t("step2Title", { file: ".mcp.json" })}</h2>
						<p className="connect-step-card__desc">
							{t.rich("step2DescRoot", {
								code: (chunks) => <code>{chunks}</code>,
								code2: (chunks) => <code>{chunks}</code>,
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
							<code>{OMP_CONFIG}</code>
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
							{"omp "}
							{t.rich("step3DescEnv", {
								code: (chunks) => <code>{chunks}</code>,
								placeholder: "${CGC_TOKEN}",
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
