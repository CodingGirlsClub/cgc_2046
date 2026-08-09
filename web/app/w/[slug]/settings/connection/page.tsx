"use client";

/**
 * 切片 D（#44）连接设置页 /w/[slug]/settings/connection。
 *
 * 管理 MCP 连接 token（OpenClacky/omp/opencode 等客户端调 /mcp 的 Bearer 凭证，
 * 绑用户不绑工作区，D13）：
 * - token 列表（名称/签发时间/最近使用/状态）+ 签发 + 两步确认撤销
 * - 签发成功展示一次性明文（D-D4：库中只存 hash，离开此页不可找回）
 * - 三客户端配置片段 Tab（McpConfigSnippet，占位符版本，D-D10）
 */

import { useCallback, useEffect, useRef, useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
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
import McpConfigSnippet from "@/components/mcp-config-snippet";
import { Icon } from "@/components/icons";

export default function ConnectionSettingsPage() {
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
					setError(e instanceof Error ? e.message : "加载失败");
			})
			.finally(() => {
				if (!cancelled) setLoading(false);
			});
		return () => {
			cancelled = true;
		};
	}, [ws]);

	const loadTokens = useCallback(async () => {
		setLoading(true);
		setError(null);
		try {
			setTokens(await fetchMyMcpTokens());
		} catch (e) {
			setError(e instanceof Error ? e.message : "加载失败");
		} finally {
			setLoading(false);
		}
	}, []);

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
			setFormError(e instanceof Error ? e.message : "签发失败");
		} finally {
			setFormSubmitting(false);
		}
	}, [formName]);

	const handleRevoke = useCallback(async (id: string) => {
		setRevokingId(id);
		try {
			const revoked = await revokeMcpToken(id);
			setTokens((prev) => prev.map((t) => (t.id === id ? revoked : t)));
		} catch (e) {
			setError(e instanceof Error ? e.message : "撤销失败");
		} finally {
			setRevokingId(null);
			setConfirmRevokeId(null);
		}
	}, []);

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label="页面路径">
					<Link href="/">工作台</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<Link href={`/w/${slug}/settings/join-policy`}>设置</Link>
					<span>›</span>
					<strong>连接</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>连接</h1>
						<p>
							管理 MCP 客户端（OpenClacky / omp / opencode）接入平台的连接
							token。首次接入？查看
							<Link href={`/w/${slug}/connect`}>连接引导</Link>。
						</p>
					</div>
					<button
						type="button"
						className="join-button join-button--primary"
						onClick={() => setShowForm(true)}
					>
						<Icon name="plus" />
						签发新 token
					</button>
				</header>

				{/* 一次性明文展示（仅签发成功瞬间） */}
				{freshToken && (
					<div className="mcp-token-once" role="status">
						<p>
							<strong>{freshToken.name}</strong> 的连接 token
							只显示这一次，请立即复制保存：
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
								{copiedFresh ? "已复制" : "复制"}
							</button>
							<button
								type="button"
								className="join-button join-button--ghost"
								onClick={() => setFreshToken(null)}
							>
								我已保存
							</button>
						</div>
						{copyFreshFailed && (
							<p className="mcp-copy-error" role="alert">
								复制失败，请手动选择上方 token 文本复制。
							</p>
						)}
					</div>
				)}

				{/* 签发表单 */}
				{showForm && (
					<div className="invitation-form-card">
						<h2>签发新连接 token</h2>
						<div className="invitation-form">
							<label className="join-field">
								<span>备注名称（标识设备或客户端）</span>
								<input
									type="text"
									className="join-input"
									placeholder="如：我的 Mac"
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
									{formSubmitting ? "签发中…" : "签发"}
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
									取消
								</button>
							</div>
						</div>
					</div>
				)}

				{(wsLoading || loading) && (
					<div className="settings-loading" aria-label="加载中">
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
							重试
						</button>
					</div>
				)}

				{!loading && !error && tokens.length === 0 && (
					<div className="settings-empty">
						<Icon name="invite" />
						<p>暂无连接 token</p>
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
											签发于 {formatDateTime(token.insertedAt)} · 最近使用{" "}
											{formatDateTime(token.lastUsedAt)}
										</div>
									</div>
									<div className="invitation-card__actions">
										<span
											className={`l-badge ${
												token.status === "active"
													? "l-badge-volunteer"
													: "l-badge-member"
											}`}
										>
											{token.status === "active" ? "有效" : "已撤销"}
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
															? "撤销中…"
															: "确认撤销"}
													</button>
													<button
														type="button"
														className="join-button join-button--ghost"
														disabled={revokingId === token.id}
														onClick={() => setConfirmRevokeId(null)}
													>
														取消
													</button>
												</>
											) : (
												<button
													type="button"
													className="join-button join-button--outline"
													onClick={() => setConfirmRevokeId(token.id)}
												>
													撤销
												</button>
											))}
									</div>
								</div>
							</div>
						))}
					</div>
				)}

				<section className="mcp-config-section">
					<h2>客户端配置</h2>
					<p className="mcp-config-section__desc">
						把对应客户端的配置片段写入配置文件，并将占位符替换为有效 token。
					</p>
					<McpConfigSnippet />
				</section>
			</div>
		</WorkspaceShell>
	);
}
