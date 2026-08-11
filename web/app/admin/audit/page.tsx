"use client";

/**
 * /admin/audit 审计仪表盘（Phase 9 / R10）。
 * 4 资源 tab（ToolCallLog / PendingOperation / WorkflowRun / SignalLog）+ workspace 过滤。
 * - ToolCallLog / PendingOperation：D5 JSONB（params->>'workspace_id'）
 * - WorkflowRun / SignalLog：真实 workspace_id 列
 */
import { useCallback, useEffect, useState } from "react";
import {
	fetchPendingOperations,
	fetchSignalLogs,
	fetchToolCallLogs,
} from "@/lib/admin";
import type {
	AdminPendingOperation,
	AdminSignalLog,
	AdminToolCallLog,
} from "@/lib/graphql/admin";
import { fetchWorkflowRuns } from "@/lib/workflows";
import type { WorkflowRunItem } from "@/lib/workflows";

const PAGE_SIZE = 50;

type AuditTab = "tool" | "pending" | "workflow" | "signal";

/** 审计表格统一投影：4 类日志各经一个 typed adapter 收敛到这一行，render 不再猜字段。 */
interface AuditRow {
	id: string;
	/** ISO 时间串；未开始（如 WorkflowRun.startedAt 为 null）→ 渲染 "—" */
	time: string | null;
	identity: string;
	/** 副标识（仅 PendingOperation 的 summary） */
	summary?: string | null;
	status: string;
}

function toolCallToRow(log: AdminToolCallLog): AuditRow {
	return {
		id: log.id,
		time: log.insertedAt,
		identity: log.tool,
		status: log.resultStatus,
	};
}

function pendingOpToRow(log: AdminPendingOperation): AuditRow {
	return {
		id: log.id,
		time: log.insertedAt,
		identity: log.tool,
		summary: log.summary,
		status: log.status,
	};
}

function workflowRunToRow(run: WorkflowRunItem): AuditRow {
	return {
		id: run.id,
		time: run.startedAt,
		identity: run.definitionId,
		status: run.status,
	};
}

function signalLogToRow(log: AdminSignalLog): AuditRow {
	return {
		id: log.id,
		time: log.insertedAt,
		identity: log.workspaceId,
		status: log.signalType,
	};
}

const TABS: Array<{ id: AuditTab; label: string }> = [
	{ id: "tool", label: "工具调用" },
	{ id: "pending", label: "待确认操作" },
	{ id: "workflow", label: "工作流运行" },
	{ id: "signal", label: "信号日志" },
];

export default function AdminAuditPage() {
	const [tab, setTab] = useState<AuditTab>("tool");
	const [workspaceId, setWorkspaceId] = useState("");
	const [rows, setRows] = useState<AuditRow[] | null>(null);
	const [loading, setLoading] = useState(false);
	const [error, setError] = useState(false);

	const load = useCallback((activeTab: AuditTab, wsId: string) => {
		// .then/.catch 链（join 页模式）：effect 内调用不触发 set-state-in-effect
		const ws = wsId.trim() || undefined;
		const p: Promise<AuditRow[]> =
			activeTab === "tool"
				? fetchToolCallLogs(ws, { first: PAGE_SIZE }).then((list) =>
						list.map(toolCallToRow),
					)
				: activeTab === "pending"
					? fetchPendingOperations(ws, { first: PAGE_SIZE }).then((list) =>
							list.map(pendingOpToRow),
						)
					: activeTab === "workflow"
						? (ws
								? fetchWorkflowRuns(ws, { first: PAGE_SIZE }).then((list) =>
										list.map(workflowRunToRow),
									)
								: Promise.resolve([]))
						: fetchSignalLogs(ws, { first: PAGE_SIZE }).then((list) =>
								list.map(signalLogToRow),
							);

		return p
			.then((list) => {
				setRows(list);
				setError(false);
			})
			.catch(() => {
				setError(true);
				setRows([]);
			})
			.finally(() => {
				setLoading(false);
			});
	}, []);

	useEffect(() => {
		void load(tab, workspaceId);
	}, [load, tab, workspaceId]);

	const handleFilter = () => {
		setLoading(true);
		void load(tab, workspaceId);
	};

	const handleTabChange = (next: AuditTab) => {
		setTab(next);
		setLoading(true);
	};

	return (
		<section>
			<h1 className="text-2xl font-semibold mb-4">审计</h1>

			<div className="flex items-center gap-2 mb-4">
				<div className="flex gap-1">
					{TABS.map((t) => (
						<button
							key={t.id}
							type="button"
							onClick={() => handleTabChange(t.id)}
							className={`px-3 py-1.5 rounded-md text-sm ${
								tab === t.id
									? "bg-neutral-900 text-white"
									: "border border-neutral-300 hover:bg-neutral-50"
							}`}
						>
							{t.label}
						</button>
					))}
				</div>
				<input
					value={workspaceId}
					onChange={(e) => setWorkspaceId(e.target.value)}
					onKeyDown={(e) => e.key === "Enter" && handleFilter()}
					placeholder="workspace 过滤（ID）"
					aria-label="workspace 过滤"
					className="px-3 py-1.5 rounded-md border border-neutral-300 text-sm flex-1 ml-2"
				/>
				<button
					type="button"
					onClick={handleFilter}
					className="px-3 py-1.5 rounded-md border border-neutral-300 text-sm hover:bg-neutral-50"
				>
					过滤
				</button>
			</div>

			{error && <p className="text-sm text-red-600 mb-4">加载失败，请稍后重试。</p>}
			{loading && <p className="text-sm text-neutral-500">加载中…</p>}

			{tab === "workflow" && !workspaceId.trim() && (
				<p className="text-sm text-neutral-500 mb-4">
					工作流运行需按 workspace 过滤（输入 workspace ID）。
				</p>
			)}

			{!loading && !error && rows && rows.length === 0 && (
				<p className="text-sm text-neutral-500">暂无记录。</p>
			)}

			{!loading && !error && rows && rows.length > 0 && (
				<table className="w-full text-sm border-collapse">
					<thead>
						<tr className="text-left text-neutral-500 border-b border-neutral-200">
							<th className="py-2">时间</th>
							<th className="py-2">标识</th>
							<th className="py-2">状态</th>
						</tr>
					</thead>
					<tbody>
						{rows.map((row) => (
							<tr key={row.id} className="border-b border-neutral-100">
								<td className="py-2 text-neutral-600">
									{row.time
										? new Date(row.time).toLocaleString("zh-CN")
										: "—"}
								</td>
								<td className="py-2">
									<span className="font-mono text-xs">
										{row.identity}
									</span>
									{row.summary && (
										<span className="text-neutral-500 text-xs ml-2">
											{row.summary}
										</span>
									)}
								</td>
								<td className="py-2">{row.status}</td>
							</tr>
						))}
					</tbody>
				</table>
			)}
		</section>
	);
}
