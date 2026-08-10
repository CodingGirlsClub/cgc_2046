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
			<div className="flex items-center justify-between mb-4">
				<h1 className="text-2xl font-semibold">申请审批</h1>
				<div className="flex gap-1">
					<button
						type="button"
						onClick={() => handleTabChange("pending")}
						className={`px-3 py-1.5 rounded-md text-sm ${
							status === "pending"
								? "bg-neutral-900 text-white"
								: "border border-neutral-300 hover:bg-neutral-50"
						}`}
					>
						待审批
					</button>
					<button
						type="button"
						onClick={() => handleTabChange("all")}
						className={`px-3 py-1.5 rounded-md text-sm ${
							status === "all"
								? "bg-neutral-900 text-white"
								: "border border-neutral-300 hover:bg-neutral-50"
						}`}
					>
						全部
					</button>
				</div>
			</div>

			{error && <p className="text-sm text-red-600 mb-4">加载失败，请稍后重试。</p>}
			{actionError && <p className="text-sm text-red-600 mb-4">{actionError}</p>}
			{loading && <p className="text-sm text-neutral-500">加载中…</p>}

			{!loading && !error && applications && applications.length === 0 && (
				<p className="text-sm text-neutral-500">暂无申请。</p>
			)}

			{!loading && !error && applications && applications.length > 0 && (
				<table className="w-full text-sm border-collapse">
					<thead>
						<tr className="text-left text-neutral-500 border-b border-neutral-200">
							<th className="py-2">工作台</th>
							<th className="py-2">slug</th>
							<th className="py-2">用途</th>
							<th className="py-2">状态</th>
							<th className="py-2">申请时间</th>
							<th className="py-2">操作</th>
						</tr>
					</thead>
					<tbody>
						{applications.map((app) => (
							<tr key={app.id} className="border-b border-neutral-100">
								<td className="py-2 font-medium">{app.name}</td>
								<td className="py-2 text-neutral-600">{app.slug}</td>
								<td className="py-2 text-neutral-600">{app.purpose}</td>
								<td className="py-2">
									<span className={APPLICATION_STATUS_CLASS[app.status]}>
										{APPLICATION_STATUS_LABEL[app.status]}
									</span>
									{app.rejectionReason && (
										<div className="text-xs text-neutral-500 mt-0.5">
											原因：{app.rejectionReason}
										</div>
									)}
								</td>
								<td className="py-2 text-neutral-600">
									{new Date(app.insertedAt).toLocaleDateString("zh-CN")}
								</td>
								<td className="py-2">
									{app.status === "pending" && (
										<div className="flex gap-2">
											<button
												type="button"
												onClick={() => handleApprove(app)}
												disabled={busyId === app.id}
												className="px-2 py-1 rounded-md border border-neutral-300 text-xs hover:bg-neutral-50 disabled:opacity-50"
											>
												通过
											</button>
											{rejectingId === app.id ? (
												<div className="flex gap-1 items-center">
													<input
														value={rejectReason}
														onChange={(e) => setRejectReason(e.target.value)}
														placeholder="拒绝原因"
														aria-label="拒绝原因"
														className="px-2 py-1 rounded-md border border-neutral-300 text-xs w-40"
													/>
													<button
														type="button"
														onClick={() => handleReject(app)}
														disabled={busyId === app.id}
														className="px-2 py-1 rounded-md bg-red-600 text-white text-xs disabled:opacity-50"
													>
														确认拒绝
													</button>
													<button
														type="button"
														onClick={() => {
															setRejectingId(null);
															setRejectReason("");
														}}
														className="px-2 py-1 rounded-md border border-neutral-300 text-xs"
													>
														取消
													</button>
												</div>
											) : (
												<button
													type="button"
													onClick={() => setRejectingId(app.id)}
													disabled={busyId === app.id}
													className="px-2 py-1 rounded-md border border-neutral-300 text-xs hover:bg-neutral-50 disabled:opacity-50"
												>
													拒绝
												</button>
											)}
										</div>
									)}
								</td>
							</tr>
						))}
					</tbody>
				</table>
			)}
		</section>
	);
}
