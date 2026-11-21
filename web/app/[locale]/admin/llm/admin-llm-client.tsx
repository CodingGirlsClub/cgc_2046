"use client";

/**
 * /admin/llm 平台算力运营与毛利控制台（Plan 008 Slice 2）。
 *
 * - 7 / 14 / 30 天时间窗口聚合 KPI（营收 / 上游成本 / 毛利额与毛利率 / 缓存命中率 / 中断与免单率）
 * - 按日 × 上游渠道明细表（覆盖 loading / empty / error + retry）
 * - 管理员写操作：工作台算力池充值（adminTopupWorkspaceLlmPool）与个人用户赠送算力（adminGrantUserLlmCredits）
 */

import { type FormEvent, useCallback, useEffect, useMemo, useState } from "react";
import { useTranslations } from "next-intl";
import { client } from "@/lib/apollo-client";
import { fromLocalInput } from "@/lib/format";
import {
	ADMIN_GRANT_USER_LLM_CREDITS,
	ADMIN_LLM_USAGE_ANALYTICS,
	ADMIN_TOPUP_WORKSPACE_LLM_POOL,
	ADMIN_UPDATE_USER_LLM_CONCURRENCY,
	ADMIN_UPDATE_USER_LLM_WALLET_STATUS,
	type LlmDailyChannelMetric,
} from "@/lib/graphql/llm-gateway";
import {
	formatMcAsCny,
	formatMcInteger,
	formatPercent,
	formatTokenCount,
	parseCnyInputToMc,
	toBigIntMc,
} from "@/lib/llm-credits";
import ProviderManager from "./provider-manager";

type AdminLlmTab = "analytics" | "providers";

const ZERO = BigInt(0);
const DAY_WINDOWS = [7, 14, 30] as const;
type DayWindow = (typeof DAY_WINDOWS)[number];

interface KpiSummary {
	revenueMc: bigint;
	costMc: bigint;
	marginMc: bigint;
	cacheHitTokens: bigint;
	cacheMissTokens: bigint;
	requestCount: number;
	abortedCount: number;
	waivedCount: number;
}

function summarizeMetrics(rows: LlmDailyChannelMetric[]): KpiSummary {
	return rows.reduce<KpiSummary>(
		(acc, row) => ({
			revenueMc: acc.revenueMc + toBigIntMc(row.totalChargedMc),
			costMc: acc.costMc + toBigIntMc(row.totalUpstreamCostMc),
			marginMc: acc.marginMc + toBigIntMc(row.grossMarginMc),
			cacheHitTokens: acc.cacheHitTokens + toBigIntMc(row.cacheHitTokens),
			cacheMissTokens: acc.cacheMissTokens + toBigIntMc(row.cacheMissTokens),
			requestCount: acc.requestCount + row.requestCount,
			abortedCount: acc.abortedCount + row.abortedCount,
			waivedCount: acc.waivedCount + row.waivedCount,
		}),
		{
			revenueMc: ZERO,
			costMc: ZERO,
			marginMc: ZERO,
			cacheHitTokens: ZERO,
			cacheMissTokens: ZERO,
			requestCount: 0,
			abortedCount: 0,
			waivedCount: 0,
		},
	);
}

function errorMessage(err: unknown, fallback: string): string {
	return err instanceof Error && err.message ? err.message : fallback;
}

export default function AdminLlmClient() {
	const t = useTranslations("adminLlm");
	const [activeTab, setActiveTab] = useState<AdminLlmTab>(() => {
		if (typeof window !== "undefined") {
			const param = new URLSearchParams(window.location.search).get("tab");
			if (param === "providers") return "providers";
		}
		return "analytics";
	});
	const [days, setDays] = useState<DayWindow>(14);
	const [rows, setRows] = useState<LlmDailyChannelMetric[] | null>(null);
	const [loading, setLoading] = useState(true);
	const [error, setError] = useState<string | null>(null);

	// 表单 1：工作台算力池充值
	const [topupWorkspaceId, setTopupWorkspaceId] = useState("");
	const [topupCny, setTopupCny] = useState("");
	const [topupSubmitting, setTopupSubmitting] = useState(false);
	const [topupError, setTopupError] = useState<string | null>(null);
	const [topupSuccess, setTopupSuccess] = useState<string | null>(null);

	// 表单 2：个人用户赠送算力
	const [giftUserId, setGiftUserId] = useState("");
	const [giftCny, setGiftCny] = useState("");
	const [giftExpiresAt, setGiftExpiresAt] = useState("");
	const [giftSubmitting, setGiftSubmitting] = useState(false);
	const [giftError, setGiftError] = useState<string | null>(null);
	const [giftSuccess, setGiftSuccess] = useState<string | null>(null);

	// 表单 3：账户冻结 / 解冻风控
	const [riskStatusUserId, setRiskStatusUserId] = useState("");
	const [riskStatus, setRiskStatus] = useState<"frozen" | "active">("frozen");
	const [riskFrozenReason, setRiskFrozenReason] = useState("");
	const [riskStatusSubmitting, setRiskStatusSubmitting] = useState(false);
	const [riskStatusError, setRiskStatusError] = useState<string | null>(null);
	const [riskStatusSuccess, setRiskStatusSuccess] = useState<string | null>(null);

	// 表单 4：用户并发流上限调整
	const [concurrencyUserId, setConcurrencyUserId] = useState("");
	const [maxConcurrentStreams, setMaxConcurrentStreams] = useState("3");
	const [concurrencySubmitting, setConcurrencySubmitting] = useState(false);
	const [concurrencyError, setConcurrencyError] = useState<string | null>(null);
	const [concurrencySuccess, setConcurrencySuccess] = useState<string | null>(null);

	const loadAnalytics = useCallback((windowDays: DayWindow) => {
		setLoading(true);
		setError(null);
		return client
			.query({
				query: ADMIN_LLM_USAGE_ANALYTICS,
				variables: { days: windowDays },
				fetchPolicy: "network-only",
			})
			.then(({ data }) => {
				setRows(data?.adminLlmUsageAnalytics ?? []);
			})
			.catch((err) => {
				setError(errorMessage(err, t("loadFailed")));
				setRows(null);
			})
			.finally(() => {
				setLoading(false);
			});
	}, [t]);

	useEffect(() => {
		let cancelled = false;
		client
			.query({
				query: ADMIN_LLM_USAGE_ANALYTICS,
				variables: { days },
				fetchPolicy: "network-only",
			})
			.then(({ data }) => {
				if (cancelled) return;
				setRows(data?.adminLlmUsageAnalytics ?? []);
				setError(null);
			})
			.catch((err) => {
				if (cancelled) return;
				setError(errorMessage(err, t("loadFailed")));
				setRows(null);
			})
			.finally(() => {
				if (!cancelled) setLoading(false);
			});

		return () => {
			cancelled = true;
		};
	}, [days, t]);

	const handleSelectDays = (next: DayWindow) => {
		if (next === days) return;
		setLoading(true);
		setError(null);
		setDays(next);
	};

	const summary = useMemo(() => summarizeMetrics(rows ?? []), [rows]);
	const topupMcPreview = useMemo(() => parseCnyInputToMc(topupCny), [topupCny]);
	const giftMcPreview = useMemo(() => parseCnyInputToMc(giftCny), [giftCny]);

	async function handleTopupSubmit(event: FormEvent) {
		event.preventDefault();
		setTopupError(null);
		setTopupSuccess(null);

		const wsId = topupWorkspaceId.trim();
		const amountMc = parseCnyInputToMc(topupCny);
		if (!wsId) {
			setTopupError(t("validationWorkspaceId"));
			return;
		}
		if (amountMc === null) {
			setTopupError(t("validationAmount"));
			return;
		}

		setTopupSubmitting(true);
		try {
			const { data } = await client.mutate({
				mutation: ADMIN_TOPUP_WORKSPACE_LLM_POOL,
				variables: { workspaceId: wsId, amountMc: amountMc.toString() },
			});
			const pool = data?.adminTopupWorkspaceLlmPool;
			if (!pool) {
				setTopupError(t("topupFailed"));
				return;
			}
			setTopupSuccess(
				t("topupSuccess", {
					workspaceId: pool.workspaceId,
					balance: formatMcAsCny(pool.creditPoolMc),
				}),
			);
			setTopupCny("");
		} catch (err) {
			setTopupError(errorMessage(err, t("topupFailed")));
		} finally {
			setTopupSubmitting(false);
		}
	}

	async function handleGiftSubmit(event: FormEvent) {
		event.preventDefault();
		setGiftError(null);
		setGiftSuccess(null);

		const uid = giftUserId.trim();
		const amountMc = parseCnyInputToMc(giftCny);
		if (!uid) {
			setGiftError(t("validationUserId"));
			return;
		}
		if (amountMc === null) {
			setGiftError(t("validationAmount"));
			return;
		}

		const expiresIso = giftExpiresAt ? fromLocalInput(giftExpiresAt) : null;
		setGiftSubmitting(true);
		try {
			const { data } = await client.mutate({
				mutation: ADMIN_GRANT_USER_LLM_CREDITS,
				variables: {
					userId: uid,
					amountMc: amountMc.toString(),
					expiresAt: expiresIso,
				},
			});
			const wallet = data?.adminGrantUserLlmCredits;
			if (!wallet) {
				setGiftError(t("giftFailed"));
				return;
			}
			setGiftSuccess(
				t("giftSuccess", {
					userId: uid,
					available: formatMcAsCny(wallet.availableMc),
				}),
			);
			setGiftCny("");
			setGiftExpiresAt("");
		} catch (err) {
			setGiftError(errorMessage(err, t("giftFailed")));
		} finally {
			setGiftSubmitting(false);
		}
	}

	async function handleRiskStatusSubmit(event: FormEvent) {
		event.preventDefault();
		setRiskStatusError(null);
		setRiskStatusSuccess(null);

		const uid = riskStatusUserId.trim();
		if (!uid) {
			setRiskStatusError(t("validationUserId"));
			return;
		}

		const reason =
			riskStatus === "frozen" && riskFrozenReason.trim()
				? riskFrozenReason.trim()
				: null;

		setRiskStatusSubmitting(true);
		try {
			const { data } = await client.mutate({
				mutation: ADMIN_UPDATE_USER_LLM_WALLET_STATUS,
				variables: {
					userId: uid,
					status: riskStatus,
					frozenReason: reason,
				},
			});
			const wallet = data?.adminUpdateUserLlmWalletStatus;
			if (!wallet) {
				setRiskStatusError(t("riskStatusFailed"));
				return;
			}
			setRiskStatusSuccess(
				wallet.status === "frozen"
					? t("riskFreezeSuccess", { userId: uid })
					: t("riskUnfreezeSuccess", { userId: uid }),
			);
			if (wallet.status === "active") {
				setRiskFrozenReason("");
			}
		} catch (err) {
			setRiskStatusError(errorMessage(err, t("riskStatusFailed")));
		} finally {
			setRiskStatusSubmitting(false);
		}
	}

	async function handleConcurrencySubmit(event: FormEvent) {
		event.preventDefault();
		setConcurrencyError(null);
		setConcurrencySuccess(null);

		const uid = concurrencyUserId.trim();
		if (!uid) {
			setConcurrencyError(t("validationUserId"));
			return;
		}
		const parsed = Number.parseInt(maxConcurrentStreams, 10);
		if (!Number.isInteger(parsed) || parsed < 1 || parsed > 20) {
			setConcurrencyError(t("validationConcurrency"));
			return;
		}

		setConcurrencySubmitting(true);
		try {
			const { data } = await client.mutate({
				mutation: ADMIN_UPDATE_USER_LLM_CONCURRENCY,
				variables: {
					userId: uid,
					maxConcurrentStreams: parsed,
				},
			});
			const wallet = data?.adminUpdateUserLlmConcurrency;
			if (!wallet) {
				setConcurrencyError(t("concurrencyFailed"));
				return;
			}
			setConcurrencySuccess(
				t("concurrencySuccess", {
					userId: uid,
					limit: wallet.maxConcurrentStreams,
				}),
			);
		} catch (err) {
			setConcurrencyError(errorMessage(err, t("concurrencyFailed")));
		} finally {
			setConcurrencySubmitting(false);
		}
	}

	const marginPct = formatPercent(summary.marginMc, summary.revenueMc, 1);
	const cacheHitPct = formatPercent(
		summary.cacheHitTokens,
		summary.cacheHitTokens + summary.cacheMissTokens,
		1,
	);
	const abortWaivedCount = summary.abortedCount + summary.waivedCount;
	const abortWaivedPct = formatPercent(abortWaivedCount, summary.requestCount, 1);

	return (
		<section className="grid gap-6">
			<div className="admin-page__head">
				<div>
					<h1>{t("title")}</h1>
					<p className="admin-page__desc">{t("subtitle")}</p>
				</div>
				<div className="flex flex-wrap items-center gap-2">
					<div className="admin-tabs" role="tablist" aria-label={t("sectionTabsAria")}>
						<button
							type="button"
							role="tab"
							aria-selected={activeTab === "analytics"}
							onClick={() => setActiveTab("analytics")}
							className={`admin-tabs__tab ${activeTab === "analytics" ? "bg-card text-ink font-medium" : ""}`}
						>
							{t("tabAnalytics")}
						</button>
						<button
							type="button"
							role="tab"
							aria-selected={activeTab === "providers"}
							onClick={() => setActiveTab("providers")}
							className={`admin-tabs__tab ${activeTab === "providers" ? "bg-card text-ink font-medium" : ""}`}
						>
							{t("tabProviders")}
						</button>
					</div>
					{activeTab === "analytics" && (
						<>
							<div className="admin-tabs" role="group" aria-label={t("windowAria")}>
								{DAY_WINDOWS.map((w) => (
									<button
										key={w}
										type="button"
										aria-pressed={days === w}
										onClick={() => handleSelectDays(w)}
										className={`admin-tabs__tab ${days === w ? "bg-card text-ink font-medium" : ""}`}
									>
										{t("daysOption", { days: w })}
									</button>
								))}
							</div>
							<button
								type="button"
								onClick={() => void loadAnalytics(days)}
								disabled={loading}
								className="l-btn-outline"
							>
								{t("refresh")}
							</button>
						</>
					)}
				</div>
			</div>

			{activeTab === "providers" ? (
				<ProviderManager />
			) : (
				<>

			{/* KPI 汇总卡片 */}
			<div
				className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5"
				data-testid="admin-llm-kpis"
			>
				<div className="admin-card admin-stat">
					<span className="admin-stat__label">{t("kpiRevenue")}</span>
					<span className="admin-stat__value" data-testid="kpi-revenue">
						{loading ? "—" : formatMcAsCny(summary.revenueMc)}
					</span>
				</div>
				<div className="admin-card admin-stat">
					<span className="admin-stat__label">{t("kpiCost")}</span>
					<span className="admin-stat__value" data-testid="kpi-cost">
						{loading ? "—" : formatMcAsCny(summary.costMc)}
					</span>
				</div>
				<div className="admin-card admin-stat">
					<span className="admin-stat__label">{t("kpiMargin")}</span>
					<span
						className={`admin-stat__value ${
							summary.marginMc < ZERO ? "text-red-400" : ""
						}`}
						data-testid="kpi-margin"
					>
						{loading ? "—" : formatMcAsCny(summary.marginMc)}
					</span>
					<span className="admin-stat__label" data-testid="kpi-margin-pct">
						{loading ? "" : t("marginRate", { pct: marginPct })}
					</span>
				</div>
				<div className="admin-card admin-stat">
					<span className="admin-stat__label">{t("kpiCacheHit")}</span>
					<span className="admin-stat__value" data-testid="kpi-cache-hit">
						{loading ? "—" : cacheHitPct}
					</span>
					<span className="admin-stat__label">
						{loading
							? ""
							: t("cacheTokensSub", {
									hit: formatTokenCount(summary.cacheHitTokens),
									miss: formatTokenCount(summary.cacheMissTokens),
								})}
					</span>
				</div>
				<div className="admin-card admin-stat">
					<span className="admin-stat__label">{t("kpiAbortWaived")}</span>
					<span className="admin-stat__value" data-testid="kpi-abort-waived">
						{loading ? "—" : abortWaivedPct}
					</span>
					<span className="admin-stat__label">
						{loading
							? ""
							: t("abortWaivedSub", {
									aborted: summary.abortedCount,
									waived: summary.waivedCount,
									total: summary.requestCount,
								})}
					</span>
				</div>
			</div>

			{/* 按日 × 渠道明细表 */}
			<div>
				<h2 className="admin-section-title">{t("breakdownTitle")}</h2>
				{error && (
					<div
						className="admin-card admin-card__body flex flex-wrap items-center justify-between gap-3"
						role="alert"
						data-testid="admin-llm-error"
					>
						<p className="text-sm text-red-400">{error}</p>
						<button
							type="button"
							onClick={() => void loadAnalytics(days)}
							className="l-btn-outline"
						>
							{t("retry")}
						</button>
					</div>
				)}
				{loading && !error && (
					<div
						className="admin-card admin-empty"
						data-testid="admin-llm-loading"
					>
						{t("loading")}
					</div>
				)}
				{!loading && !error && rows && rows.length === 0 && (
					<div className="admin-card admin-empty" data-testid="admin-llm-empty">
						{t("empty")}
					</div>
				)}
				{!loading && !error && rows && rows.length > 0 && (
					<div className="admin-card admin-table-wrap">
						<table className="admin-table" data-testid="admin-llm-table">
							<thead>
								<tr>
									<th>{t("thDay")}</th>
									<th>{t("thChannel")}</th>
									<th className="admin-table__num">{t("thRequests")}</th>
									<th className="admin-table__num">{t("thAbortedWaived")}</th>
									<th className="admin-table__num">{t("thCacheHit")}</th>
									<th className="admin-table__num">{t("thCompletion")}</th>
									<th className="admin-table__num">{t("thRevenue")}</th>
									<th className="admin-table__num">{t("thCost")}</th>
									<th className="admin-table__num">{t("thMargin")}</th>
								</tr>
							</thead>
							<tbody>
								{rows.map((row) => {
									const hit = toBigIntMc(row.cacheHitTokens);
									const miss = toBigIntMc(row.cacheMissTokens);
									const rev = toBigIntMc(row.totalChargedMc);
									const margin = toBigIntMc(row.grossMarginMc);
									return (
										<tr key={`${row.day}-${row.upstreamChannel}`}>
											<td className="l-mono">{row.day}</td>
											<td className="admin-table__primary">{row.upstreamChannel}</td>
											<td className="admin-table__num">{row.requestCount}</td>
											<td className="admin-table__num">
												{row.abortedCount} / {row.waivedCount}
											</td>
											<td className="admin-table__num">
												{formatPercent(hit, hit + miss, 1)}
											</td>
											<td className="admin-table__num">
												{formatTokenCount(row.completionTokens)}
											</td>
											<td className="admin-table__num">{formatMcAsCny(rev)}</td>
											<td className="admin-table__num">
												{formatMcAsCny(row.totalUpstreamCostMc)}
											</td>
											<td className="admin-table__num">
												<span className={margin < ZERO ? "text-red-400" : ""}>
													{formatMcAsCny(margin)}
												</span>
												<span className="admin-table__sub">
													{formatPercent(margin, rev, 1)}
												</span>
											</td>
										</tr>
									);
								})}
							</tbody>
						</table>
					</div>
				)}
			</div>

			{/* 管理员运营表单：工作台充值 & 个人赠送 */}
			<div>
				<h2 className="admin-section-title">{t("opsTitle")}</h2>
				<div className="grid gap-4 lg:grid-cols-2">
					<form
						onSubmit={(e) => void handleTopupSubmit(e)}
						className="admin-card admin-card__body"
						data-testid="admin-topup-form"
					>
						<div>
							<h3 className="text-sm font-medium text-ink">{t("topupTitle")}</h3>
							<p className="mt-1 text-xs text-ink-3">{t("topupDesc")}</p>
						</div>
						<label className="grid gap-1.5 text-xs text-ink-2">
							<span>{t("workspaceIdLabel")}</span>
							<input
								type="text"
								value={topupWorkspaceId}
								onChange={(e) => setTopupWorkspaceId(e.target.value)}
								placeholder={t("workspaceIdPlaceholder")}
								className="l-input"
							/>
						</label>
						<label className="grid gap-1.5 text-xs text-ink-2">
							<span>{t("amountCnyLabel")}</span>
							<input
								type="text"
								inputMode="decimal"
								value={topupCny}
								onChange={(e) => setTopupCny(e.target.value)}
								placeholder="100.00"
								className="l-input"
							/>
							{topupMcPreview !== null && (
								<span className="font-mono text-xs text-ink-3">
									= {formatMcInteger(topupMcPreview)} mc
								</span>
							)}
						</label>
						{topupError && (
							<p role="alert" className="text-xs text-red-400">
								{topupError}
							</p>
						)}
						{topupSuccess && (
							<p role="status" className="text-xs text-emerald-400">
								{topupSuccess}
							</p>
						)}
						<div>
							<button
								type="submit"
								disabled={topupSubmitting}
								className="l-btn-primary"
							>
								{topupSubmitting ? t("submitting") : t("topupSubmit")}
							</button>
						</div>
					</form>

					<form
						onSubmit={(e) => void handleGiftSubmit(e)}
						className="admin-card admin-card__body"
						data-testid="admin-gift-form"
					>
						<div>
							<h3 className="text-sm font-medium text-ink">{t("giftTitle")}</h3>
							<p className="mt-1 text-xs text-ink-3">{t("giftDesc")}</p>
						</div>
						<label className="grid gap-1.5 text-xs text-ink-2">
							<span>{t("userIdLabel")}</span>
							<input
								type="text"
								value={giftUserId}
								onChange={(e) => setGiftUserId(e.target.value)}
								placeholder={t("userIdPlaceholder")}
								className="l-input"
							/>
						</label>
						<label className="grid gap-1.5 text-xs text-ink-2">
							<span>{t("amountCnyLabel")}</span>
							<input
								type="text"
								inputMode="decimal"
								value={giftCny}
								onChange={(e) => setGiftCny(e.target.value)}
								placeholder="20.00"
								className="l-input"
							/>
							{giftMcPreview !== null && (
								<span className="font-mono text-xs text-ink-3">
									= {formatMcInteger(giftMcPreview)} mc
								</span>
							)}
						</label>
						<label className="grid gap-1.5 text-xs text-ink-2">
							<span>{t("expiresAtLabel")}</span>
							<input
								type="datetime-local"
								value={giftExpiresAt}
								onChange={(e) => setGiftExpiresAt(e.target.value)}
								className="l-input"
							/>
							<span className="text-xs text-ink-3">{t("expiresAtHint")}</span>
						</label>
						{giftError && (
							<p role="alert" className="text-xs text-red-400">
								{giftError}
							</p>
						)}
						{giftSuccess && (
							<p role="status" className="text-xs text-emerald-400">
								{giftSuccess}
							</p>
						)}
						<div>
							<button
								type="submit"
								disabled={giftSubmitting}
								className="l-btn-primary"
							>
								{giftSubmitting ? t("submitting") : t("giftSubmit")}
							</button>
						</div>
					</form>

					<form
						onSubmit={(e) => void handleRiskStatusSubmit(e)}
						className="admin-card admin-card__body"
						data-testid="admin-wallet-status-form"
					>
						<div>
							<h3 className="text-sm font-medium text-ink">{t("riskStatusTitle")}</h3>
							<p className="mt-1 text-xs text-ink-3">{t("riskStatusDesc")}</p>
						</div>
						<label className="grid gap-1.5 text-xs text-ink-2">
							<span>{t("userIdLabel")}</span>
							<input
								type="text"
								value={riskStatusUserId}
								onChange={(e) => setRiskStatusUserId(e.target.value)}
								placeholder={t("userIdPlaceholder")}
								className="l-input"
							/>
						</label>
						<div className="grid gap-1.5 text-xs text-ink-2">
							<span>{t("riskActionLabel")}</span>
							<div className="flex flex-wrap gap-2">
								<button
									type="button"
									aria-pressed={riskStatus === "frozen"}
									onClick={() => setRiskStatus("frozen")}
									className={
										riskStatus === "frozen" ? "l-btn-primary" : "l-btn-outline"
									}
								>
									{t("riskActionFreeze")}
								</button>
								<button
									type="button"
									aria-pressed={riskStatus === "active"}
									onClick={() => setRiskStatus("active")}
									className={
										riskStatus === "active" ? "l-btn-primary" : "l-btn-outline"
									}
								>
									{t("riskActionUnfreeze")}
								</button>
							</div>
						</div>
						{riskStatus === "frozen" && (
							<label className="grid gap-1.5 text-xs text-ink-2">
								<span>{t("frozenReasonLabel")}</span>
								<input
									type="text"
									maxLength={200}
									value={riskFrozenReason}
									onChange={(e) => setRiskFrozenReason(e.target.value)}
									placeholder={t("frozenReasonPlaceholder")}
									className="l-input"
								/>
							</label>
						)}
						{riskStatusError && (
							<p role="alert" className="text-xs text-red-400">
								{riskStatusError}
							</p>
						)}
						{riskStatusSuccess && (
							<p role="status" className="text-xs text-emerald-400">
								{riskStatusSuccess}
							</p>
						)}
						<div>
							<button
								type="submit"
								disabled={riskStatusSubmitting}
								className="l-btn-primary"
							>
								{riskStatusSubmitting ? t("submitting") : t("riskStatusSubmit")}
							</button>
						</div>
					</form>

					<form
						onSubmit={(e) => void handleConcurrencySubmit(e)}
						className="admin-card admin-card__body"
						data-testid="admin-wallet-concurrency-form"
					>
						<div>
							<h3 className="text-sm font-medium text-ink">
								{t("concurrencyTitle")}
							</h3>
							<p className="mt-1 text-xs text-ink-3">{t("concurrencyDesc")}</p>
						</div>
						<label className="grid gap-1.5 text-xs text-ink-2">
							<span>{t("userIdLabel")}</span>
							<input
								type="text"
								value={concurrencyUserId}
								onChange={(e) => setConcurrencyUserId(e.target.value)}
								placeholder={t("userIdPlaceholder")}
								className="l-input"
							/>
						</label>
						<label className="grid gap-1.5 text-xs text-ink-2">
							<span>{t("concurrencyLimitLabel")}</span>
							<input
								type="number"
								min={1}
								max={20}
								value={maxConcurrentStreams}
								onChange={(e) => setMaxConcurrentStreams(e.target.value)}
								className="l-input"
							/>
							<span className="text-xs text-ink-3">
								{t("concurrencyLimitHint")}
							</span>
						</label>
						{concurrencyError && (
							<p role="alert" className="text-xs text-red-400">
								{concurrencyError}
							</p>
						)}
						{concurrencySuccess && (
							<p role="status" className="text-xs text-emerald-400">
								{concurrencySuccess}
							</p>
						)}
						<div>
							<button
								type="submit"
								disabled={concurrencySubmitting}
								className="l-btn-primary"
							>
								{concurrencySubmitting
									? t("submitting")
									: t("concurrencySubmit")}
							</button>
						</div>
					</form>
				</div>
			</div>
				</>
			)}
		</section>
	);
}
