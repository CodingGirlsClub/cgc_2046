"use client";

/**
 * /admin/audit 审计仪表盘（Phase 9 / R10）。
 * 5 资源 tab（ToolCallLog / PendingOperation / WorkflowRun / SignalLog / AdminActionLog）
 * + workspace 过滤 + 状态/类型 + 时间范围筛选（#117）。
 * - ToolCallLog / PendingOperation：D5 JSONB（params->>'workspace_id'）
 * - WorkflowRun / SignalLog：真实 workspace_id 列；WorkflowRun 可免 workspace 全量列出，
 *   时间范围映射 startedAt（自动 filter 无 insertedAt）
 * - AdminActionLog（治理操作）：平台级日志，无 workspace/状态维度，仅时间范围生效
 */
import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import {
	fetchAdminActionLogs,
	fetchPendingOperations,
	fetchSignalLogs,
	fetchToolCallLogs,
	type AuditFilters,
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

/**
 * #117 各 tab 状态枚举（值 = 后端枚举串，label 与表格状态列渲染一致）。
 * signal tab 无状态枚举（signal_type 自由 string）→ 文本输入；action tab 无状态维度。
 */
const STATUS_OPTIONS: Record<"tool" | "pending" | "workflow", string[]> = {
	tool: ["ok", "error", "needs_confirmation", "forbidden"],
	pending: ["pending", "confirmed", "cancelled", "expired"],
	workflow: [
		"pending",
		"running",
		"waiting",
		"succeeded",
		"failed",
		"cancelled",
		"expired",
	],
};

/** toolbar 控件值 → AuditFilters（datetime-local 本地值转 ISO8601；空值不落参数） */
function buildFilters(input: {
	tab: AuditTab;
	status: string;
	signalType: string;
	insertedAfter: string;
	insertedBefore: string;
}): AuditFilters {
	const filters: AuditFilters = {};
	if (input.tab === "signal") {
		const st = input.signalType.trim();
		if (st) filters.signalType = st;
	} else if (input.tab !== "action" && input.status) {
		filters.status = input.status;
	}
	if (input.insertedAfter) {
		filters.insertedAfter = new Date(input.insertedAfter).toISOString();
	}
	if (input.insertedBefore) {
		filters.insertedBefore = new Date(input.insertedBefore).toISOString();
	}
	return filters;
}

/** 审计表格统一投影：4 类日志各经一个 typed adapter 收敛到这一行，render 不再猜字段。 */
interface AuditRow {
	id: string;
	/** ISO 时间串；未开始（如 WorkflowRun.startedAt 为 null）→ 渲染 "—" */
	time: string | null;
	identity: string;
	/** identity 为 admin messages key（治理操作 action 名），渲染时需 t() */
	identityKey?: boolean;
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

/** 治理操作 action 枚举 → admin messages key（未知枚举值回退原串） */
const ACTION_LABEL: Record<string, string> = {
	workspace_create: "actionWorkspaceCreate",
	application_approve: "actionApplicationApprove",
	application_reject: "actionApplicationReject",
	admin_promote: "actionAdminPromote",
	admin_demote: "actionAdminDemote",
	owner_reassign: "actionOwnerReassign",
	owner_invitation_cancel: "actionOwnerInvitationCancel",
};

function adminActionToRow(log: AdminActionLog): AuditRow {
	return {
		id: log.id,
		time: log.insertedAt,
		identity: ACTION_LABEL[log.action] ?? log.action,
		identityKey: true,
		summary: log.targetId.slice(0, 8),
		status: log.result,
	};
}

const TABS: Array<{ id: AuditTab; label: string }> = [
	{ id: "tool", label: "tabTool" },
	{ id: "pending", label: "tabPendingActions" },
	{ id: "workflow", label: "tabWorkflow" },
	{ id: "signal", label: "tabSignal" },
	{ id: "action", label: "tabAction" },
];

export default function AdminAuditPage() {
	const t = useTranslations("admin");
	const [tab, setTab] = useState<AuditTab>("tool");
	const [workspaceId, setWorkspaceId] = useState("");
	const [status, setStatus] = useState("");
	const [signalType, setSignalType] = useState("");
	const [insertedAfter, setInsertedAfter] = useState("");
	const [insertedBefore, setInsertedBefore] = useState("");
	const [rows, setRows] = useState<AuditRow[] | null>(null);
	const [loading, setLoading] = useState(false);
	const [error, setError] = useState(false);

	const load = useCallback(
		(
			activeTab: AuditTab,
			wsId: string,
			filterInput: {
				status: string;
				signalType: string;
				insertedAfter: string;
				insertedBefore: string;
			},
		) => {
			// .then/.catch 链（join 页模式）：effect 内调用不触发 set-state-in-effect
			const ws = wsId.trim() || undefined;
			const filters = buildFilters({ tab: activeTab, ...filterInput });
			const p: Promise<AuditRow[]> =
				activeTab === "tool"
					? fetchToolCallLogs(ws, filters, { first: PAGE_SIZE }).then((list) =>
							list.map(toolCallToRow),
						)
					: activeTab === "pending"
						? fetchPendingOperations(ws, filters, { first: PAGE_SIZE }).then((list) =>
								list.map(pendingOpToRow),
							)
						: activeTab === "workflow"
							? fetchWorkflowRuns(ws, { first: PAGE_SIZE, filters }).then((list) =>
									list.map(workflowRunToRow),
								)
							: activeTab === "action"
								? // 治理操作无 workspace 维度，忽略过滤输入；#117 仅时间范围生效
									fetchAdminActionLogs(undefined, filters, { first: PAGE_SIZE }).then(
										(list) => list.map(adminActionToRow),
									)
								: fetchSignalLogs(ws, filters, { first: PAGE_SIZE }).then((list) =>
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
		},
		[],
	);

	useEffect(() => {
		void load(tab, workspaceId, { status, signalType, insertedAfter, insertedBefore });
	}, [load, tab, workspaceId, status, signalType, insertedAfter, insertedBefore]);

	const handleFilter = () => {
		setLoading(true);
		void load(tab, workspaceId, { status, signalType, insertedAfter, insertedBefore });
	};

	const handleTabChange = (next: AuditTab) => {
		setTab(next);
		// 各 tab 状态枚举不同，切换时重置避免带入不适用值
		setStatus("");
		setLoading(true);
	};

	return (
		<section>
			<div className="admin-page__head">
				<h1>{t("auditTitle")}</h1>
			</div>

			<div className="admin-toolbar">
				<div className="admin-tabs">
					{TABS.map((tabDef) => (
						<button
							key={tabDef.id}
							type="button"
							aria-pressed={tab === tabDef.id}
							onClick={() => handleTabChange(tabDef.id)}
							className={`admin-tabs__tab ${tab === tabDef.id ? "admin-tabs__tab--selected" : ""}`}
						>
							{t(tabDef.label)}
						</button>
					))}
				</div>
				<div className="admin-toolbar__spacer" />
				{tab === "signal" ? (
					<input
						value={signalType}
						onChange={(e) => setSignalType(e.target.value)}
						onKeyDown={(e) => e.key === "Enter" && handleFilter()}
						placeholder={t("signalPlaceholder")}
						aria-label={t("signalAria")}
						className="l-input"
					/>
				) : tab !== "action" ? (
					<select
						value={status}
						onChange={(e) => setStatus(e.target.value)}
						aria-label={t("statusAria")}
						className="l-input"
					>
						<option value="">{t("allStatuses")}</option>
						{STATUS_OPTIONS[tab].map((s) => (
							<option key={s} value={s}>
								{s}
							</option>
						))}
					</select>
				) : null}
				<input
					type="datetime-local"
					value={insertedAfter}
					onChange={(e) => setInsertedAfter(e.target.value)}
					aria-label={t("startAria")}
					className="l-input"
				/>
				<input
					type="datetime-local"
					value={insertedBefore}
					onChange={(e) => setInsertedBefore(e.target.value)}
					aria-label={t("endAria")}
					className="l-input"
				/>
				<input
					value={workspaceId}
					onChange={(e) => setWorkspaceId(e.target.value)}
					onKeyDown={(e) => e.key === "Enter" && handleFilter()}
					placeholder={t("workspaceFilterPlaceholder")}
					aria-label={t("workspaceFilterAria")}
					className="l-input"
				/>
				<button
					type="button"
					onClick={handleFilter}
					className="l-btn-outline"
				>
					{t("filter")}
				</button>
			</div>

			{error && <p className="admin-alert admin-alert--error">{t("loadFailed")}</p>}
			{loading && <p className="admin-muted">{t("loading")}</p>}

			{!loading && !error && rows && rows.length === 0 && (
				<p className="admin-empty">{t("empty")}</p>
			)}

			{!loading && !error && rows && rows.length > 0 && (
				<div className="admin-card admin-table-wrap">
					<table className="admin-table">
						<thead>
							<tr>
								<th>{t("thTime")}</th>
								<th>{t("thId")}</th>
								<th>{t("thStatus")}</th>
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
										<span className="l-mono">
											{row.identityKey ? t(row.identity) : row.identity}
										</span>
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
