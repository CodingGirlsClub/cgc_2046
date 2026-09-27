"use client";

/**
 * 四率统计卡（U11/R24/KTD10）+ 波次筛选（#984）。
 * batch 空 = 全局；选中波次由父组件带参重取 stats（拆批 = 放弃跨批去重，
 * 口径见后端 AdminStats moduledoc）。EVENTS/LINES/pct 导出给 CSV 导出复用
 * （矩阵口径单源）。
 */
import { useTranslations } from "next-intl";
import type { FlashbackAdminStats } from "@/lib/graphql/admin";

export const EVENTS = [
	{ key: "linkOpened", label: "fbLinkOpened" },
	{ key: "revealed", label: "fbRevealed" },
	{ key: "sentToWall", label: "fbSentToWall" },
	{ key: "intentSubmitted", label: "fbIntentSubmitted" },
] as const;

export const LINES = [
	{ key: "memory", label: "fbLineMemory" },
	{ key: "dream", label: "fbLineDream" },
	{ key: "overall", label: "fbLineOverall" },
] as const;

export function pct(count: number, delivered: number): string {
	if (delivered <= 0) return "—";
	return `${Math.round((count / delivered) * 100)}%`;
}

export function StatsCard({
	stats,
	batches,
	batch,
	onBatchChange,
}: {
	stats: FlashbackAdminStats;
	/** 波次下拉选项（flashbackAdminBatches），空数组 = 只显示「全部波次」。 */
	batches: string[];
	batch: string;
	onBatchChange: (batch: string) => void;
}) {
	const t = useTranslations("admin");

	return (
		<>
			<div className="admin-card admin-toolbar">
				<select
					value={batch}
					onChange={(e) => onBatchChange(e.target.value)}
					aria-label={t("fbBatchFilter")}
				>
					<option value="">{t("fbBatchAll")}</option>
					{batches.map((b) => (
						<option key={b} value={b}>
							{b}
						</option>
					))}
				</select>
			</div>
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
		</>
	);
}
