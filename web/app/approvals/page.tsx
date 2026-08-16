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

function kindLabel(item: PendingApprovalItem): string {
	if (item.kind === "enrollment") {
		return item.courseId ? "课程报名" : "活动报名";
	}
	if (item.kind === "join_request") return "加入申请";
	if (item.kind === "sponsorship") {
		return item.level === "workspace" ? "工作台赞助" : "活动赞助";
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
						throw new Error(payload?.errors?.[0]?.message ?? "操作失败，请稍后重试");
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
						throw new Error(payload?.errors?.[0]?.message ?? "操作失败，请稍后重试");
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
				setActionError(e instanceof Error ? e.message : "操作失败，请稍后重试");
			} finally {
				setBusyId(null);
			}
		},
		[refetch],
	);

	if (!confirmed) {
		return (
			<main className="ws-shell-loading">
				<span>加载中…</span>
			</main>
		);
	}
	if (!authed) {
		router.replace(`/login?next=${encodeURIComponent("/approvals")}`);
		return null;
	}

	return (
		<main className="approvals-page">
			<nav className="approvals-breadcrumb" aria-label="面包屑">
				<Link href="/">工作台</Link>
				<span aria-hidden="true"> &gt; </span>
				<span>审批</span>
			</nav>

			<header className="approvals-header">
				<h1>审批中心</h1>
				<p>你作为 Owner / Admin 的跨工作台待审批项（报名、加入申请与赞助意向）。</p>
			</header>

			{actionError && (
				<div role="alert" className="auth-alert">
					{actionError}
				</div>
			)}

			{loading && <p>加载中…</p>}
			{error && (
				<div role="alert" className="auth-alert">
					加载失败，请刷新重试。
				</div>
			)}

			{!loading && !error && pendingRows.length === 0 && (
				<p className="approvals-empty">暂无待审批项。</p>
			)}

			<section className="approvals-list" aria-label="待审批">
				{pendingRows.map((item) => (
					<article key={item.id} className="join-card approvals-row">
						<div className="approvals-row__main">
							<span className="approvals-row__kind">{kindLabel(item)}</span>
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
									placeholder="拒绝原因（可选）"
									aria-label="拒绝原因"
								/>
								<button
									type="button"
									className="join-button join-button--primary"
									disabled={busyId === item.id}
									onClick={() => decide(item, "reject", rejectReason)}
								>
									确认拒绝
								</button>
								<button
									type="button"
									className="join-button"
									onClick={() => {
										setRejectingId(null);
										setRejectReason("");
									}}
								>
									取消
								</button>
							</div>
						) : deadlinePassed(item, now) ? (
							// E-9：ApprovalExpiryWorker 落库前短窗口——deadline 已过仍
							// status=pending 的行不渲染假按钮（后端 claim 守卫同口径）
							<p className="approvals-row__expired-note">
								审批已超时，等待系统更新状态。
							</p>
						) : (
							<div className="approvals-row__actions">
								<button
									type="button"
									className="join-button join-button--primary"
									disabled={busyId === item.id}
									onClick={() => decide(item, "approve")}
								>
									通过
								</button>
								<button
									type="button"
									className="join-button"
									disabled={busyId === item.id}
									onClick={() => setRejectingId(item.id)}
								>
									拒绝
								</button>
							</div>
						)}
					</article>
				))}
			</section>

			{expiredRows.length > 0 && (
				<section className="approvals-expired" aria-label="已过期">
					<h2>已过期</h2>
					<p className="approvals-expired__hint">
						审批超时的申请不可再通过或拒绝；申请者可重新提交。
					</p>
					{expiredRows.map((item) => {
						const href = resubmitHref(item);
						return (
							<article
								key={item.id}
								className="join-card approvals-row approvals-row--expired"
							>
								<div className="approvals-row__main">
									<span className="approvals-row__kind">{kindLabel(item)}</span>
									<div className="approvals-row__text">
										<strong>{item.requesterName ?? "—"}</strong>
										<span>
											{item.contextTitle ?? "—"} · {item.workspaceName ?? "—"}
											{item.tierName ? ` · ${item.tierName}` : ""}
										</span>
									</div>
									<span className="approval-chip approval-chip--expired">
										已过期 · {formatDateTime(item.expiredAt)}
									</span>
								</div>
								{/* E-9 #123 补差：expired 行按 kind 加重提链接（申请者可重新提交；
									落点在申请者侧页面，此处为可分享的入口链接） */}
								<div className="approvals-row__actions">
									{href ? (
										<Link href={href} className="join-button">
											已过期 · 申请者可重新提交
										</Link>
									) : (
										<span className="approvals-row__expired-note">
											已过期 · 申请者可重新提交
										</span>
									)}
									{item.kind === "sponsorship" && item.level === "workspace" && (
										<span className="approvals-row__expired-note">
											该工作台无公开赞助入口，请前往工作台概览。
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
