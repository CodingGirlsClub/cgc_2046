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
import { useLocale, useTranslations } from "next-intl";
import {
	fetchAdminActionLogs,
	fetchPendingOperations,
	fetchSignalLogs,
	fetchToolCallLogs,
	type AuditFilters,
} from "@/lib/admin";
import type {
	AdminActionLog,
	AdminOfferingChangeMetadata,
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
	/** 副标识（PendingOperation 的 summary；#607 起治理操作行也用它放「规则名 · 目标短 ID」） */
	summary?: string | null;
	/** 副标识的 i18n key（#607 规则变更行的规则名）；有值时渲染 t() 而非 summary 本身 */
	summaryKey?: string;
	status: string;
	/** #607 变更列（仅治理操作 tab 渲染）；`rule` = 规则值快照，`offering` = U1 offering 闭集标量 */
	change?:
		| {
				kind: "rule";
				/** 变更前规则值 JSON；null ⇔ 新建 */
				before: string | null;
				after: string;
				/** 变更前锁定态；新建时为 null */
				lockedBefore: boolean | null;
				locked: boolean;
				beforeOmitted: boolean;
				afterOmitted: boolean;
		  }
		| {
				kind: "offering";
				/** 已格式化的变更列（`key=value, ...`；两侧键序一致，便于对照） */
				before: string;
				after: string;
		  };
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
		identity: run.definitionType,
		// L4:失败 run 的脱敏错误摘要(后端仅对 status=failed 返回常量 "workflow_failed")
		summary: run.errorSummary ?? undefined,
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
	initiative_rule_update: "actionInitiativeRuleUpdate",
	// U1 offering 治理写（R8）：8 个 action 各有人读标签，缺表即渲染 missing-message 回退串
	admin_event_update: "actionAdminEventUpdate",
	admin_event_launch: "actionAdminEventLaunch",
	admin_event_close: "actionAdminEventClose",
	admin_event_cancel: "actionAdminEventCancel",
	admin_course_update: "actionAdminCourseUpdate",
	admin_course_launch: "actionAdminCourseLaunch",
	admin_course_close: "actionAdminCourseClose",
	admin_course_cancel: "actionAdminCourseCancel",
};

/** #607 规则键 → admin messages key（未知规则键回退原串） */
const RULE_KEY_LABEL: Record<string, string> = {
	deposit: "ruleDeposit",
	age_gate: "ruleAgeGate",
	min_participants: "ruleMinParticipants",
	deadline_rule: "ruleDeadlineRule",
};

/** 规则值原语渲染；对象/数组回退 JSON 原文（当前四项规则值都是标量） */
function formatRuleValue(value: unknown): string {
	if (value === null || value === undefined) return "null";
	if (typeof value === "object") return JSON.stringify(value);
	return String(value);
}

/**
 * #607 规则态快照 → "locked=<b>, key=value, key=value"（**结构化**，非 JSON 原文）。
 * `locked` 置首（锁翻转是独立的审计维度）；值键序 = 后端二级白名单次序
 * （JSON.parse 保序）→ 前端无键名清单可漂移。
 * `locked === null` 时**不补默认值**（审计面不许编造状态）；全空 → "—"。
 */
function formatRuleState(json: string, locked: boolean | null): string {
	const entries = Object.entries(JSON.parse(json) as Record<string, unknown>);
	const parts = [
		...(locked === null ? [] : [`locked=${locked}`]),
		...entries.map(([key, value]) => `${key}=${formatRuleValue(value)}`),
	];
	return parts.length === 0 ? "—" : parts.join(", ");
}

function adminActionToRow(log: AdminActionLog): AuditRow {
	const md = log.metadata;
	const shortId = log.targetId.slice(0, 8);
	const ruleLabelKey = md ? RULE_KEY_LABEL[md.ruleKey] : undefined;
	const offeringEntries = log.offeringChange ? offeringChangeEntries(log.offeringChange) : [];

	return {
		id: log.id,
		time: log.insertedAt,
		identity: ACTION_LABEL[log.action] ?? log.action,
		identityKey: true,
		// #607：规则变更行副标识 = 规则名 + 目标短 ID（未知规则键回退原串，不静默丢信息）
		summary: ruleLabelKey || !md ? shortId : `${md.ruleKey} · ${shortId}`,
		summaryKey: ruleLabelKey,
		status: log.result,
		change:
			offeringEntries.length > 0
				? {
						kind: "offering",
						before: formatOfferingSide(offeringEntries, "before"),
						after: formatOfferingSide(offeringEntries, "after"),
					}
				: md
					? {
							kind: "rule",
							before: md.valueBeforeJson,
							after: md.valueAfterJson,
							lockedBefore: md.lockedBefore,
							locked: md.locked,
							beforeOmitted: md.valueBeforeOmitted,
							afterOmitted: md.valueAfterOmitted,
						}
					: undefined,
	};
}

/**
 * U1 offering 变更投影 → 变更列条目（`[字段名, 前值, 后值]`）。
 * 列序 = 后端闭集次序（键序单源在后端白名单表）；两侧同为 null = 本次未改该属性 → 不渲染。
 */
function offeringChangeEntries(
	change: AdminOfferingChangeMetadata,
): Array<[string, unknown, unknown]> {
	const pairs: Array<[string, unknown, unknown]> = [
		["title", change.titleBefore, change.titleAfter],
		["visibility", change.visibilityBefore, change.visibilityAfter],
		["capacity", change.capacityBefore, change.capacityAfter],
		["pricing_enabled", change.pricingEnabledBefore, change.pricingEnabledAfter],
		["deposit_enabled", change.depositEnabledBefore, change.depositEnabledAfter],
	];
	return pairs.filter(([, before, after]) => before !== null || after !== null);
}

/** 变更列单侧：`key=value, ...`；缺值（未设/nil）渲染 "—"，不编造 0/false。 */
function formatOfferingSide(
	entries: Array<[string, unknown, unknown]>,
	side: "before" | "after",
): string {
	const index = side === "before" ? 1 : 2;
	return entries
		.map((entry) => {
			const value = entry[index];
			return `${entry[0]}=${value === null || value === undefined ? "—" : String(value)}`;
		})
		.join(", ");
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
	const locale = useLocale();
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
		<section data-testid="platform-audit-page">
			<div className="admin-page__head">
				<h1>{t("auditTitle")}</h1>
			</div>
			<p className="admin-muted" data-testid="audit-redaction-notice">{t("auditRedactionNotice")}</p>

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
				<div className="admin-card admin-table-wrap" data-testid="audit-table-wrap">
					<table className="admin-table">
						<thead>
							<tr>
								<th>{t("thTime")}</th>
								<th>{t("thId")}</th>
								{/* #607：变更列仅治理操作 tab 渲染（其它 tab 无 metadata 投影） */}
								{tab === "action" && <th>{t("thChange")}</th>}
								<th>{t("thStatus")}</th>
							</tr>
						</thead>
						<tbody>
							{rows.map((row) => (
								<tr key={row.id}>
									<td>
										{row.time
											? new Date(row.time).toLocaleString(locale === "en" ? "en-US" : "zh-CN")
											: "—"}
									</td>
									<td>
										<span className="l-mono">
											{row.identityKey ? t(row.identity) : row.identity}
										</span>
										{row.summary && (
											<span className="admin-table__sub">
												{row.summaryKey ? `${t(row.summaryKey)} · ` : ""}
												{row.summary}
											</span>
										)}
									</td>
									{tab === "action" && (
										<td className="l-mono">
											{renderChange(row, t("ruleChangeCreated"), t("ruleChangeOmitted"))}
										</td>
									)}
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

/**
 * #607 变更列：`<before> → <after>`，`before === null` 时渲染「新建」。
 * 被白名单省略的一侧追加 `…`，带 title/aria-label 说明（不让读者以为那就是全部）。
 * 无投影的行（其它 action）→ "—"。
 */
function renderChange(row: AuditRow, createdLabel: string, omittedLabel: string) {
	if (!row.change) return "—";

	// U1：offering 变更已格式化为平行两侧（`key=value, ...`），无「新建/省略」语义
	if (row.change.kind === "offering") {
		return (
			<>
				<span data-testid="audit-change-before">{row.change.before}</span>
				{/* 箭头不加 aria-hidden：两侧快照需要可读分隔，否则读屏会把前后态连成一串 */}
				<span> → </span>
				<span data-testid="audit-change-after">{row.change.after}</span>
			</>
		);
	}

	const { before, after, lockedBefore, locked, beforeOmitted, afterOmitted } = row.change;

	return (
		<>
			<span data-testid="audit-change-before">
				{before === null ? createdLabel : formatRuleState(before, lockedBefore)}
				{beforeOmitted && <OmittedMark label={omittedLabel} />}
			</span>
			{/* 箭头不加 aria-hidden：两侧快照需要可读分隔，否则读屏会把前后态连成一串 */}
			<span> → </span>
			<span data-testid="audit-change-after">
				{formatRuleState(after, locked)}
				{afterOmitted && <OmittedMark label={omittedLabel} />}
			</span>
		</>
	);
}

function OmittedMark({ label }: { label: string }) {
	return (
		// role="note"：aria-label 在 generic role 上不被暴露为可访问名（只有裸 " …" 会被读出）
		<span className="admin-table__omitted" role="note" title={label} aria-label={label}>
			{" …"}
		</span>
	);
}
