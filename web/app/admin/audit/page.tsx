"use client";

/**
 * /admin/audit 审计仪表盘（Phase 9 / R10）。
 * 5 资源 tab（ToolCallLog / PendingOperation / WorkflowRun / SignalLog / AdminActionLog）+ workspace 过滤。
 * - ToolCallLog / PendingOperation：D5 JSONB（params->>'workspace_id'）
 * - WorkflowRun / SignalLog：真实 workspace_id 列
 * - AdminActionLog（治理操作）：平台级日志，无 workspace 维度，忽略过滤输入
 */
import { useCallback, useEffect, useState } from "react";
import {
	fetchAdminActionLogs,
	fetchPendingOperations,
	fetchSignalLogs,
	fetchToolCallLogs,
} from "@/lib/admin";
import type {
	AdminActionLog,
	AdminPendingOperation,
	AdminSignalLog,
	AdminToolCallLog,
} from "@/lib/graphql/admin";
import { fetchWorkflowRuns } from "@/lib/workflows";
import type { WorkflowRunItem } from "@/lib/workflows";

const PAGE_SIZE = 50;

type AuditTab = "tool" | "pending" | "workflow" | "signal" | "action";

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

/** 治理操作 action 枚举 → 中文名（未知枚举值回退原串） */
const ACTION_LABEL: Record<string, string> = {
	workspace_create: "创建工作台",
	application_approve: "审批通过",
	application_reject: "审批拒绝",
	admin_promote: "提升管理员",
	admin_demote: "降级管理员",
};

function adminActionToRow(log: AdminActionLog): AuditRow {
	return {
		id: log.id,
		time: log.insertedAt,
		identity: ACTION_LABEL[log.action] ?? log.action,
		summary: log.targetId.slice(0, 8),
		status: log.result,
	};
}

const TABS: Array<{ id: AuditTab; label: string }> = [
	{ id: "tool", label: "工具调用" },
	{ id: "pending", label: "待确认操作" },
	{ id: "workflow", label: "工作流运行" },
	{ id: "signal", label: "信号日志" },
	{ id: "action", label: "治理操作" },
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
						: activeTab === "action"
							? // 治理操作无 workspace 维度，忽略过滤输入
								fetchAdminActionLogs(undefined, { first: PAGE_SIZE }).then(
									(list) => list.map(adminActionToRow),
								)
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
			<div className="admin-page__head">
				<h1>审计</h1>
			</div>

			<div className="admin-toolbar">
				<div className="admin-tabs">
					{TABS.map((t) => (
						<button
							key={t.id}
							type="button"
							aria-pressed={tab === t.id}
							onClick={() => handleTabChange(t.id)}
							className={`admin-tabs__tab ${tab === t.id ? "admin-tabs__tab--selected" : ""}`}
						>
							{t.label}
						</button>
					))}
				</div>
				<div className="admin-toolbar__spacer" />
				<input
					value={workspaceId}
					onChange={(e) => setWorkspaceId(e.target.value)}
					onKeyDown={(e) => e.key === "Enter" && handleFilter()}
					placeholder="workspace 过滤（ID）"
					aria-label="workspace 过滤"
					className="l-input"
				/>
				<button
					type="button"
					onClick={handleFilter}
					className="l-btn-outline"
				>
					过滤
				</button>
			</div>

			{error && <p className="admin-alert admin-alert--error">加载失败，请稍后重试。</p>}
			{loading && <p className="admin-muted">加载中…</p>}

			{tab === "workflow" && !workspaceId.trim() && (
				<p className="admin-alert admin-alert--plain">
					工作流运行需按 workspace 过滤（输入 workspace ID）。
				</p>
			)}

			{!loading && !error && rows && rows.length === 0 && (
				<p className="admin-empty">暂无记录。</p>
			)}

			{!loading && !error && rows && rows.length > 0 && (
				<div className="admin-card admin-table-wrap">
					<table className="admin-table">
						<thead>
							<tr>
								<th>时间</th>
								<th>标识</th>
								<th>状态</th>
							</tr>
						</thead>
						<tbody>
							{rows.map((row) => (
								<tr key={row.id}>
									<td>
										{row.time
											? new Date(row.time).toLocaleString("zh-CN")
											: "—"}
									</td>
									<td>
										<span className="l-mono">{row.identity}</span>
										{row.summary && (
											<span className="admin-table__sub">{row.summary}</span>
										)}
									</td>
									<td>{row.status}</td>
								</tr>
							))}
						</tbody>
					</table>
				</div>
			)}
		</section>
	);
}
