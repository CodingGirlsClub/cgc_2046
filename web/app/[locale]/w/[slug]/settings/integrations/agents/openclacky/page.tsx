"use client";

/**
 * 集成 - OpenClacky（接入引导）页 /w/[slug]/settings/integrations/agents/openclacky。
 *
 * 三步接入引导（常驻）：
 * ① 安装 OpenClacky（官方下载页 iframe embed）
 * ② 安装 CGC-2046 连接器扩展（OpenClacky 扩展市场）
 * ③ 生成连接 token（跳转 MCP 页签发）
 *
 * 三张内容卡为共享组件（@/components/agent-connect-sections，
 * 首公里向导复用同一内容源，per plan first-mile-onboarding R4）。
 */

import { Link } from "@/i18n/navigation";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import WorkspaceShell from "@/components/workspace-shell";
import IntegrationsAgentsTabs from "@/components/integrations-agents-tabs";
import {
	OpenclackyInstallCard,
	OpenclackyExtensionCard,
	OpenclackyTokenLinkCard,
} from "@/components/agent-connect-sections";

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
					<OpenclackyInstallCard stepNo="①" />
					<OpenclackyExtensionCard stepNo="②" />
					<OpenclackyTokenLinkCard slug={slug} stepNo="③" />
				</div>
			</div>
		</WorkspaceShell>
	);
}
