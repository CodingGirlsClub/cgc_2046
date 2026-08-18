"use client";

/**
 * 集成 - MCP（Token 管理）页 /w/[slug]/settings/integrations/agents/mcp。
 *
 * 管理 MCP 连接 token（客户端调 /mcp 的 Bearer 凭证，绑用户不绑工作区，D13）：
 * - token 列表（名称/签发时间/最近使用/状态）+ 签发 + 两步确认撤销
 * - 签发成功展示一次性明文（D-D4：库中只存 hash，离开此页不可找回）
 * - 空状态提示引导到 OpenClacky 页（接入引导）
 */

import { useCallback, useEffect, useRef, useState } from "react";
import { Link } from "@/i18n/navigation";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import {
	fetchMyMcpTokens,
	issueMcpToken,
	revokeMcpToken,
	type McpTokenItem,
} from "@/lib/mcp";
import { formatDateTime } from "@/lib/format";
import { copyText } from "@/lib/clipboard";
import WorkspaceShell from "@/components/workspace-shell";
import IntegrationsAgentsTabs from "@/components/integrations-agents-tabs";
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

	// 签发表单
	const [showForm, setShowForm] = useState(false);
	const [formName, setFormName] = useState("");
	const [formSubmitting, setFormSubmitting] = useState(false);
	const [formError, setFormError] = useState<string | null>(null);

	// 一次性明文（仅签发成功瞬间存在）
	const [freshToken, setFreshToken] = useState<{
		name: string;
		plainToken: string;
	} | null>(null);
	const [copiedFresh, setCopiedFresh] = useState(false);
	const [copyFreshFailed, setCopyFreshFailed] = useState(false);

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

	const handleIssue = useCallback(async () => {
		const name = formName.trim();
		if (!name) return;
		setFormSubmitting(true);
		setFormError(null);
		try {
			const { token, plainToken } = await issueMcpToken(name);
			setTokens((prev) => [token, ...prev]);
			setFreshToken({ name, plainToken });
			setCopiedFresh(false);
			setShowForm(false);
			setFormName("");
		} catch (e) {
			setFormError(e instanceof Error ? labelsT(e.message) : t("issueFailed"));
		} finally {
			setFormSubmitting(false);
		}
	}, [formName, t, labelsT]);

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

				<div className="settings-actions">
					<button
						type="button"
						className="join-button join-button--primary"
						onClick={() => setShowForm(true)}
					>
						<Icon name="plus" />
						{t("issueNew")}
					</button>
				</div>

				{/* 一次性明文展示（仅签发成功瞬间） */}
				{freshToken && (
					<div className="mcp-token-once" role="status">
						<p>
							{t("freshTokenNote", { name: freshToken.name })}
						</p>
						<div className="mcp-token-once__row">
							<code>{freshToken.plainToken}</code>
							<button
								type="button"
								className="join-button join-button--outline"
								onClick={() => {
									void copyText(freshToken.plainToken).then((ok) => {
										if (ok) {
											setCopiedFresh(true);
											setCopyFreshFailed(false);
											setTimeout(() => setCopiedFresh(false), 2000);
										} else {
											setCopyFreshFailed(true);
										}
									});
								}}
							>
								{copiedFresh ? t("copied") : t("copy")}
							</button>
							<button
								type="button"
								className="join-button join-button--ghost"
								onClick={() => setFreshToken(null)}
							>
								{t("savedConfirm")}
							</button>
						</div>
						{copyFreshFailed && (
							<p className="mcp-copy-error" role="alert">
								{t("copyFailed")}
							</p>
						)}
					</div>
				)}

				{/* 签发表单 */}
				{showForm && (
					<div className="invitation-form-card">
						<h2>{t("issueHeading")}</h2>
						<div className="invitation-form">
							<label className="join-field">
								<span>{t("nameLabel")}</span>
								<input
									type="text"
									className="join-input"
									placeholder={t("namePlaceholder")}
									value={formName}
									onChange={(e) => setFormName(e.target.value)}
									disabled={formSubmitting}
								/>
							</label>
							{formError && (
								<div className="members-error" role="alert">
									{formError}
								</div>
							)}
							<div className="invitation-form-actions">
								<button
									type="button"
									className="join-button join-button--primary"
									onClick={handleIssue}
									disabled={formSubmitting || !formName.trim()}
								>
									{formSubmitting ? t("issuing") : t("issue")}
								</button>
								<button
									type="button"
									className="join-button join-button--ghost"
									onClick={() => {
										setShowForm(false);
										setFormError(null);
									}}
									disabled={formSubmitting}
								>
									{t("cancel")}
								</button>
							</div>
						</div>
					</div>
				)}

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
													: "l-badge-danger"
											}`}
										>
											{token.status === "active" ? t("active") : t("revoked")}
										</span>
										{token.status === "active" &&
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
