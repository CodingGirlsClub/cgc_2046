"use client";

/**
 * 集成 - MCP（Token 管理）页 /w/[slug]/settings/integrations/agents/mcp。
 *
 * 管理 MCP 连接 token（客户端调 /mcp 的 Bearer 凭证，绑用户不绑工作区，D13）：
 * - token 列表（名称/签发时间/最近使用/状态）+ 签发 + 两步确认撤销
 * - 签发行（表单 + 一次性明文，D-D4：库中只存 hash，离开此页不可找回）
 *   为共享组件 McpTokenIssuePanel（首公里向导复用同一签出面）
 * - 空状态提示引导到 OpenClacky 页（接入引导）
 */

import { useCallback, useEffect, useRef, useState } from "react";
import { Link } from "@/i18n/navigation";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import {
	fetchMyMcpTokens,
	revokeMcpToken,
	type McpTokenItem,
} from "@/lib/mcp";
import { formatDateTime } from "@/lib/format";
import WorkspaceShell from "@/components/workspace-shell";
import IntegrationsAgentsTabs from "@/components/integrations-agents-tabs";
import McpTokenIssuePanel from "@/components/mcp-token-issue-panel";
import { Icon } from "@/components/icons";

export default function AgentsMcpPage() {
	const t = useTranslations("workspaceMcp");
	const tCommon = useTranslations("common");
	const labelsT = useTranslations();
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const { ws, loading: wsLoading } = useWorkspaceBySlug(slug);

	const [tokens, setTokens] = useState<McpTokenItem[]>([]);
	const [loading, setLoading] = useState(true);
	const [error, setError] = useState<string | null>(null);
	const loadedRef = useRef(false);

	// 撤销两步确认
	const [confirmRevokeId, setConfirmRevokeId] = useState<string | null>(null);
	const [revokingId, setRevokingId] = useState<string | null>(null);

	useEffect(() => {
		if (!ws || loadedRef.current) return;
		loadedRef.current = true;
		let cancelled = false;
		fetchMyMcpTokens()
			.then((list) => {
				if (!cancelled) setTokens(list);
			})
			.catch((e) => {
				if (!cancelled)
					setError(e instanceof Error ? labelsT(e.message) : t("loadFailed"));
			})
			.finally(() => {
				if (!cancelled) setLoading(false);
			});
		return () => {
			cancelled = true;
		};
	}, [ws, t, labelsT]);

	const loadTokens = useCallback(async () => {
		setLoading(true);
		setError(null);
		try {
			setTokens(await fetchMyMcpTokens());
		} catch (e) {
			setError(e instanceof Error ? labelsT(e.message) : t("loadFailed"));
		} finally {
			setLoading(false);
		}
	}, [t, labelsT]);

	const handleRevoke = useCallback(async (id: string) => {
		setRevokingId(id);
		try {
			const revoked = await revokeMcpToken(id);
			setTokens((prev) => prev.map((t) => (t.id === id ? revoked : t)));
		} catch (e) {
			setError(e instanceof Error ? labelsT(e.message) : t("revokeFailed"));
		} finally {
			setRevokingId(null);
			setConfirmRevokeId(null);
		}
	}, [t, labelsT]);

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

				<McpTokenIssuePanel
					onIssued={(token) => setTokens((prev) => [token, ...prev])}
				/>

				{(wsLoading || loading) && (
					<div className="settings-loading" aria-label={t("loadingAria")}>
						<div className="settings-skeleton settings-skeleton--title" />
						<div className="settings-skeleton" />
					</div>
				)}

				{error && (
					<div className="members-error" role="alert">
						{error}
						<button
							type="button"
							className="join-button join-button--outline"
							onClick={loadTokens}
						>
							{t("retry")}
						</button>
					</div>
				)}

				{!loading && !error && tokens.length === 0 && (
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
				)}

				{tokens.length > 0 && (
					<div className="invitations-list">
						{tokens.map((token) => (
							<div className="invitation-card" key={token.id}>
								<div className="invitation-card__header">
									<div className="invitation-card__info">
										<strong>{token.name}</strong>
										<div className="invitation-card__expires">
											{t("issuedAt", {
												time: formatDateTime(token.insertedAt),
												used: formatDateTime(token.lastUsedAt),
											})}
										</div>
									</div>
									<div className="invitation-card__actions">
										<span
											className={`l-badge ${
												token.status === "active"
													? "l-badge-volunteer"
													: token.status === "idle_expired"
														? "l-badge-pending"
														: "l-badge-danger"
											}`}
										>
											{token.status === "active"
												? t("active")
												: token.status === "idle_expired"
													? t("idleExpired")
													: t("revoked")}
										</span>
										{token.status !== "revoked" &&
											(confirmRevokeId === token.id ? (
												<>
													<button
														type="button"
														className="join-button join-button--primary"
														disabled={revokingId === token.id}
														onClick={() => handleRevoke(token.id)}
													>
														{revokingId === token.id
															? t("revoking")
															: t("confirmRevoke")}
													</button>
													<button
														type="button"
														className="join-button join-button--ghost"
														disabled={revokingId === token.id}
														onClick={() => setConfirmRevokeId(null)}
													>
														{t("cancel")}
													</button>
												</>
											) : (
												<button
													type="button"
													className="join-button join-button--outline"
													onClick={() => setConfirmRevokeId(token.id)}
												>
													{t("revoke")}
												</button>
											))}
									</div>
								</div>
							</div>
						))}
					</div>
				)}
			</div>
		</WorkspaceShell>
	);
}
