"use client";

/**
 * E-8 #123 审批控制台（kind-agnostic，落地拍板 #3「审批入口 = 网站后台审批页」）。
 *
 * 消费 myPendingApprovals(includeExpired: true)：
 * - pending 区：行形状 D7（kind / requester 摘要 / context 摘要 / approvalDeadline
 *   倒计时，<48h 琥珀脉冲），按 kind dispatch 通过/拒绝——enrollment →
 *   confirmEnrollment/rejectEnrollment；join_request → 既有 approve/rejectJoinRequest。
 * - expired 区：「已过期」+ 过期时间，只读（不可通过/拒绝；重提是申请者侧动作，
 *   过期后唯一索引已放行重新报名/申请）；每行按 kind 加重提链接（E-9 #123 补差）：
 *   enrollment → /participations；join_request → /join?workspace=<slug>；
 *   sponsorship event 级 → /events/<slug>（公开页含「赞助本场」入口）；workspace 级
 *   → /w/<slug>（无公开赞助入口，注明并链工作台概览）。
 * - deadline 时序边界（E-9）：pending 行操作按钮按行级 approvalDeadline > now 守卫，
 *   与 ApprovalChip 同源判定——ApprovalExpiryWorker 落库前的短窗口内不渲染假按钮
 *   （后端 claim 守卫已拒，前端展示对齐；展示仍含过期 pending 行，KTD8 口径）。
 * - 不含 WorkflowRun-waiting（StepAuthorization 是 run 内授权，语义不同，D7）。
 */

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useTranslations } from "next-intl";
import { useQuery } from "@apollo/client/react";
import { client } from "@/lib/apollo-client";
import { useAuthed } from "@/lib/use-authed";
import {
	MY_PENDING_APPROVALS,
	CONFIRM_ENROLLMENT,
	REJECT_ENROLLMENT,
	type PendingApprovalItem,
} from "@/lib/graphql/approvals";
import { approveJoinRequest, rejectJoinRequest } from "@/lib/requests";
import { ApprovalChip } from "@/components/approval-chip";
import {
	APPROVE_SPONSORSHIP,
	REJECT_SPONSORSHIP,
} from "@/lib/graphql/sponsorship";

/** E-9 #123 expired 行重提链接落点；slug 缺失（历史行/无 slug 供给物）→ null 降级纯文本 */
function resubmitHref(item: PendingApprovalItem): string | null {
	if (item.kind === "enrollment") return "/participations";
	if (item.kind === "join_request") {
		return item.workspaceSlug ? `/join?workspace=${item.workspaceSlug}` : null;
	}
	if (item.kind === "sponsorship") {
		// event 级 → 目标活动公开页（含「赞助本场」意向入口）；workspace 级无公开
		// 赞助入口 → 链 workspace 概览（行内注明）
		if (item.level !== "workspace") {
			return item.eventSlug ? `/events/${item.eventSlug}` : null;
		}
		return item.workspaceSlug ? `/w/${item.workspaceSlug}` : null;
	}
	return null;
}

/** 与 ApprovalChip 同源：approvalDeadline <= now 视为已过期（E-9 行级行为守卫） */
function deadlinePassed(item: PendingApprovalItem, now: number): boolean {
	if (!item.approvalDeadline) return false;
	return new Date(item.approvalDeadline).getTime() <= now;
}

function kindLabel(
	item: PendingApprovalItem,
	t: ReturnType<typeof useTranslations<"approvals">>,
): string {
	if (item.kind === "enrollment") {
		return item.courseId ? t("kindEnrollmentCourse") : t("kindEnrollmentEvent");
	}
	if (item.kind === "join_request") return t("kindJoinRequest");
	if (item.kind === "sponsorship") {
		return item.level === "workspace"
			? t("kindSponsorshipWorkspace")
			: t("kindSponsorshipEvent");
	}
	return item.kind;
}

function formatDateTime(iso: string | null | undefined): string {
	if (!iso) return "—";
	const d = new Date(iso);
	return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(
		d.getDate(),
	).padStart(2, "0")} ${String(d.getHours()).padStart(2, "0")}:${String(
		d.getMinutes(),
	).padStart(2, "0")}`;
}

export default function ApprovalsPage() {
	const router = useRouter();
	const t = useTranslations("approvals");
	const { authed, confirmed } = useAuthed();
	const { data, loading, error, refetch } = useQuery(MY_PENDING_APPROVALS, {
		variables: { includeExpired: true },
		skip: !authed,
	});

	const [busyId, setBusyId] = useState<string | null>(null);
	const [rejectingId, setRejectingId] = useState<string | null>(null);
	const [rejectReason, setRejectReason] = useState("");
	const [actionError, setActionError] = useState<string | null>(null);

	// E-9 deadline 行级守卫时钟：60s 一拍（ApprovalChip 同频），判定与 chip 同源
	// （approvalDeadline <= now 视为已过期）——ApprovalExpiryWorker 落库前的
	// 短窗口内 pending 行不渲染操作按钮。
	const [now, setNow] = useState(() => Date.now());

	useEffect(() => {
		const timer = setInterval(() => setNow(Date.now()), 60000);
		return () => clearInterval(timer);
	}, []);

	const rows = useMemo(() => data?.myPendingApprovals ?? [], [data]);
	const pendingRows = useMemo(() => rows.filter((r) => r.status === "pending"), [rows]);
	const expiredRows = useMemo(() => rows.filter((r) => r.status === "expired"), [rows]);

	const decide = useCallback(
		async (item: PendingApprovalItem, decision: "approve" | "reject", reason?: string) => {
			setBusyId(item.id);
			setActionError(null);
			try {
				if (item.kind === "enrollment") {
					const payload =
						decision === "approve"
							? (
									await client.mutate({
										mutation: CONFIRM_ENROLLMENT,
										variables: { id: item.id },
									})
								).data?.confirmEnrollment
							: (
									await client.mutate({
										mutation: REJECT_ENROLLMENT,
										variables: {
											id: item.id,
											input: { rejectionReason: reason?.trim() || undefined },
										},
									})
								).data?.rejectEnrollment;
					if (!payload?.result) {
						throw new Error(payload?.errors?.[0]?.message ?? t("actionFailed"));
					}
				} else if (item.kind === "sponsorship") {
					// E-3 #48：kind dispatch 增量——approve/reject sponsorship
					// （reject 带 reason 落审计字段；Workspace 级仅 Owner，Admin
					// 被后端 SponsorshipApprover policy 拒绝，错误经 payload.errors 回显）
					const payload =
						decision === "approve"
							? (
									await client.mutate({
										mutation: APPROVE_SPONSORSHIP,
										variables: { id: item.id },
									})
								).data?.approveSponsorship
							: (
									await client.mutate({
										mutation: REJECT_SPONSORSHIP,
										variables: {
											id: item.id,
											input: { rejectionReason: reason?.trim() || undefined },
										},
									})
								).data?.rejectSponsorship;
					if (!payload?.result) {
						throw new Error(payload?.errors?.[0]?.message ?? t("actionFailed"));
					}
				} else if (decision === "approve") {
					await approveJoinRequest(item.id);
				} else {
					await rejectJoinRequest(item.id, reason?.trim() || null);
				}
				setRejectingId(null);
				setRejectReason("");
				await refetch();
			} catch (e) {
				setActionError(e instanceof Error ? e.message : t("actionFailed"));
			} finally {
				setBusyId(null);
			}
		},
		[refetch, t],
	);

	if (!confirmed) {
		return (
			<main className="ws-shell-loading">
				<span>{t("loading")}</span>
			</main>
		);
	}
	if (!authed) {
		router.replace(`/login?next=${encodeURIComponent("/approvals")}`);
		return null;
	}

	return (
		<main className="approvals-page">
			<nav className="approvals-breadcrumb" aria-label={t("breadcrumbAria")}>
				<Link href="/">{t("breadcrumbHome")}</Link>
				<span aria-hidden="true"> &gt; </span>
				<span>{t("breadcrumbApprovals")}</span>
			</nav>

			<header className="approvals-header">
				<h1>{t("title")}</h1>
				<p>{t("subtitle")}</p>
			</header>

			{actionError && (
				<div role="alert" className="auth-alert">
					{actionError}
				</div>
			)}

			{loading && <p>{t("loading")}</p>}
			{error && (
				<div role="alert" className="auth-alert">
					{t("loadFailed")}
				</div>
			)}

			{!loading && !error && pendingRows.length === 0 && (
				<p className="approvals-empty">{t("empty")}</p>
			)}

			<section className="approvals-list" aria-label={t("pendingSectionAria")}>
				{pendingRows.map((item) => (
					<article key={item.id} className="join-card approvals-row">
						<div className="approvals-row__main">
							<span className="approvals-row__kind">{kindLabel(item, t)}</span>
							<div className="approvals-row__text">
								<strong>{item.requesterName ?? "—"}</strong>
								<span>
									{item.contextTitle ?? "—"} · {item.workspaceName ?? "—"}
									{item.tierName ? ` · ${item.tierName}` : ""}
								</span>
							</div>
							<ApprovalChip deadline={item.approvalDeadline ?? null} />
						</div>
						{rejectingId === item.id ? (
							<div className="approvals-row__reject">
								<input
									type="text"
									value={rejectReason}
									onChange={(e) => setRejectReason(e.target.value)}
									placeholder={t("rejectReasonLabel")}
									aria-label={t("rejectReasonAria")}
								/>
								<button
									type="button"
									className="join-button join-button--primary"
									disabled={busyId === item.id}
									onClick={() => decide(item, "reject", rejectReason)}
								>
									{t("confirmReject")}
								</button>
								<button
									type="button"
									className="join-button"
									onClick={() => {
										setRejectingId(null);
										setRejectReason("");
									}}
								>
									{t("cancel")}
								</button>
							</div>
						) : deadlinePassed(item, now) ? (
							// E-9：ApprovalExpiryWorker 落库前短窗口——deadline 已过仍
							// status=pending 的行不渲染假按钮（后端 claim 守卫同口径）
							<p className="approvals-row__expired-note">
								{t("expiredNote")}
							</p>
						) : (
							<div className="approvals-row__actions">
								<button
									type="button"
									className="join-button join-button--primary"
									disabled={busyId === item.id}
									onClick={() => decide(item, "approve")}
								>
									{t("approve")}
								</button>
								<button
									type="button"
									className="join-button"
									disabled={busyId === item.id}
									onClick={() => setRejectingId(item.id)}
								>
									{t("reject")}
								</button>
							</div>
						)}
					</article>
				))}
			</section>

			{expiredRows.length > 0 && (
				<section className="approvals-expired" aria-label={t("expiredSectionAria")}>
					<h2>{t("expiredTitle")}</h2>
					<p className="approvals-expired__hint">{t("expiredHint")}</p>
					{expiredRows.map((item) => {
						const href = resubmitHref(item);
						return (
							<article
								key={item.id}
								className="join-card approvals-row approvals-row--expired"
							>
								<div className="approvals-row__main">
									<span className="approvals-row__kind">{kindLabel(item, t)}</span>
									<div className="approvals-row__text">
										<strong>{item.requesterName ?? "—"}</strong>
										<span>
											{item.contextTitle ?? "—"} · {item.workspaceName ?? "—"}
											{item.tierName ? ` · ${item.tierName}` : ""}
										</span>
									</div>
									<span className="approval-chip approval-chip--expired">
										{t("expiredAt", { time: formatDateTime(item.expiredAt) })}
									</span>
								</div>
								{/* E-9 #123 补差：expired 行按 kind 加重提链接（申请者可重新提交；
									落点在申请者侧页面，此处为可分享的入口链接） */}
								<div className="approvals-row__actions">
									{href ? (
										<Link href={href} className="join-button">
											{t("expiredResubmit")}
										</Link>
									) : (
										<span className="approvals-row__expired-note">
											{t("expiredResubmit")}
										</span>
									)}
									{item.kind === "sponsorship" && item.level === "workspace" && (
										<span className="approvals-row__expired-note">
											{t("noPublicSponsor")}
										</span>
									)}
								</div>
							</article>
						);
					})}
				</section>
			)}
		</main>
	);
}
