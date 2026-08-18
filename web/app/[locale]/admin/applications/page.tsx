"use client";

/**
 * /admin/applications 申请审批队列（Phase 9 / R7）。
 * pending applications 列表 + approve/reject（含拒绝原因输入）。
 * 通过后自动创建 workspace（后端）；拒绝原因对申请人可见（R7a）。
 */
import { useCallback, useEffect, useState } from "react";
import {
	approveApplication,
	fetchApplications,
	rejectApplication,
} from "@/lib/admin";
import {
	APPLICATION_STATUS_CLASS,
	APPLICATION_STATUS_LABEL,
	type AdminWorkspaceApplication,
} from "@/lib/graphql/admin";

const PAGE_SIZE = 50;

/** 处理人短 ID：approved → approvedBy，rejected → rejectedBy；其余状态或空值 → "—" */
function handlerShortId(app: AdminWorkspaceApplication): string {
	if (app.status === "approved") return app.approvedBy?.slice(0, 8) ?? "—";
	if (app.status === "rejected") return app.rejectedBy?.slice(0, 8) ?? "—";
	return "—";
}

export default function AdminApplicationsPage() {
	const [applications, setApplications] = useState<AdminWorkspaceApplication[] | null>(null);
	const [status, setStatus] = useState<"pending" | "all">("pending");
	const [loading, setLoading] = useState(false);
	const [error, setError] = useState(false);
	const [actionError, setActionError] = useState<string | null>(null);
	const [busyId, setBusyId] = useState<string | null>(null);
	/** 正在输入拒绝原因的申请 id（null = 未在拒绝流程） */
	const [rejectingId, setRejectingId] = useState<string | null>(null);
	const [rejectReason, setRejectReason] = useState("");

	const load = useCallback((statusFilter: "pending" | "all") => {
		// .then/.catch 链（join 页模式）：effect 内调用不触发 set-state-in-effect
		return fetchApplications(
			statusFilter === "pending" ? "pending" : undefined,
			{ first: PAGE_SIZE },
		)
			.then((list) => {
				setApplications(list);
				setError(false);
			})
			.catch(() => {
				setError(true);
				setApplications([]);
			})
			.finally(() => {
				setLoading(false);
			});
	}, []);

	useEffect(() => {
		void load(status);
	}, [load, status]);

	const handleTabChange = (next: "pending" | "all") => {
		setStatus(next);
		setLoading(true);
	};

	const handleApprove = async (app: AdminWorkspaceApplication) => {
		setBusyId(app.id);
		setActionError(null);
		try {
			const res = await approveApplication(app.id);
			if (res.result) {
				// 成功：刷新列表（pending 过滤下该条消失）
				await load(status);
			} else {
				setActionError(res.errors[0]?.message ?? "审批失败");
			}
		} catch {
			setActionError("审批失败，请稍后重试");
		} finally {
			setBusyId(null);
		}
	};

	const handleReject = async (app: AdminWorkspaceApplication) => {
		setBusyId(app.id);
		setActionError(null);
		try {
			const reason = rejectReason.trim() || null;
			const res = await rejectApplication(app.id, reason);
			if (res.result) {
				setRejectingId(null);
				setRejectReason("");
				await load(status);
			} else {
				setActionError(res.errors[0]?.message ?? "拒绝失败");
			}
		} catch {
			setActionError("拒绝失败，请稍后重试");
		} finally {
			setBusyId(null);
		}
	};

	return (
		<section>
			<div className="admin-page__head">
				<h1>申请审批</h1>
				<div className="admin-tabs">
					<button
						type="button"
						aria-pressed={status === "pending"}
						onClick={() => handleTabChange("pending")}
						className={`admin-tabs__tab ${status === "pending" ? "admin-tabs__tab--selected" : ""}`}
					>
						待审批
					</button>
					<button
						type="button"
						aria-pressed={status === "all"}
						onClick={() => handleTabChange("all")}
						className={`admin-tabs__tab ${status === "all" ? "admin-tabs__tab--selected" : ""}`}
					>
						全部
					</button>
				</div>
			</div>

			{error && <p className="admin-alert admin-alert--error">加载失败，请稍后重试。</p>}
			{actionError && <p className="admin-alert admin-alert--error">{actionError}</p>}
			{loading && <p className="admin-muted">加载中…</p>}

			{!loading && !error && applications && applications.length === 0 && (
				<p className="admin-empty">暂无申请。</p>
			)}

			{!loading && !error && applications && applications.length > 0 && (
				<div className="admin-card admin-table-wrap">
					<table className="admin-table">
						<thead>
							<tr>
								<th>工作台</th>
								<th>slug</th>
								<th>用途</th>
								<th>状态</th>
								<th>处理人</th>
								<th>申请时间</th>
								<th className="admin-table__actions">操作</th>
							</tr>
						</thead>
						<tbody>
							{applications.map((app) => (
								<tr key={app.id}>
									<td className="admin-table__primary">{app.name}</td>
									<td>{app.slug}</td>
									<td>{app.purpose}</td>
									<td>
										<span className={APPLICATION_STATUS_CLASS[app.status]}>
											{APPLICATION_STATUS_LABEL[app.status]}
										</span>
										{app.rejectionReason && (
											<span className="admin-table__sub">
												原因：{app.rejectionReason}
											</span>
										)}
									</td>
									<td>{handlerShortId(app)}</td>
									<td>
										{new Date(app.insertedAt).toLocaleDateString("zh-CN")}
									</td>
									<td className="admin-table__actions">
										{app.status === "pending" && (
											<>
												<button
													type="button"
													onClick={() => handleApprove(app)}
													disabled={busyId === app.id}
													className="l-btn-outline"
												>
													通过
												</button>
												{rejectingId === app.id ? (
													<span className="admin-inline-form">
														<input
															value={rejectReason}
															onChange={(e) => setRejectReason(e.target.value)}
															placeholder="拒绝原因"
															aria-label="拒绝原因"
															className="l-input"
														/>
														<button
															type="button"
															onClick={() => handleReject(app)}
															disabled={busyId === app.id}
															className="l-btn-danger"
														>
															确认拒绝
														</button>
														<button
															type="button"
															onClick={() => {
																setRejectingId(null);
																setRejectReason("");
															}}
															className="l-btn-ghost"
														>
															取消
														</button>
													</span>
												) : (
													<button
														type="button"
														onClick={() => setRejectingId(app.id)}
														disabled={busyId === app.id}
														className="l-btn-outline l-btn-outline--danger"
													>
														拒绝
													</button>
												)}
											</>
										)}
									</td>
								</tr>
							))}
						</tbody>
					</table>
				</div>
			)}
		</section>
	);
}
