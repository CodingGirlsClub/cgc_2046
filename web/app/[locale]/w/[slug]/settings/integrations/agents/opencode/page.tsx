"use client";

/**
 * 集成 - opencode（手动配置）页 /w/[slug]/settings/integrations/agents/opencode。
 *
 * opencode 客户端接入 CGC-2046 的手动配置说明：
 * 项目根目录 opencode.json 写入 cgc-2046 条目（type remote + oauth:false +
 * Bearer {env:CGC_TOKEN}），token 从 MCP 页签发。
 *
 * 内容卡为共享组件（@/components/agent-connect-sections，
 * 首公里向导复用同一内容源，per plan first-mile-onboarding R4）。
 */

import { Link } from "@/i18n/navigation";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import WorkspaceShell from "@/components/workspace-shell";
import IntegrationsAgentsTabs from "@/components/integrations-agents-tabs";
import {
	TokenLinkStepCard,
	WriteConfigStepCard,
	ConfigureTokenStepCard,
	ConfigNotesStepCard,
} from "@/components/agent-connect-sections";

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
					<TokenLinkStepCard slug={slug} />
					<WriteConfigStepCard variant="opencode" />
					<ConfigureTokenStepCard variant="opencode" />
					<ConfigNotesStepCard />
				</div>
			</div>
		</WorkspaceShell>
	);
}
