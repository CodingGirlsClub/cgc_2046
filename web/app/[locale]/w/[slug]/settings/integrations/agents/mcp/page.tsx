"use client";

/**
 * 集成 - MCP（用户级凭证）页 /w/[slug]/settings/integrations/agents/mcp。
 *
 * 同一界面呈现两类绑定用户的凭证（KTD3「不建第二套状态体系」）：
 * - 连接 token（手工粘贴的 Bearer 凭证，D-D4/D13）：列表 + 签发 + 两步确认撤销
 * - 已授权应用（宿主经平台 OAuth 授权拿到的凭证，U5）：列表 + 两步确认撤销
 * 两者都进首公里「已接入」判定（lib/onboarding.ts deriveOnboardingState）；
 * 撤销后 web 端即时反映，宿主在下一次调用时得到 401（无推送通道，拉模式）。
 *
 * 数据流与两个共享组件（McpTokenList / AuthorizedAppsSection）由用户级账号设置
 * `/settings/account/connections` 复用；本页额外挂签发行（McpTokenIssuePanel：
 * 表单 + 一次性明文，D-D4 库中只存 hash，离开此页不可找回——首公里向导复用同一
 * 签出面）。
 */

import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import { useMcpCredentials } from "@/lib/mcp-credentials";
import WorkspaceShell from "@/components/workspace-shell";
import IntegrationsAgentsTabs from "@/components/integrations-agents-tabs";
import McpTokenIssuePanel from "@/components/mcp-token-issue-panel";
import McpTokenList from "@/components/mcp-token-list";
import AuthorizedAppsSection from "@/components/authorized-apps-section";
import { Icon } from "@/components/icons";

export default function AgentsMcpPage() {
	const t = useTranslations("workspaceMcp");
	const tCommon = useTranslations("common");
	const tAuth = useTranslations("oauthAuthorizations");
	const labelsT = useTranslations();
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const { ws, loading: wsLoading } = useWorkspaceBySlug(slug);

	// 凭证两源（token + 授权）：ws 就绪后拉取（进入本页即工作台上下文已定）
	const credentials = useMcpCredentials({ enabled: Boolean(ws) });
	// 错误只挡空态、不挡已有数据：撤销失败时列表保留展示（错误内联在页首），
	// 加载失败且无数据时才整段隐藏（不留空标题）
	const showTokenSection =
		credentials.tokens.length > 0 || !credentials.errorKey;
	const showAuthSection =
		credentials.authorizations.length > 0 || !credentials.errorKey;

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
					<strong>{t("title")}</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>{t("title")}</h1>
						<p>{t("subtitle")}</p>
					</div>
				</header>

				<IntegrationsAgentsTabs slug={slug} current="agents-mcp" abilities={[]} />

				<McpTokenIssuePanel onIssued={credentials.prependToken} />

				{(wsLoading || credentials.loading) && (
					<div className="settings-loading" aria-label={t("loadingAria")}>
						<div className="settings-skeleton settings-skeleton--title" />
						<div className="settings-skeleton" />
					</div>
				)}

				{credentials.errorKey && (
					<div className="members-error" role="alert">
						{labelsT(credentials.errorKey)}
						<button
							type="button"
							className="join-button join-button--outline"
							onClick={credentials.reload}
						>
							{t("retry")}
						</button>
					</div>
				)}

				{!credentials.loading && showTokenSection && (
					<section>
						<h2 className="l-h3">{t("tokensHeading")}</h2>
						{credentials.tokens.length === 0 ? (
							<div className="settings-empty">
								<Icon name="invite" />
								<p>{t("empty")}</p>
								<Link
									href={`/w/${slug}/settings/integrations/agents/openclacky`}
									className="join-button join-button--outline"
								>
									{t("viewGuide")}
								</Link>
							</div>
						) : (
							<McpTokenList
								tokens={credentials.tokens}
								revokingId={credentials.revokingTokenId}
								onRevoke={credentials.revokeToken}
							/>
						)}
					</section>
				)}

				{!credentials.loading && showAuthSection && (
					<section style={{ marginTop: 24 }}>
						<h2 className="l-h3">{tAuth("title")}</h2>
						<p className="ws-page-heading__desc">{tAuth("subtitle")}</p>
						{credentials.authorizations.length === 0 ? (
							<p data-testid="authorized-apps-empty">{tAuth("empty")}</p>
						) : (
							<AuthorizedAppsSection
								items={credentials.authorizations}
								revokingClientId={credentials.revokingClientId}
								onRevoke={credentials.revokeAuthorization}
							/>
						)}
					</section>
				)}
			</div>
		</WorkspaceShell>
	);
}
