"use client";

/**
 * 用户级「连接与授权」页 /settings/account/connections（U5/KTD3）。
 *
 * 为什么必须存在用户级入口：连接 token 与 OAuth 授权都绑用户、不绑工作台（D13），
 * 且 U4 同意页向用户承诺「可随时在 CGC 账号设置中撤销此授权」——撤销入口不能只
 * 存在于需要工作台成员资格的工作台设置页。入口在用户菜单的 Account 分组
 * （workspace-switcher-menu），任何登录用户可达。
 *
 * 与工作台 MCP 页同一数据流与组件（useMcpCredentials + McpTokenList /
 * AuthorizedAppsSection）；本页不含签发面——签发属于接入向导语境（工作台 MCP 页
 * 的签发行与首公里向导共用同一面板）。
 */

import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { useTranslations } from "next-intl";
import { useAuthed } from "@/lib/use-authed";
import { useMcpCredentials } from "@/lib/mcp-credentials";
import SitePage from "@/components/site-page";
import McpTokenList from "@/components/mcp-token-list";
import AuthorizedAppsSection from "@/components/authorized-apps-section";

export default function AccountConnectionsPage() {
	const t = useTranslations("accountConnections");
	const tMcp = useTranslations("workspaceMcp");
	const tAuth = useTranslations("oauthAuthorizations");
	const labelsT = useTranslations();
	const router = useRouter();
	const { authed, confirmed } = useAuthed();

	// 未登录跳登录页并带回跳（confirmed 前不跳：已登录用户不被先踢）
	useEffect(() => {
		if (confirmed && !authed) {
			router.replace(
				`/login?next=${encodeURIComponent("/settings/account/connections")}`,
			);
		}
	}, [confirmed, authed, router]);

	const credentials = useMcpCredentials({ enabled: authed });
	// 错误只挡空态、不挡已有数据（撤销失败的列表保留展示，错误内联在页首）
	const showTokenSection = credentials.tokens.length > 0 || !credentials.errorKey;
	const showAuthSection =
		credentials.authorizations.length > 0 || !credentials.errorKey;

	if (!confirmed || !authed) {
		return (
			<SitePage>
				<div className="mx-auto max-w-3xl px-4 py-10">
					<div className="settings-loading" aria-label={tMcp("loadingAria")}>
						<div className="settings-skeleton settings-skeleton--title" />
						<div className="settings-skeleton" />
					</div>
				</div>
			</SitePage>
		);
	}

	return (
		<SitePage>
			<div className="mx-auto max-w-3xl px-4 py-10">
				<h1 className="l-h1">{t("title")}</h1>
				<p className="mt-2 text-sm leading-7 text-ink-2">{t("subtitle")}</p>

				{credentials.loading && (
					<div className="settings-loading" aria-label={tMcp("loadingAria")}>
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
							{tMcp("retry")}
						</button>
					</div>
				)}

				{!credentials.loading && showTokenSection && (
					<section className="mt-8">
						<h2 className="l-h3">{tMcp("tokensHeading")}</h2>
						{credentials.tokens.length === 0 ? (
							<p className="mt-2 text-sm leading-7 text-ink-2">
								{tMcp("empty")}
							</p>
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
					<section className="mt-10">
						<h2 className="l-h3">{tAuth("title")}</h2>
						<p className="mt-2 text-sm leading-7 text-ink-2">
							{tAuth("subtitle")}
						</p>
						{credentials.authorizations.length === 0 ? (
							<p
								className="mt-2 text-sm leading-7 text-ink-2"
								data-testid="authorized-apps-empty"
							>
								{tAuth("empty")}
							</p>
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
		</SitePage>
	);
}
