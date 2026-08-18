"use client";

/**
 * /admin/applications 申请审批队列（Phase 9 / R7）。
 * pending applications 列表 + approve/reject（含拒绝原因输入）。
 * 通过后自动创建 workspace（后端）；拒绝原因对申请人可见（R7a）。
 */
import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";
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
	const t = useTranslations("admin");
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
				setActionError(res.errors[0]?.message ?? t("approveFailed"));
			}
		} catch {
			setActionError(t("approveFailedRetry"));
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
				setActionError(res.errors[0]?.message ?? t("rejectFailed"));
			}
		} catch {
			setActionError(t("rejectFailedRetry"));
		} finally {
			setBusyId(null);
		}
	};

	return (
		<section>
			<div className="admin-page__head">
				<h1>{t("navApplications")}</h1>
				<div className="admin-tabs">
					<button
						type="button"
						aria-pressed={status === "pending"}
						onClick={() => handleTabChange("pending")}
						className={`admin-tabs__tab ${status === "pending" ? "admin-tabs__tab--selected" : ""}`}
					>
						{t("tabPending")}
					</button>
					<button
						type="button"
						aria-pressed={status === "all"}
						onClick={() => handleTabChange("all")}
						className={`admin-tabs__tab ${status === "all" ? "admin-tabs__tab--selected" : ""}`}
					>
						{t("tabAll")}
					</button>
				</div>
			</div>

			{error && <p className="admin-alert admin-alert--error">{t("loadFailed")}</p>}
			{actionError && <p className="admin-alert admin-alert--error">{actionError}</p>}
			{loading && <p className="admin-muted">{t("loading")}</p>}

			{!loading && !error && applications && applications.length === 0 && (
				<p className="admin-empty">{t("noApplications")}</p>
			)}

			{!loading && !error && applications && applications.length > 0 && (
				<div className="admin-card admin-table-wrap">
					<table className="admin-table">
						<thead>
							<tr>
								<th>{t("thWorkspace")}</th>
								<th>{t("thSlug")}</th>
								<th>{t("thPurpose")}</th>
								<th>{t("thStatus")}</th>
								<th>{t("thHandler")}</th>
								<th>{t("thAppliedAt")}</th>
								<th className="admin-table__actions">{t("thActions")}</th>
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
												{t("reasonPrefix", { reason: app.rejectionReason })}
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
													{t("approve")}
												</button>
												{rejectingId === app.id ? (
													<span className="admin-inline-form">
														<input
															value={rejectReason}
															onChange={(e) => setRejectReason(e.target.value)}
															placeholder={t("rejectReasonPlaceholder")}
															aria-label={t("rejectReasonAria")}
															className="l-input"
														/>
														<button
															type="button"
															onClick={() => handleReject(app)}
															disabled={busyId === app.id}
															className="l-btn-danger"
														>
															{t("confirmReject")}
														</button>
														<button
															type="button"
															onClick={() => {
																setRejectingId(null);
																setRejectReason("");
															}}
															className="l-btn-ghost"
														>
															{t("cancel")}
														</button>
													</span>
												) : (
													<button
														type="button"
														onClick={() => setRejectingId(app.id)}
														disabled={busyId === app.id}
														className="l-btn-outline l-btn-outline--danger"
													>
														{t("reject")}
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
