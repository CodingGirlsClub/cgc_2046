"use client";

/**
 * B-3 邀请管理页 /w/[slug]/settings/invitations。
 *
 * 创建表单（预授权角色多选 + 目标邮箱可选 + expires_at 可选）
 * + 邀请列表（状态 active/used/revoked/expired + 复制链接 + 撤销按钮）
 * + Volunteer 角色过滤（不可选 admin/owner，Role.manage_roles）。
 * 双主题。
 */

import { useCallback, useEffect, useRef, useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import { useAuthed } from "@/lib/use-authed";
import {
	fetchInvitations,
	createInvitation,
	revokeInvitation,
	invitationRoleLabel,
} from "@/lib/invitations";
import type { InvitationItem } from "@/lib/invitations";
import {
	INVITATION_STATUS_LABEL,
	INVITATION_STATUS_CLASS,
} from "@/lib/graphql/invitation";
import {
	GRANTABLE_ROLE_NAMES,
	type MembershipRoleName,
} from "@/lib/graphql/workspace";
import WorkspaceShell from "@/components/workspace-shell";
import MembersTabs from "@/components/members-tabs";
import { Icon } from "@/components/icons";

export default function InvitationsPage() {
	const t = useTranslations("workspaceInvitations");
	const tCommon = useTranslations("common");
	const labelsT = useTranslations();
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const { ws, loading: wsLoading } = useWorkspaceBySlug(slug);
	const { userId } = useAuthed();
	const canManage = ws?.myAbilities?.includes("manage_members") ?? false;

	const [invitations, setInvitations] = useState<InvitationItem[]>([]);
	const [loading, setLoading] = useState(true);
	const [error, setError] = useState<string | null>(null);
	const [actionLoading, setActionLoading] = useState<string | null>(null);
	const loadedRef = useRef(false);

	// 创建表单状态
	const [showForm, setShowForm] = useState(false);
	const [formTargetEmail, setFormTargetEmail] = useState("");
	const [formRoles, setFormRoles] = useState<MembershipRoleName[]>([]);
	const [formExpiresAt, setFormExpiresAt] = useState("");
	const [formSubmitting, setFormSubmitting] = useState(false);
	const [formError, setFormError] = useState<string | null>(null);
	const [copiedId, setCopiedId] = useState<string | null>(null);

	// 首次加载
	useEffect(() => {
		if (!ws || loadedRef.current) return;
		loadedRef.current = true;
		if (!canManage) {
			// plan 016：无管理能力也要结束加载态，否则 loading 永真（B-3 bug）。
			// 微任务提交，避免 react-hooks/set-state-in-effect 同步 setState
			queueMicrotask(() => setLoading(false));
			return;
		}
		let cancelled = false;
		fetchInvitations(ws.id)
			.then((page) => {
				if (!cancelled) setInvitations(page.items);
			})
			.catch((e) => {
				if (!cancelled)
					setError(e instanceof Error ? e.message : t("loadFailed"));
			})
			.finally(() => {
				if (!cancelled) setLoading(false);
			});
		return () => {
			cancelled = true;
		};
	}, [ws, canManage, t]);

	/** 加载邀请列表 */
	const loadInvitations = useCallback(async () => {
		if (!ws) return;
		setLoading(true);
		setError(null);
		try {
			const page = await fetchInvitations(ws.id);
			setInvitations(page.items);
		} catch (e) {
			setError(e instanceof Error ? e.message : t("loadFailed"));
		} finally {
			setLoading(false);
		}
	}, [ws, t]);

	/** 创建邀请 */
	const handleCreate = useCallback(async () => {
		if (!ws || !userId) return;
		setFormSubmitting(true);
		setFormError(null);
		try {
			const inv = await createInvitation({
				workspaceId: ws.id,
				inviterId: userId,
				targetEmail: formTargetEmail.trim() || null,
				preauthorizedRoleNames: formRoles.length > 0 ? formRoles : null,
				expiresAt: formExpiresAt || null,
			});
			setInvitations((prev) => [inv, ...prev]);
			setShowForm(false);
			setFormTargetEmail("");
			setFormRoles([]);
			setFormExpiresAt("");
		} catch (e) {
			setFormError(e instanceof Error ? e.message : t("createFailed"));
		} finally {
			setFormSubmitting(false);
		}
	}, [ws, userId, formTargetEmail, formRoles, formExpiresAt, t]);

	/** 撤销邀请 */
	const handleRevoke = useCallback(async (id: string) => {
		setActionLoading(id);
		try {
			await revokeInvitation(id);
			setInvitations((prev) =>
				prev.map((inv) =>
					inv.id === id ? { ...inv, status: "revoked" as const } : inv,
				),
			);
		} catch (e) {
			setError(e instanceof Error ? e.message : t("revokeFailed"));
		} finally {
			setActionLoading(null);
		}
	}, [t]);

	/** 复制邀请链接（仅创建时返回明文 token 的邀请可复制；历史邀请 token 不落库，无法重新复制） */
	const handleCopyLink = useCallback((inv: InvitationItem) => {
		if (!inv.plainToken) return;
		const baseUrl = window.location.origin;
		const link = `${baseUrl}/join?token=${inv.plainToken}`;
		navigator.clipboard.writeText(link).then(() => {
			setCopiedId(inv.id);
			setTimeout(() => setCopiedId(null), 2000);
		});
	}, []);

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
					<strong>{t("breadcrumbTitle")}</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>{t("title")}</h1>
						<p>{t("subtitle")}</p>
					</div>
					{canManage && (
						<button
							type="button"
							className="join-button join-button--primary"
							onClick={() => setShowForm(true)}
						>
							<Icon name="plus" />
							{t("createInvite")}
						</button>
					)}
				</header>

				{ws && (
					<MembersTabs
						slug={slug}
						current="invitations"
						abilities={ws.myAbilities ?? []}
					/>
				)}

				{wsLoading && (
					<div className="settings-loading" aria-label={t("loadingAria")}>
						<div className="settings-skeleton settings-skeleton--title" />
						<div className="settings-skeleton" />
					</div>
				)}

				{!canManage && !wsLoading && (
					<div className="settings-note">{t("manageNote")}</div>
				)}

				{/* 创建表单 */}
				{showForm && canManage && (
					<div className="invitation-form-card">
						<h2>{t("createHeading")}</h2>
						<div className="invitation-form">
							<label className="join-field">
								<span>{t("targetEmail")}</span>
								<input
									type="email"
									className="join-input"
									placeholder="user@example.com"
									value={formTargetEmail}
									onChange={(e) => setFormTargetEmail(e.target.value)}
									disabled={formSubmitting}
								/>
							</label>
							{/* 多选组不可用 label 嵌套包裹（W3C：label 不得嵌套；组用容器元素）。
							    外层曾是 label——happy-dom 按 label activation 会把 click 转发给组内
							    首个 input 造成双 toggle，也暴露了嵌套语义本身的问题。 */}
							<div className="join-field">
								<span>{t("preauthRoles")}</span>
								<div className="invitation-role-select">
									{GRANTABLE_ROLE_NAMES.map((role) => (
										<label key={role} className="invitation-role-option">
											<input
												type="checkbox"
												aria-label={t("roleAria", { role })}
												checked={formRoles.includes(role)}
												onChange={() => {
													setFormRoles((prev) =>
														prev.includes(role)
															? prev.filter((r) => r !== role)
															: [...prev, role],
													);
												}}
												disabled={formSubmitting}
											/>
											<span>{role}</span>
										</label>
									))}
								</div>
							</div>
							<label className="join-field">
								<span>{t("expiresAt")}</span>
								<input
									type="datetime-local"
									className="join-input"
									value={formExpiresAt}
									onChange={(e) => setFormExpiresAt(e.target.value)}
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
									onClick={handleCreate}
									disabled={formSubmitting}
								>
									{formSubmitting ? t("creating") : t("create")}
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

				{error && (
					<div className="members-error" role="alert">
						{error}
						<button
							type="button"
							className="join-button join-button--outline"
							onClick={loadInvitations}
						>
							{t("retry")}
						</button>
					</div>
				)}

				{canManage && !loading && !error && invitations.length === 0 && (
					<div className="settings-empty">
						<Icon name="invite" />
						<p>{t("empty")}</p>
					</div>
				)}

				{canManage && invitations.length > 0 && (
					<div className="invitations-list">
						{invitations.map((inv) => (
							<div className="invitation-card" key={inv.id}>
								<div className="invitation-card__header">
									<div className="invitation-card__info">
										<strong>{inv.targetEmail ?? t("publicLink")}</strong>
										{inv.preauthorizedRoleNames &&
											inv.preauthorizedRoleNames.length > 0 && (
												<div className="invitation-card__roles">
													{inv.preauthorizedRoleNames.map((role) => (
														<span className="workspace-role-chip" key={role}>
															{invitationRoleLabel(role, labelsT("labels.memberNoLabel"))}
														</span>
													))}
												</div>
											)}
									</div>
									<span
										className={`invitation-status ${INVITATION_STATUS_CLASS[inv.status]}`}
									>
										{labelsT(INVITATION_STATUS_LABEL[inv.status])}
									</span>
								</div>
								{inv.expiresAt && (
									<p className="invitation-card__expires">
										{t("expiresLabel", {
											time: new Date(inv.expiresAt).toLocaleString(),
										})}
									</p>
								)}
								<div className="invitation-card__actions">
									{inv.status === "active" && (
										<>
											<button
												type="button"
												className="join-button join-button--outline"
												onClick={() => handleCopyLink(inv)}
												disabled={!inv.plainToken}
												title={
													inv.plainToken
														? t("copyInviteLink")
														: t("tokenOnce")
												}
											>
												{copiedId === inv.id ? t("copied") : t("copyLink")}
											</button>
											<button
												type="button"
												className="join-button join-button--danger"
												onClick={() => handleRevoke(inv.id)}
												disabled={actionLoading === inv.id}
											>
												{actionLoading === inv.id ? t("revoking") : t("revoke")}
											</button>
										</>
									)}
								</div>
							</div>
						))}
					</div>
				)}
			</div>
		</WorkspaceShell>
	);
}
