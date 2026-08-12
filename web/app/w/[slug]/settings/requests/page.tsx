"use client";

/**
 * B-3 审批页 /w/[slug]/settings/requests。
 *
 * pending 列表（申请人/申请时间/审批倒计时 ApprovalChip <48h 脉冲高亮/留言）
 * + 通过（选角色，默认 member）/ 拒绝（填原因，可选）/ 已过期入口（显示 expired_at，不可审批）。
 * 复用 WorkspaceShell + 能力门控 manage_members。
 */

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
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

/** 审批倒计时组件：<48h 脉冲高亮 */
function ApprovalChip({ deadline }: { deadline: string | null }) {
	const [now, setNow] = useState(() => Date.now());

	useEffect(() => {
		const timer = setInterval(() => setNow(Date.now()), 60000);
		return () => clearInterval(timer);
	}, []);

	const timeLeft = useMemo(() => {
		if (!deadline) return null;
		const deadlineMs = new Date(deadline).getTime();
		const diff = deadlineMs - now;
		if (diff <= 0) return { hours: 0, minutes: 0, expired: true as const };
		return {
			hours: Math.floor(diff / 3600000),
			minutes: Math.floor((diff % 3600000) / 60000),
			expired: false as const,
		};
	}, [deadline, now]);

	if (!timeLeft) return null;
	if (timeLeft.expired) {
		return <span className="approval-chip approval-chip--expired">已过期</span>;
	}

	const urgent = timeLeft.hours < 48;
	return (
		<span
			className={`approval-chip ${urgent ? "approval-chip--urgent" : ""}`}
			title={`审批剩余：${timeLeft.hours} 小时 ${timeLeft.minutes} 分钟`}
		>
			{urgent && <span className="approval-chip__pulse" aria-hidden="true" />}
			{timeLeft.hours > 0
				? `剩余 ${timeLeft.hours}h`
				: `剩余 ${timeLeft.minutes}m`}
		</span>
	);
}

export default function RequestsPage() {
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
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
	const [approveRoles, setApproveRoles] = useState<MembershipRoleName[]>([
		"member",
	]);
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
			setError(e instanceof Error ? e.message : "加载失败");
		} finally {
			setLoading(false);
		}
	}, [ws]);

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
				if (!cancelled) setError(e instanceof Error ? e.message : "加载失败");
			})
			.finally(() => {
				if (!cancelled) setLoading(false);
			});
		return () => {
			cancelled = true;
		};
	}, [ws, canManage]);

	/** 审批通过 */
	const handleApprove = useCallback(async () => {
		if (!approveTarget) return;
		setActionLoading(approveTarget.id);
		try {
			await approveJoinRequest(approveTarget.id, approveRoles);
			setRequests((prev) => prev.filter((r) => r.id !== approveTarget.id));
			setApproveTarget(null);
		} catch (e) {
			setError(e instanceof Error ? e.message : "审批失败");
		} finally {
			setActionLoading(null);
		}
	}, [approveTarget, approveRoles]);

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
			setError(e instanceof Error ? e.message : "拒绝失败");
		} finally {
			setActionLoading(null);
		}
	}, [rejectTarget, rejectReason]);

	/** 可选的审批角色（单一来源 GRANTABLE_ROLE_NAMES = ROLE_NAMES − 管理角色，契约守卫） */
	const approvableRoles = GRANTABLE_ROLE_NAMES;

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
					<strong>加入审批</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>加入审批</h1>
						<p>审批待处理的加入申请</p>
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
					<div className="settings-loading" aria-label="加载中">
						<div className="settings-skeleton settings-skeleton--title" />
						<div className="settings-skeleton" />
					</div>
				)}

				{!canManage && !wsLoading && (
					<div className="settings-note">
						仅具备管理成员能力的用户可查看加入审批。
					</div>
				)}

				{canManage && loading && (
					<div className="settings-loading" aria-label="加载中">
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
							重试
						</button>
					</div>
				)}

				{canManage && !loading && !error && requests.length === 0 && (
					<div className="settings-empty">
						<Icon name="check" />
						<p>暂无待处理的加入申请</p>
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
										通过
									</button>
									<button
										type="button"
										className="join-button join-button--danger"
										onClick={() => setRejectTarget(req)}
										disabled={actionLoading === req.id}
									>
										拒绝
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
							<h2>审批通过</h2>
							<p>为申请人分配角色</p>
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
									disabled={approveRoles.length === 0}
								>
									确认通过
								</button>
								<button
									type="button"
									className="join-button join-button--ghost"
									onClick={() => setApproveTarget(null)}
								>
									取消
								</button>
							</div>
						</div>
					</div>
				)}

				{/* 拒绝弹窗 */}
				{rejectTarget && (
					<div className="modal-overlay" onClick={() => setRejectTarget(null)}>
						<div className="modal-content" onClick={(e) => e.stopPropagation()}>
							<h2>拒绝申请</h2>
							<label className="join-field">
								<span>拒绝原因（可选）</span>
								<textarea
									className="join-textarea"
									placeholder="填写拒绝原因…"
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
									确认拒绝
								</button>
								<button
									type="button"
									className="join-button join-button--ghost"
									onClick={() => {
										setRejectTarget(null);
										setRejectReason("");
									}}
								>
									取消
								</button>
							</div>
						</div>
					</div>
				)}
			</div>
		</WorkspaceShell>
	);
}
