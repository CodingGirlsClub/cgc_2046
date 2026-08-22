"use client";

/**
 * 集成 - Agents 区入口页 /w/[slug]/settings/integrations/agents
 * （plan 2026-08-22 first-mile-onboarding U4，KTD1）。
 *
 * 该路径此前 404（子页靠 tabs 直达），本页为新增的区入口，向导/管理两态互斥：
 * - 无 active token（未接入成员，含全撤销/过期的回归成员）→ 向导态
 *   （OnboardingWizard：开场 + 三步 stepper + 内嵌签发，R4–R6）；
 * - 有 active token（已接入成员）→ 管理态：IntegrationsAgentsTabs 现状内容 +
 *   四子页入口卡 +「已接入 ✓ · 重新查看引导」（只读回看，无签发面，R7）；
 * - useOnboardingState 消费契约（KTD5）：先判 loading/error——
 *   loading → 骨架占位；error → 静默回退管理态（该区今天的现状外观即安全回退）。
 *
 * 四个子页路由与外观不变（R9/KTD1：v1 不改名、无重定向义务）；
 * 该区不做能力门控，所有成员可用（R10）。
 */

import { useState } from "react";
import { Link } from "@/i18n/navigation";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import { useOnboardingState } from "@/lib/onboarding";
import WorkspaceShell from "@/components/workspace-shell";
import IntegrationsAgentsTabs from "@/components/integrations-agents-tabs";
import OnboardingWizard from "@/components/onboarding-wizard";

function EntryCard({
	href,
	title,
	desc,
}: {
	href: string;
	title: string;
	desc: string;
}) {
	return (
		<div className="connect-step-card">
			<h2>
				<Link href={href} className="connect-step-card__link">
					{title}
				</Link>
			</h2>
			<p className="connect-step-card__desc">{desc}</p>
		</div>
	);
}

export default function AgentsIntegrationsPage() {
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const { ws } = useWorkspaceBySlug(slug);
	const t = useTranslations("onboarding");
	const tConnect = useTranslations("agentConnect");
	const tMcp = useTranslations("workspaceMcp");
	const tCommon = useTranslations("common");
	const state = useOnboardingState();
	const [reviewing, setReviewing] = useState(false);

	// KTD5：loading/error 优先求值；error 静默回退管理态
	const showWizard = !state.loading && !state.error && !state.hasActiveToken;

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label={tCommon("breadcrumbAria")}>
					<Link href="/">{tConnect("breadcrumbHome")}</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<Link href={`/w/${slug}/settings/join-policy`}>
						{tConnect("breadcrumbSettings")}
					</Link>
					<span>›</span>
					<strong>{t("entryTitle")}</strong>
				</div>

				{state.loading ? (
					<div className="settings-loading" aria-label={t("loadingAria")}>
						<div className="settings-skeleton settings-skeleton--title" />
						<div className="settings-skeleton" />
					</div>
				) : showWizard ? (
					<OnboardingWizard slug={slug} />
				) : reviewing ? (
					<>
						<div className="settings-actions">
							<button
								type="button"
								className="join-button join-button--ghost"
								onClick={() => setReviewing(false)}
							>
								{t("reviewBack")}
							</button>
						</div>
						<OnboardingWizard slug={slug} readOnly />
					</>
				) : (
					<>
						<header className="ws-page-heading">
							<div>
								<h1>{t("entryTitle")}</h1>
								<p>{t("entrySubtitle")}</p>
							</div>
						</header>

						<IntegrationsAgentsTabs
							slug={slug}
							current="agents-entry"
							abilities={[]}
						/>

						{!state.error && (
							<p style={{ marginTop: 16 }}>
								<span className="l-badge l-badge-volunteer">
									{t("connectedBadge")}
								</span>{" "}
								<button
									type="button"
									className="join-button join-button--outline"
									onClick={() => setReviewing(true)}
								>
									{t("reviewGuide")}
								</button>
							</p>
						)}

						<div
							data-testid="agent-entry-cards"
							style={{ display: "grid", gap: 16, marginTop: 16 }}
						>
							<EntryCard
								href={`/w/${slug}/settings/integrations/agents/mcp`}
								title={tMcp("title")}
								desc={tMcp("subtitle")}
							/>
							<EntryCard
								href={`/w/${slug}/settings/integrations/agents/openclacky`}
								title={tConnect("titleOpenclacky")}
								desc={tConnect("subtitleOpenclacky")}
							/>
							<EntryCard
								href={`/w/${slug}/settings/integrations/agents/opencode`}
								title={tConnect("titleOpencode")}
								desc={tConnect("subtitleOpencode")}
							/>
							<EntryCard
								href={`/w/${slug}/settings/integrations/agents/omp`}
								title={tConnect("titleOmp")}
								desc={tConnect("subtitleOmp")}
							/>
						</div>
					</>
				)}
			</div>
		</WorkspaceShell>
	);
}
