"use client";

/**
 * /admin/flashback 闪念间看板（U11/R24/R25）。
 * 四率 + 分线（KTD10：分子 = touch distinct person，分母 = 成功送达——硬退信
 * 与退订剔除，记忆线/圆梦线分开）；导出 CSV 为聚合数字，结构性无 PII（KTD3）。
 * 兑换申请（R25）：人工处理队列——收款渠道由本人提交，状态流转
 * pending → contacted → settled | rejected（非法转移由后端 fail-closed 拒绝）。
 */
import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import {
	fetchFlashbackAdminRedemptions,
	fetchFlashbackAdminStats,
	updateFlashbackRedemption,
} from "@/lib/admin";
import { formatDateTime } from "@/lib/format";
import type {
	FlashbackAdminStats,
	FlashbackRedemption,
} from "@/lib/graphql/admin";

const EVENTS = [
	{ key: "linkOpened", label: "fbLinkOpened" },
	{ key: "revealed", label: "fbRevealed" },
	{ key: "sentToWall", label: "fbSentToWall" },
	{ key: "intentSubmitted", label: "fbIntentSubmitted" },
] as const;

const LINES = [
	{ key: "memory", label: "fbLineMemory" },
	{ key: "dream", label: "fbLineDream" },
	{ key: "overall", label: "fbLineOverall" },
] as const;

/** 合法流转表（与后端 AdminStats.@status_transitions 同源；终态无操作）。 */
const NEXT_STATUSES: Record<string, string[]> = {
	pending: ["contacted", "settled", "rejected"],
	contacted: ["settled", "rejected"],
	settled: [],
	rejected: [],
};

const STATUS_LABEL: Record<string, string> = {
	pending: "fbStatusPending",
	contacted: "fbStatusContacted",
	settled: "fbStatusSettled",
	rejected: "fbStatusRejected",
};

const ACTION_LABEL: Record<string, string> = {
	contacted: "fbActionContacted",
	settled: "fbActionSettled",
	rejected: "fbActionRejected",
};

function pct(count: number, delivered: number): string {
	if (delivered <= 0) return "—";
	return `${Math.round((count / delivered) * 100)}%`;
}

export default function AdminFlashbackPage() {
	const t = useTranslations("admin");
	const [stats, setStats] = useState<FlashbackAdminStats | null>(null);
	const [rows, setRows] = useState<FlashbackRedemption[] | null>(null);
	const [loading, setLoading] = useState(true);
	const [error, setError] = useState(false);
	const [notes, setNotes] = useState<Record<string, string>>({});
	const [updateError, setUpdateError] = useState(false);

	// .then/.catch 链（reconciliation 页模式）：effect 内调用不触发 set-state-in-effect
	const load = useCallback(() => {
		return Promise.all([
			fetchFlashbackAdminStats(),
			fetchFlashbackAdminRedemptions(),
		])
			.then(([s, r]) => {
				setStats(s);
				setRows(r);
				setError(false);
			})
			.catch(() => {
				setError(true);
				setStats(null);
				setRows([]);
			})
			.finally(() => {
				setLoading(false);
			});
	}, []);

	useEffect(() => {
		void load();
	}, [load]);

	/** 导出 = 聚合矩阵（线 × 送达 + 四事件计数与率），无任何个人级字段（KTD3）。 */
	const exportCsv = () => {
		if (!stats) return;
		const header = [
			t("fbLine"),
			t("fbDelivered"),
			...EVENTS.flatMap((e) => [t(e.label), `${t(e.label)}${t("fbRateSuffix")}`]),
		];
		const body = LINES.map(({ key, label }) => {
			const r = stats[key];
			return [
				t(label),
				String(r.delivered),
				...EVENTS.flatMap((e) => [
					String(r[e.key]),
					pct(r[e.key], r.delivered),
				]),
			];
		});
		const csv = [header, ...body]
			.map((cells) => cells.map((c) => `"${c.replaceAll('"', '""')}"`).join(","))
			.join("\r\n");
		const blob = new Blob([`\uFEFF${csv}`], { type: "text/csv;charset=utf-8" });
		const url = URL.createObjectURL(blob);
		const a = document.createElement("a");
		a.href = url;
		a.download = "flashback-stats.csv";
		a.click();
		URL.revokeObjectURL(url);
	};

	const handleTransition = (id: string, status: string) => {
		updateFlashbackRedemption(id, status, notes[id]?.trim() || undefined)
			.then(() => {
				setUpdateError(false);
				return load();
			})
			.catch(() => setUpdateError(true));
	};

	return (
		<section>
			<div className="admin-page__head">
				<div>
					<h1>{t("flashbackTitle")}</h1>
					<p className="admin-page__desc">{t("flashbackDesc")}</p>
				</div>
				{stats && (
					<button type="button" onClick={exportCsv} className="l-btn-outline">
						{t("fbExport")}
					</button>
				)}
			</div>

			{error && <p className="admin-alert admin-alert--error">{t("loadFailed")}</p>}
			{loading && <p className="admin-muted">{t("loading")}</p>}

			{!loading && !error && stats && (
				<div className="admin-card admin-table-wrap">
					<table className="admin-table">
						<thead>
							<tr>
								<th>{t("fbLine")}</th>
								<th>{t("fbDelivered")}</th>
								{EVENTS.map((e) => (
									<th key={e.key}>{t(e.label)}</th>
								))}
							</tr>
						</thead>
						<tbody>
							{LINES.map(({ key, label }) => {
								const r = stats[key];
								return (
									<tr key={key}>
										<td>{t(label)}</td>
										<td>{r.delivered}</td>
										{EVENTS.map((e) => (
											<td key={e.key}>
												{r[e.key]} ({pct(r[e.key], r.delivered)})
											</td>
										))}
									</tr>
								);
							})}
						</tbody>
					</table>
				</div>
			)}

			{!loading && !error && rows && (
				<div className="admin-page__head">
					<div>
						<h2>{t("fbRedeemTitle")}</h2>
						<p className="admin-page__desc">{t("fbRedeemNote")}</p>
					</div>
				</div>
			)}

			{updateError && (
				<p className="admin-alert admin-alert--error">{t("fbUpdateFailed")}</p>
			)}

			{!loading && !error && rows && rows.length === 0 && (
				<p className="admin-empty">{t("fbNoRedemptions")}</p>
			)}

			{!loading && !error && rows && rows.length > 0 && (
				<div className="admin-card admin-table-wrap">
					<table className="admin-table">
						<thead>
							<tr>
								<th>{t("fbThMaskedName")}</th>
								<th>{t("fbThCity")}</th>
								<th>{t("fbThChannel")}</th>
								<th>{t("fbThStatus")}</th>
								<th>{t("fbThNote")}</th>
								<th>{t("fbThTime")}</th>
								<th>{t("fbThActions")}</th>
							</tr>
						</thead>
						<tbody>
							{rows.map((row) => (
								<tr key={row.id}>
									<td>{row.maskedName ?? "—"}</td>
									<td>{row.city ?? "—"}</td>
									<td>{row.channelNote}</td>
									<td>{t(STATUS_LABEL[row.status] ?? row.status)}</td>
									<td>{row.handledNote ?? "—"}</td>
									<td>{row.insertedAt ? formatDateTime(row.insertedAt) : "—"}</td>
									<td>
										{(NEXT_STATUSES[row.status] ?? []).length > 0 && (
											<div className="admin-toolbar">
												<input
													value={notes[row.id] ?? ""}
													onChange={(e) =>
														setNotes((prev) => ({
															...prev,
															[row.id]: e.target.value,
														}))
													}
													placeholder={t("fbNotePlaceholder")}
													aria-label={`${t("fbThNote")} ${row.maskedName ?? row.id}`}
													className="l-input"
												/>
												{(NEXT_STATUSES[row.status] ?? []).map((next) => (
													<button
														key={next}
														type="button"
														onClick={() => handleTransition(row.id, next)}
														className="l-btn-outline"
													>
														{t(ACTION_LABEL[next])}
													</button>
												))}
											</div>
										)}
										{(NEXT_STATUSES[row.status] ?? []).length === 0 && "—"}
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
