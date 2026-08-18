"use client";

/**
 * /admin/reconciliation 对账扫描页（E-10 #125）。
 * 平台级孤儿报告（ReconciliationScanWorker 每 10 分钟扫六规则落 reconciliation_findings）。
 * 列：规则 / 实体 / ID / workspace / 首次发现 / 最近发现；规则枚举中文标签。
 */
import { useCallback, useEffect, useState } from "react";
import { fetchReconciliationFindings } from "@/lib/admin";
import {
	RECONCILIATION_ENTITY_LABEL,
	RECONCILIATION_RULE_LABEL,
	type AdminReconciliationFinding,
} from "@/lib/graphql/admin";

const PAGE_SIZE = 50;

/** 规则下拉选项（值 = 后端枚举串，label = 中文名） */
const RULE_OPTIONS = Object.entries(RECONCILIATION_RULE_LABEL);

export default function AdminReconciliationPage() {
	const [rows, setRows] = useState<AdminReconciliationFinding[] | null>(null);
	const [rule, setRule] = useState("");
	const [workspaceId, setWorkspaceId] = useState("");
	const [loading, setLoading] = useState(false);
	const [error, setError] = useState(false);

	const load = useCallback((ruleFilter: string, wsId: string) => {
		// .then/.catch 链（audit 页模式）：effect 内调用不触发 set-state-in-effect
		return fetchReconciliationFindings(
			{
				rule: ruleFilter || undefined,
				workspaceId: wsId.trim() || undefined,
			},
			{ first: PAGE_SIZE },
		)
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
		void load(rule, workspaceId);
	}, [load, rule, workspaceId]);

	const handleFilter = () => {
		setLoading(true);
		void load(rule, workspaceId);
	};

	return (
		<section>
			<div className="admin-page__head">
				<h1>对账</h1>
			</div>

			<div className="admin-toolbar">
				<select
					value={rule}
					onChange={(e) => setRule(e.target.value)}
					aria-label="规则过滤"
					className="l-input"
				>
					<option value="">全部规则</option>
					{RULE_OPTIONS.map(([value, label]) => (
						<option key={value} value={value}>
							{label}
						</option>
					))}
				</select>
				<input
					value={workspaceId}
					onChange={(e) => setWorkspaceId(e.target.value)}
					onKeyDown={(e) => e.key === "Enter" && handleFilter()}
					placeholder="workspace 过滤（ID）"
					aria-label="workspace 过滤"
					className="l-input"
				/>
				<button type="button" onClick={handleFilter} className="l-btn-outline">
					过滤
				</button>
			</div>

			{error && <p className="admin-alert admin-alert--error">加载失败，请稍后重试。</p>}
			{loading && <p className="admin-muted">加载中…</p>}

			{!loading && !error && rows && rows.length === 0 && (
				<p className="admin-empty">暂无孤儿发现。</p>
			)}

			{!loading && !error && rows && rows.length > 0 && (
				<div className="admin-card admin-table-wrap">
					<table className="admin-table">
						<thead>
							<tr>
								<th>规则</th>
								<th>实体</th>
								<th>ID</th>
								<th>workspace</th>
								<th>首次发现</th>
								<th>最近发现</th>
							</tr>
						</thead>
						<tbody>
							{rows.map((row) => (
								<tr key={row.id}>
									<td>{RECONCILIATION_RULE_LABEL[row.rule] ?? row.rule}</td>
									<td>
										{RECONCILIATION_ENTITY_LABEL[row.entityType] ?? row.entityType}
									</td>
									<td className="l-mono">{row.entityId}</td>
									<td className="l-mono">{row.workspaceId ?? "—"}</td>
									<td>{new Date(row.firstSeenAt).toLocaleString("zh-CN")}</td>
									<td>{new Date(row.lastSeenAt).toLocaleString("zh-CN")}</td>
								</tr>
							))}
						</tbody>
					</table>
				</div>
			)}
		</section>
	);
}
