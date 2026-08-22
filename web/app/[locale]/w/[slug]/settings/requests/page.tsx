"use client";

/**
 * B-3 审批页 /w/[slug]/settings/requests。
 *
 * pending 列表（申请人/申请时间/审批倒计时 ApprovalChip <48h 脉冲高亮/留言）
 * + 通过（选角色，默认无标签）/ 拒绝（填原因，可选）/ 已过期入口（显示 expired_at，不可审批）。
 * 复用 WorkspaceShell + 能力门控 manage_members。
 */

import { useCallback, useEffect, useRef, useState } from "react";
import { Link } from "@/i18n/navigation";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import {
	fetchJoinRequests,
	approveJoinRequest,
	rejectJoinRequest,
} from "@/lib/requests";
import type { JoinRequestItem } from "@/lib/requests";
import {
	GRANTABLE_ROLE_NAMES,
	type MembershipRoleName,
} from "@/lib/graphql/workspace";
import WorkspaceShell from "@/components/workspace-shell";
import MembersTabs from "@/components/members-tabs";
import { Icon } from "@/components/icons";
import { ApprovalChip } from "@/components/approval-chip";

export default function RequestsPage() {
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const t = useTranslations("workspaceRequests");
	const tCommon = useTranslations("common");
	const { ws, loading: wsLoading } = useWorkspaceBySlug(slug);
	const canManage = ws?.myAbilities?.includes("manage_members") ?? false;

	const [requests, setRequests] = useState<JoinRequestItem[]>([]);
	const [loading, setLoading] = useState(true);
	const [error, setError] = useState<string | null>(null);
	const [actionLoading, setActionLoading] = useState<string | null>(null);
	const loadedRef = useRef(false);

	// 审批弹窗状态
	const [approveTarget, setApproveTarget] = useState<JoinRequestItem | null>(
		null,
	);
	const [approveRoles, setApproveRoles] = useState<MembershipRoleName[]>([]);
	const [rejectTarget, setRejectTarget] = useState<JoinRequestItem | null>(
		null,
	);
	const [rejectReason, setRejectReason] = useState("");

	/** 加载 pending 申请 */
	const loadRequests = useCallback(async () => {
		if (!ws) return;
		setLoading(true);
		setError(null);
		try {
			const page = await fetchJoinRequests(ws.id, { status: "pending" });
			setRequests(page.items);
		} catch (e) {
			setError(e instanceof Error ? e.message : t("loadFailed"));
		} finally {
			setLoading(false);
		}
	}, [ws, t]);

	// 首次加载：ws 就绪后触发一次数据加载
	useEffect(() => {
		if (!ws || loadedRef.current) return;
		loadedRef.current = true;
		if (!canManage) {
			// plan 016：与邀请页同修 —— 无管理能力也要结束加载态，否则 loading 永真。
			// 微任务提交，避免 react-hooks/set-state-in-effect 同步 setState
			queueMicrotask(() => setLoading(false));
			return;
		}
		let cancelled = false;
		fetchJoinRequests(ws.id, { status: "pending" })
			.then((page) => {
				if (!cancelled) setRequests(page.items);
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

	/** 审批通过 */
	const handleApprove = useCallback(async () => {
		if (!approveTarget) return;
		setActionLoading(approveTarget.id);
		try {
			await approveJoinRequest(approveTarget.id, approveRoles);
			setRequests((prev) => prev.filter((r) => r.id !== approveTarget.id));
			setApproveTarget(null);
		} catch (e) {
			setError(e instanceof Error ? e.message : t("approveFailed"));
		} finally {
			setActionLoading(null);
		}
	}, [approveTarget, approveRoles, t]);

	/** 拒绝 */
	const handleReject = useCallback(async () => {
		if (!rejectTarget) return;
		setActionLoading(rejectTarget.id);
		try {
			await rejectJoinRequest(rejectTarget.id, rejectReason || null);
			setRequests((prev) => prev.filter((r) => r.id !== rejectTarget.id));
			setRejectTarget(null);
			setRejectReason("");
		} catch (e) {
			setError(e instanceof Error ? e.message : t("rejectFailed"));
		} finally {
			setActionLoading(null);
		}
	}, [rejectTarget, rejectReason, t]);

	/** 可选的审批角色（单一来源 GRANTABLE_ROLE_NAMES = ROLE_NAMES − 管理角色，契约守卫） */
	const approvableRoles = GRANTABLE_ROLE_NAMES;

	return (
		<WorkspaceShell slug={slug} requireAbility="manage_members">
			<div className="ws-page-main__inner">
				<div
					className="ws-page-breadcrumb"
					aria-label={tCommon("breadcrumbAria")}
				>
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
				</header>

				{ws && (
					<MembersTabs
						slug={slug}
						current="requests"
						abilities={ws.myAbilities ?? []}
					/>
				)}

				{wsLoading && (
					<div
						className="settings-loading"
						aria-label={t("loadingAria")}
					>
						<div className="settings-skeleton settings-skeleton--title" />
						<div className="settings-skeleton" />
					</div>
				)}

				{!canManage && !wsLoading && (
					<div className="settings-note">{t("manageNote")}</div>
				)}

				{canManage && loading && (
					<div
						className="settings-loading"
						aria-label={t("loadingAria")}
					>
						<div className="settings-skeleton settings-skeleton--title" />
						<div className="settings-skeleton" />
						<div className="settings-skeleton" />
					</div>
				)}

				{error && (
					<div className="members-error" role="alert">
						{error}
						<button
							type="button"
							className="join-button join-button--outline"
							onClick={loadRequests}
						>
							{t("retry")}
						</button>
					</div>
				)}

				{canManage && !loading && !error && requests.length === 0 && (
					<div className="settings-empty">
						<Icon name="check" />
						<p>{t("empty")}</p>
					</div>
				)}

				{canManage && requests.length > 0 && (
					<div className="requests-list">
						{requests.map((req) => (
							<div className="request-card" key={req.id}>
								<div className="request-card__header">
									<div className="request-card__user">
										<span className="request-card__avatar">
											{req.userId.slice(0, 2).toUpperCase()}
										</span>
										<div>
											<strong>{req.userId}</strong>
											{req.message && (
												<p className="request-card__message">{req.message}</p>
											)}
										</div>
									</div>
									<ApprovalChip deadline={req.approvalDeadline ?? null} />
								</div>
								<div className="request-card__actions">
									<button
										type="button"
										className="join-button join-button--primary"
										onClick={() => setApproveTarget(req)}
										disabled={actionLoading === req.id}
									>
										{t("approve")}
									</button>
									<button
										type="button"
										className="join-button join-button--danger"
										onClick={() => setRejectTarget(req)}
										disabled={actionLoading === req.id}
									>
										{t("reject")}
									</button>
								</div>
							</div>
						))}
					</div>
				)}

				{/* 通过弹窗 */}
				{approveTarget && (
					<div className="modal-overlay" onClick={() => setApproveTarget(null)}>
						<div className="modal-content" onClick={(e) => e.stopPropagation()}>
							<h2>{t("approveModalTitle")}</h2>
							<p>{t("approveModalDesc")}</p>
							<div className="modal-role-select">
								{approvableRoles.map((role) => (
									<label key={role} className="modal-role-option">
										<input
											type="checkbox"
											checked={approveRoles.includes(role)}
											onChange={() => {
												setApproveRoles((prev) =>
													prev.includes(role)
														? prev.filter((r) => r !== role)
														: [...prev, role],
												);
											}}
										/>
										<span>{role}</span>
									</label>
								))}
							</div>
							<div className="modal-actions">
								<button
									type="button"
									className="join-button join-button--primary"
									onClick={handleApprove}
								>
									{t("confirmApprove")}
								</button>
								<button
									type="button"
									className="join-button join-button--ghost"
									onClick={() => setApproveTarget(null)}
								>
									{t("cancel")}
								</button>
							</div>
						</div>
					</div>
				)}

				{/* 拒绝弹窗 */}
				{rejectTarget && (
					<div className="modal-overlay" onClick={() => setRejectTarget(null)}>
						<div className="modal-content" onClick={(e) => e.stopPropagation()}>
							<h2>{t("rejectModalTitle")}</h2>
							<label className="join-field">
								<span>{t("rejectReasonLabel")}</span>
								<textarea
									className="join-textarea"
									placeholder={t("rejectReasonPlaceholder")}
									value={rejectReason}
									onChange={(e) => setRejectReason(e.target.value)}
									rows={3}
								/>
							</label>
							<div className="modal-actions">
								<button
									type="button"
									className="join-button join-button--danger"
									onClick={handleReject}
								>
									{t("confirmReject")}
								</button>
								<button
									type="button"
									className="join-button join-button--ghost"
									onClick={() => {
										setRejectTarget(null);
										setRejectReason("");
									}}
								>
									{t("cancel")}
								</button>
							</div>
						</div>
					</div>
				)}
			</div>
		</WorkspaceShell>
	);
}
