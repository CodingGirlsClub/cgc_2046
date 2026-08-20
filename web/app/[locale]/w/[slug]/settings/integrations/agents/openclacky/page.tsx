"use client";

/**
 * 集成 - OpenClacky（接入引导）页 /w/[slug]/settings/integrations/agents/openclacky。
 *
 * 三步接入引导（常驻）：
 * ① 安装 OpenClacky（官方下载页 iframe embed）
 * ② 安装 CGC-2046 连接器扩展（OpenClacky 扩展市场）
 * ③ 生成连接 token（跳转 MCP 页签发）
 */

import { Link } from "@/i18n/navigation";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import WorkspaceShell from "@/components/workspace-shell";
import IntegrationsAgentsTabs from "@/components/integrations-agents-tabs";
import { Icon } from "@/components/icons";

export default function AgentsOpenclackyPage() {
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
					<strong>{t("titleOpenclacky")}</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>{t("titleOpenclacky")}</h1>
						<p>{t("subtitleOpenclacky")}</p>
					</div>
				</header>

				<IntegrationsAgentsTabs slug={slug} current="agents-openclacky" abilities={[]} />

				<div style={{ display: "grid", gap: 16, marginTop: 16 }}>
					<div className="connect-step-card">
						<h2>{t("step1Openclacky")}</h2>
						<iframe
							src="https://www.openclacky.com/claw/cgc?embed=1"
							width="100%"
							height={300}
							style={{ border: "none", borderRadius: 12 }}
							allow="clipboard-write"
							loading="lazy"
							title={t("downloadTitle")}
						/>
					</div>

					<div className="connect-step-card">
						<h2>{t("step2Openclacky")}</h2>
						<p className="connect-step-card__desc">
							{t("extensionSearchHint")}
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
								{t("openMarket")}
							</li>
							<li style={{ lineHeight: "20px" }}>
								{t.rich("searchExtension", {
									code: (chunks) => <code>{chunks}</code>,
								})}
							</li>
							<li style={{ lineHeight: "20px" }}>
								{t("installExtension")}
							</li>
						</ol>
						<p className="connect-step-card__desc">
							{t("installedPanel")}
						</p>
					</div>

					<div className="connect-step-card">
						<h2>{t("step3Openclacky")}</h2>
						<p className="connect-step-card__desc">
							{t("generateTokenDesc")}
						</p>
						<div className="connect-step-card__actions">
							<Link
								href={`/w/${slug}/settings/integrations/agents/mcp`}
								className="join-button join-button--primary"
							>
								<Icon name="plus" />
								{t("generateToken")}
							</Link>
						</div>
					</div>
				</div>
			</div>
		</WorkspaceShell>
	);
}
