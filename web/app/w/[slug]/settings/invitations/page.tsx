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
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import { useAuthed } from "@/lib/use-authed";
import {
	fetchInvitations,
	createInvitation,
	revokeInvitation,
} from "@/lib/invitations";
import type { InvitationItem } from "@/lib/invitations";
import {
	INVITATION_STATUS_LABEL,
	INVITATION_STATUS_CLASS,
} from "@/lib/graphql/join";
import { ROLE_NAMES, type MembershipRoleName } from "@/lib/graphql/workspace";
import WorkspaceShell from "@/components/workspace-shell";
import { Icon } from "@/components/icons";

/** 可选的邀请角色（排除 owner/admin，Volunteer 不可预授权 Admin 级角色） */
const INVITABLE_ROLES = ROLE_NAMES.filter(
	(r) => r !== "owner" && r !== "admin",
);

export default function InvitationsPage() {
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
		if (!canManage) return;
		let cancelled = false;
		fetchInvitations(ws.id)
			.then((page) => {
				if (!cancelled) setInvitations(page.items);
			})
			.catch((e) => {
				if (!cancelled) setError(e instanceof Error ? e.message : "加载失败");
			})
			.finally(() => {
				if (!cancelled) setLoading(false);
			});
		return () => {
			cancelled = true;
		};
	}, [ws, canManage]);

	/** 加载邀请列表 */
	const loadInvitations = useCallback(async () => {
		if (!ws) return;
		setLoading(true);
		setError(null);
		try {
			const page = await fetchInvitations(ws.id);
			setInvitations(page.items);
		} catch (e) {
			setError(e instanceof Error ? e.message : "加载失败");
		} finally {
			setLoading(false);
		}
	}, [ws]);

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
			setFormError(e instanceof Error ? e.message : "创建失败");
		} finally {
			setFormSubmitting(false);
		}
	}, [ws, userId, formTargetEmail, formRoles, formExpiresAt]);

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
			setError(e instanceof Error ? e.message : "撤销失败");
		} finally {
			setActionLoading(null);
		}
	}, []);

	/** 复制邀请链接 */
	const handleCopyLink = useCallback((inv: InvitationItem) => {
		const baseUrl = window.location.origin;
		const link = `${baseUrl}/join?token=${inv.plainToken ?? inv.id}`;
		navigator.clipboard.writeText(link).then(() => {
			setCopiedId(inv.id);
			setTimeout(() => setCopiedId(null), 2000);
		});
	}, []);

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label="页面路径">
					<Link href={`/w/${slug}/settings`}>工作区设置</Link>
					<span>›</span>
					<strong>邀请管理</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>邀请管理</h1>
						<p>创建和管理加入邀请</p>
					</div>
					{canManage && (
						<button
							type="button"
							className="join-button join-button--primary"
							onClick={() => setShowForm(true)}
						>
							<Icon name="plus" />
							创建邀请
						</button>
					)}
				</header>

				{wsLoading && (
					<div className="settings-loading" aria-label="加载中">
						<div className="settings-skeleton settings-skeleton--title" />
						<div className="settings-skeleton" />
					</div>
				)}

				{!canManage && !wsLoading && (
					<div className="settings-note">
						仅具备管理成员能力的用户可管理邀请。
					</div>
				)}

				{/* 创建表单 */}
				{showForm && canManage && (
					<div className="invitation-form-card">
						<h2>创建新邀请</h2>
						<div className="invitation-form">
							<label className="join-field">
								<span>目标邮箱（可选，空=公开链接）</span>
								<input
									type="email"
									className="join-input"
									placeholder="user@example.com"
									value={formTargetEmail}
									onChange={(e) => setFormTargetEmail(e.target.value)}
									disabled={formSubmitting}
								/>
							</label>
							<label className="join-field">
								<span>预授权角色（可选，多选）</span>
								<div className="invitation-role-select">
									{INVITABLE_ROLES.map((role) => (
										<label key={role} className="invitation-role-option">
											<input
												type="checkbox"
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
							</label>
							<label className="join-field">
								<span>过期时间（可选）</span>
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
									{formSubmitting ? "创建中…" : "创建邀请"}
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

				{error && (
					<div className="members-error" role="alert">
						{error}
						<button
							type="button"
							className="join-button join-button--outline"
							onClick={loadInvitations}
						>
							重试
						</button>
					</div>
				)}

				{canManage && !loading && !error && invitations.length === 0 && (
					<div className="settings-empty">
						<Icon name="invite" />
						<p>暂无邀请记录</p>
					</div>
				)}

				{canManage && invitations.length > 0 && (
					<div className="invitations-list">
						{invitations.map((inv) => (
							<div className="invitation-card" key={inv.id}>
								<div className="invitation-card__header">
									<div className="invitation-card__info">
										<strong>{inv.targetEmail ?? "公开链接"}</strong>
										{inv.preauthorizedRoleNames &&
											inv.preauthorizedRoleNames.length > 0 && (
												<div className="invitation-card__roles">
													{inv.preauthorizedRoleNames.map((role) => (
														<span className="workspace-role-chip" key={role}>
															{role}
														</span>
													))}
												</div>
											)}
									</div>
									<span
										className={`invitation-status ${INVITATION_STATUS_CLASS[inv.status]}`}
									>
										{INVITATION_STATUS_LABEL[inv.status]}
									</span>
								</div>
								{inv.expiresAt && (
									<p className="invitation-card__expires">
										过期时间：{new Date(inv.expiresAt).toLocaleString()}
									</p>
								)}
								<div className="invitation-card__actions">
									{inv.status === "active" && (
										<>
											<button
												type="button"
												className="join-button join-button--outline"
												onClick={() => handleCopyLink(inv)}
											>
												{copiedId === inv.id ? "已复制" : "复制链接"}
											</button>
											<button
												type="button"
												className="join-button join-button--danger"
												onClick={() => handleRevoke(inv.id)}
												disabled={actionLoading === inv.id}
											>
												{actionLoading === inv.id ? "撤销中…" : "撤销"}
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
