"use client";

/**
 * 个人 AI 额度与用量明细页 /settings/ai-quota（Plan 008 Slice 3）。
 *
 * - 展示 myLlmWallet 余额、冻结额度、活跃授信批次与到期时间
 * - 扫码收银台：月度订阅（¥29 / ¥99）与永久算力包（¥10 / ¥50 / ¥100 / ¥500）
 * - 用量流水表：基于 before 游标加载更多（myLlmUsageLogs）
 */

import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import { client } from "@/lib/apollo-client";
import { formatDateTime } from "@/lib/format";
import {
	CREATE_LLM_PAYMENT_ORDER,
	MY_LLM_USAGE_LOGS,
	MY_LLM_WALLET,
	type LlmOrderKind,
	type LlmPaymentCheckout,
	type LlmPaymentProvider,
	type LlmUsageLogItem,
	type LlmWalletSummary,
} from "@/lib/graphql/llm-gateway";
import {
	formatMcAsCny,
	formatMcInteger,
	formatTokenCount,
} from "@/lib/llm-credits";
import { PROVIDER_LABEL, formatAmountShort } from "@/lib/payment";
import { useAuthed } from "@/lib/use-authed";
import LlmQrCheckout from "@/components/llm-qr-checkout";
import SitePage from "@/components/site-page";

const LOG_PAGE_SIZE = 20;
const PROVIDERS: readonly LlmPaymentProvider[] = ["wechat_native", "alipay_qr"];

interface CheckoutTier {
	orderKind: Extract<LlmOrderKind, "llm_subscription" | "llm_credit_pack">;
	amountCents: number;
	labelKey: string;
}

const SUBSCRIPTION_TIERS: readonly CheckoutTier[] = [
	{ orderKind: "llm_subscription", amountCents: 2900, labelKey: "tierSub29" },
	{ orderKind: "llm_subscription", amountCents: 9900, labelKey: "tierSub99" },
];

const PACK_TIERS: readonly CheckoutTier[] = [
	{ orderKind: "llm_credit_pack", amountCents: 1000, labelKey: "tierPack10" },
	{ orderKind: "llm_credit_pack", amountCents: 5000, labelKey: "tierPack50" },
	{ orderKind: "llm_credit_pack", amountCents: 10000, labelKey: "tierPack100" },
	{ orderKind: "llm_credit_pack", amountCents: 50000, labelKey: "tierPack500" },
];

const GRANT_SOURCE_KEYS: Record<string, string> = {
	subscription: "sourceSubscription",
	pack: "sourcePack",
	workspace_grant: "sourceWorkspaceGrant",
	admin_gift: "sourceAdminGift",
};

const BILLING_MODE_KEYS: Record<string, string> = {
	exact: "billingExact",
	estimated_abort: "billingEstimatedAbort",
	waived_upstream_error: "billingWaived",
};

function errorMessage(err: unknown, fallback: string): string {
	if (!(err instanceof Error) || !err.message) return fallback;
	if (
		/^(Response not successful|Failed to fetch|NetworkError|Load failed)/i.test(
			err.message,
		)
	) {
		return fallback;
	}
	return err.message;
}

export default function PersonalLlmWalletPage() {
	const t = useTranslations("llmWallet");
	const tCommon = useTranslations("common");
	const labelsT = useTranslations();
	const { authed, confirmed } = useAuthed();

	// 钱包摘要状态
	const [wallet, setWallet] = useState<LlmWalletSummary | null>(null);
	const [walletLoading, setWalletLoading] = useState(true);
	const [walletError, setWalletError] = useState<string | null>(null);

	// 扫码下单状态
	const [provider, setProvider] = useState<LlmPaymentProvider>("wechat_native");
	const [creatingTierKey, setCreatingTierKey] = useState<string | null>(null);
	const [orderError, setOrderError] = useState<string | null>(null);
	const [activeCheckout, setActiveCheckout] = useState<{
		checkout: LlmPaymentCheckout;
		provider: LlmPaymentProvider;
	} | null>(null);

	// 用量日志与游标分页状态
	const [logs, setLogs] = useState<LlmUsageLogItem[]>([]);
	const [logsLoading, setLogsLoading] = useState(true);
	const [logsLoadingMore, setLogsLoadingMore] = useState(false);
	const [logsError, setLogsError] = useState<string | null>(null);
	const [hasMoreLogs, setHasMoreLogs] = useState(false);

	const loadWallet = useCallback(() => {
		setWalletLoading(true);
		setWalletError(null);
		return client
			.query({
				query: MY_LLM_WALLET,
				fetchPolicy: "network-only",
			})
			.then(({ data }) => {
				setWallet(data?.myLlmWallet ?? null);
			})
			.catch((err) => {
				setWalletError(errorMessage(err, t("walletLoadFailed")));
				setWallet(null);
			})
			.finally(() => {
				setWalletLoading(false);
			});
	}, [t]);

	const loadInitialLogs = useCallback(() => {
		setLogsLoading(true);
		setLogsError(null);
		return client
			.query({
				query: MY_LLM_USAGE_LOGS,
				variables: { limit: LOG_PAGE_SIZE },
				fetchPolicy: "network-only",
			})
			.then(({ data }) => {
				const items = data?.myLlmUsageLogs ?? [];
				setLogs(items);
				setHasMoreLogs(items.length === LOG_PAGE_SIZE);
			})
			.catch((err) => {
				setLogsError(errorMessage(err, t("logsLoadFailed")));
				setLogs([]);
				setHasMoreLogs(false);
			})
			.finally(() => {
				setLogsLoading(false);
			});
	}, [t]);

	useEffect(() => {
		if (!authed) return;
		let cancelled = false;

		client
			.query({ query: MY_LLM_WALLET, fetchPolicy: "network-only" })
			.then(({ data }) => {
				if (cancelled) return;
				setWallet(data?.myLlmWallet ?? null);
				setWalletError(null);
			})
			.catch((err) => {
				if (cancelled) return;
				setWalletError(errorMessage(err, t("walletLoadFailed")));
				setWallet(null);
			})
			.finally(() => {
				if (!cancelled) setWalletLoading(false);
			});

		client
			.query({
				query: MY_LLM_USAGE_LOGS,
				variables: { limit: LOG_PAGE_SIZE },
				fetchPolicy: "network-only",
			})
			.then(({ data }) => {
				if (cancelled) return;
				const items = data?.myLlmUsageLogs ?? [];
				setLogs(items);
				setHasMoreLogs(items.length === LOG_PAGE_SIZE);
				setLogsError(null);
			})
			.catch((err) => {
				if (cancelled) return;
				setLogsError(errorMessage(err, t("logsLoadFailed")));
				setLogs([]);
				setHasMoreLogs(false);
			})
			.finally(() => {
				if (!cancelled) setLogsLoading(false);
			});

		return () => {
			cancelled = true;
		};
	}, [authed, t]);

	async function handleLoadMoreLogs() {
		const cursor = logs[logs.length - 1]?.insertedAt;
		if (!cursor || logsLoadingMore) return;
		setLogsLoadingMore(true);
		setLogsError(null);
		try {
			const { data } = await client.query({
				query: MY_LLM_USAGE_LOGS,
				variables: { limit: LOG_PAGE_SIZE, before: cursor },
				fetchPolicy: "network-only",
			});
			const nextItems = data?.myLlmUsageLogs ?? [];
			setLogs((prev) => {
				const seen = new Set(prev.map((item) => item.id));
				const merged = [...prev];
				for (const item of nextItems) {
					if (!seen.has(item.id)) merged.push(item);
				}
				return merged;
			});
			setHasMoreLogs(nextItems.length === LOG_PAGE_SIZE);
		} catch (err) {
			setLogsError(errorMessage(err, t("logsLoadFailed")));
		} finally {
			setLogsLoadingMore(false);
		}
	}

	async function handleSelectTier(tier: CheckoutTier) {
		const tierKey = `${tier.orderKind}:${tier.amountCents}`;
		setCreatingTierKey(tierKey);
		setOrderError(null);
		try {
			const { data } = await client.mutate({
				mutation: CREATE_LLM_PAYMENT_ORDER,
				variables: {
					orderKind: tier.orderKind,
					provider,
					amountCents: tier.amountCents,
					idempotencyKey: crypto.randomUUID(),
				},
			});
			const checkout = data?.createLlmPaymentOrder;
			if (!checkout) {
				setOrderError(t("createOrderFailed"));
				return;
			}
			setActiveCheckout({ checkout, provider });
			if (checkout.order.status === "paid") {
				void loadWallet();
			}
		} catch (err) {
			setOrderError(errorMessage(err, t("createOrderFailed")));
		} finally {
			setCreatingTierKey(null);
		}
	}

	const handleOrderPaid = useCallback(() => {
		void loadWallet();
	}, [loadWallet]);

	if (!confirmed) {
		return (
			<SitePage>
				<div className="mx-auto w-full max-w-5xl px-4 py-10">
					<div
						className="admin-card admin-empty"
						data-testid="wallet-auth-loading"
					>
						{t("loading")}
					</div>
				</div>
			</SitePage>
		);
	}

	if (!authed) {
		return (
			<SitePage>
				<div className="mx-auto w-full max-w-lg px-4 py-10">
					<div className="admin-card admin-card__body text-center">
						<h1 className="text-lg font-medium text-ink">{t("loginTitle")}</h1>
						<p className="text-sm text-ink-3">{t("loginDesc")}</p>
						<div>
							<Link
								href="/login?next=/settings/ai-quota"
								className="l-btn-primary inline-flex"
							>
								{t("loginCta")}
							</Link>
						</div>
					</div>
				</div>
			</SitePage>
		);
	}

	return (
		<SitePage>
			<div className="mx-auto grid w-full max-w-5xl gap-6 px-4 py-8">
				<div className="admin-page__head">
					<div>
						<h1>{t("title")}</h1>
						<p className="admin-page__desc">{t("subtitle")}</p>
					</div>
					<button
						type="button"
						onClick={() => {
							void loadWallet();
							void loadInitialLogs();
						}}
						disabled={walletLoading || logsLoading}
						className="l-btn-outline"
					>
						{t("refresh")}
					</button>
				</div>

				{/* 钱包余额概览 */}
				{walletLoading && !wallet && !walletError ? (
					<div className="admin-card admin-empty" data-testid="wallet-loading">
						{t("loading")}
					</div>
				) : walletError ? (
					<div
						className="admin-card admin-card__body flex flex-wrap items-center justify-between gap-3"
						role="alert"
						data-testid="wallet-error"
					>
						<p className="text-sm text-red-400">{walletError}</p>
						<button
							type="button"
							onClick={() => void loadWallet()}
							className="l-btn-outline"
						>
							{tCommon("retry")}
						</button>
					</div>
				) : !wallet ? (
					<div className="admin-card admin-empty" data-testid="wallet-empty">
						{t("walletEmpty")}
					</div>
				) : (
					<div className="grid gap-4" data-testid="wallet-summary">
						<div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
							<div className="admin-card admin-stat">
								<span className="admin-stat__label">{t("availableBalance")}</span>
								<span
									className="admin-stat__value"
									data-testid="wallet-available-cny"
								>
									{formatMcAsCny(wallet.availableMc)}
								</span>
								<span className="admin-stat__label font-mono">
									{formatMcInteger(wallet.availableMc)} mc
								</span>
							</div>
							<div className="admin-card admin-stat">
								<span className="admin-stat__label">{t("totalBalance")}</span>
								<span
									className="admin-stat__value"
									data-testid="wallet-cached-cny"
								>
									{formatMcAsCny(wallet.cachedBalanceMc)}
								</span>
							</div>
							<div className="admin-card admin-stat">
								<span className="admin-stat__label">{t("heldBalance")}</span>
								<span
									className="admin-stat__value"
									data-testid="wallet-held-cny"
								>
									{formatMcAsCny(wallet.heldMc)}
								</span>
							</div>
							<div className="admin-card admin-stat">
								<span className="admin-stat__label">{t("walletStatus")}</span>
								<div className="mt-1 flex items-center gap-2">
									<span
										className={`l-badge ${
											wallet.status === "active"
												? "l-badge-success"
												: "l-badge-danger"
										}`}
										data-testid="wallet-status-badge"
									>
										{wallet.status === "active"
											? t("statusActive")
											: t("statusFrozen")}
									</span>
									<span className="text-xs text-ink-3">
										{t("remainingPct", { pct: wallet.remainingPercentage })}
									</span>
								</div>
								<span className="admin-stat__label mt-1">
									{t("maxStreams", { count: wallet.maxConcurrentStreams })}
								</span>
								{wallet.status === "frozen" && wallet.frozenReason ? (
									<span
										className="mt-1 text-xs text-red-400"
										data-testid="wallet-frozen-reason"
									>
										{t("frozenReasonLabel", { reason: wallet.frozenReason })}
									</span>
								) : null}
							</div>
						</div>

						{/* 活跃授信批次 */}
						<div>
							<h2 className="admin-section-title">{t("grantsTitle")}</h2>
							{wallet.activeGrants.length === 0 ? (
								<div
									className="admin-card admin-empty"
									data-testid="grants-empty"
								>
									{t("grantsEmpty")}
								</div>
							) : (
								<div className="admin-card admin-table-wrap">
									<table className="admin-table" data-testid="grants-table">
										<thead>
											<tr>
												<th>{t("thGrantSource")}</th>
												<th className="admin-table__num">{t("thGrantRemaining")}</th>
												<th className="admin-table__num">{t("thGrantInitial")}</th>
												<th>{t("thGrantExpires")}</th>
												<th>{t("thGrantCreated")}</th>
											</tr>
										</thead>
										<tbody>
											{wallet.activeGrants.map((grant) => {
												const sourceKey = GRANT_SOURCE_KEYS[grant.sourceType];
												return (
													<tr key={grant.id}>
														<td className="admin-table__primary">
															{sourceKey ? t(sourceKey) : grant.sourceType}
														</td>
														<td className="admin-table__num">
															{formatMcAsCny(grant.remainingMc)}
														</td>
														<td className="admin-table__num">
															{formatMcAsCny(grant.initialMc)}
														</td>
														<td>
															{grant.expiresAt
																? formatDateTime(grant.expiresAt)
																: t("permanent")}
														</td>
														<td>{formatDateTime(grant.insertedAt)}</td>
													</tr>
												);
											})}
										</tbody>
									</table>
								</div>
							)}
						</div>
					</div>
				)}

				{/* 订阅与算力包收银台 */}
				<div className="grid gap-3">
					<h2 className="admin-section-title">{t("checkoutTitle")}</h2>
					<div className="admin-card admin-card__body">
						<div className="flex flex-wrap items-center justify-between gap-3">
							<p className="text-xs text-ink-3">{t("checkoutDesc")}</p>
							<div className="flex flex-wrap items-center gap-2">
								<span className="text-xs text-ink-3">{t("providerLabel")}</span>
								{PROVIDERS.map((p) => (
									<button
										key={p}
										type="button"
										aria-pressed={provider === p}
										onClick={() => setProvider(p)}
										className={
											provider === p ? "l-btn-primary" : "l-btn-outline"
										}
									>
										{PROVIDER_LABEL[p] ? labelsT(PROVIDER_LABEL[p]) : p}
									</button>
								))}
							</div>
						</div>

						{activeCheckout ? (
							<LlmQrCheckout
								order={activeCheckout.checkout.order}
								provider={activeCheckout.provider}
								credential={activeCheckout.checkout.credential}
								onPaid={handleOrderPaid}
								onReset={() => setActiveCheckout(null)}
							/>
						) : (
							<div className="grid items-start gap-4 lg:grid-cols-2">
								<div className="grid gap-2">
									<h3 className="text-sm font-medium text-ink">
										{t("subscriptionTitle")}
									</h3>
									<p className="text-xs text-ink-3">{t("subscriptionDesc")}</p>
									<div className="grid gap-2 sm:grid-cols-2">
										{SUBSCRIPTION_TIERS.map((tier) => {
											const key = `${tier.orderKind}:${tier.amountCents}`;
											const busy = creatingTierKey === key;
											return (
												<button
													key={key}
													type="button"
													disabled={creatingTierKey !== null}
													onClick={() => void handleSelectTier(tier)}
													data-testid={`buy-sub-${tier.amountCents}`}
													className="admin-card admin-stat text-left"
												>
													<span className="admin-stat__value">
														¥{formatAmountShort(tier.amountCents)}
													</span>
													<span className="admin-stat__label">
														{busy ? t("creatingOrder") : t(tier.labelKey)}
													</span>
												</button>
											);
										})}
									</div>
								</div>

								<div className="grid gap-2">
									<h3 className="text-sm font-medium text-ink">
										{t("packTitle")}
									</h3>
									<p className="text-xs text-ink-3">{t("packDesc")}</p>
									<div className="grid gap-2 sm:grid-cols-2">
										{PACK_TIERS.map((tier) => {
											const key = `${tier.orderKind}:${tier.amountCents}`;
											const busy = creatingTierKey === key;
											return (
												<button
													key={key}
													type="button"
													disabled={creatingTierKey !== null}
													onClick={() => void handleSelectTier(tier)}
													data-testid={`buy-pack-${tier.amountCents}`}
													className="admin-card admin-stat text-left"
												>
													<span className="admin-stat__value">
														¥{formatAmountShort(tier.amountCents)}
													</span>
													<span className="admin-stat__label">
														{busy ? t("creatingOrder") : t(tier.labelKey)}
													</span>
												</button>
											);
										})}
									</div>
								</div>
							</div>
						)}

						{orderError && (
							<p role="alert" className="text-xs text-red-400">
								{orderError}
							</p>
						)}
					</div>
				</div>

				{/* 用量明细表 + 加载更多 */}
				<div>
					<h2 className="admin-section-title">{t("usageTitle")}</h2>
					{logsLoading && logs.length === 0 && !logsError ? (
						<div
							className="admin-card admin-empty"
							data-testid="usage-logs-loading"
						>
							{t("loading")}
						</div>
					) : logsError && logs.length === 0 ? (
						<div
							className="admin-card admin-card__body flex flex-wrap items-center justify-between gap-3"
							role="alert"
							data-testid="usage-logs-error"
						>
							<p className="text-sm text-red-400">{logsError}</p>
							<button
								type="button"
								onClick={() => void loadInitialLogs()}
								className="l-btn-outline"
							>
								{tCommon("retry")}
							</button>
						</div>
					) : logs.length === 0 ? (
						<div
							className="admin-card admin-empty"
							data-testid="usage-logs-empty"
						>
							{t("usageEmpty")}
						</div>
					) : (
						<div className="grid gap-3">
							<div className="admin-card admin-table-wrap">
								<table className="admin-table" data-testid="usage-logs-table">
									<thead>
										<tr>
											<th>{t("thLogTime")}</th>
											<th>{t("thLogModel")}</th>
											<th>{t("thLogBillingMode")}</th>
											<th className="admin-table__num">{t("thLogPromptTokens")}</th>
											<th className="admin-table__num">{t("thLogOutputTokens")}</th>
											<th className="admin-table__num">{t("thLogCharged")}</th>
											<th className="admin-table__num">{t("thLogLatency")}</th>
										</tr>
									</thead>
									<tbody>
										{logs.map((log) => {
											const modeKey = BILLING_MODE_KEYS[log.billingMode];
											return (
												<tr key={log.id}>
													<td>{formatDateTime(log.insertedAt)}</td>
													<td className="admin-table__primary l-mono">
														{log.logicalModel}
													</td>
													<td>{modeKey ? t(modeKey) : log.billingMode}</td>
													<td className="admin-table__num">
														{formatTokenCount(log.promptCacheHitTokens)} /{" "}
														{formatTokenCount(log.promptCacheMissTokens)}
													</td>
													<td className="admin-table__num">
														{formatTokenCount(log.completionTokens)}
														{String(log.reasoningTokens) !== "0" && (
															<span className="admin-table__sub">
																{t("reasoningSub", {
																	tokens: formatTokenCount(log.reasoningTokens),
																})}
															</span>
														)}
													</td>
													<td className="admin-table__num">
														{formatMcAsCny(log.chargedMc, { decimals: 4 })}
													</td>
													<td className="admin-table__num">
														{log.ttfbMs != null ? `${log.ttfbMs}ms` : "—"} /{" "}
														{log.durationMs != null ? `${log.durationMs}ms` : "—"}
													</td>
												</tr>
											);
										})}
									</tbody>
								</table>
							</div>

							{logsError && (
								<p role="alert" className="text-xs text-red-400">
									{logsError}
								</p>
							)}

							{hasMoreLogs && (
								<div className="flex justify-center">
									<button
										type="button"
										onClick={() => void handleLoadMoreLogs()}
										disabled={logsLoadingMore}
										data-testid="usage-logs-load-more"
										className="l-btn-outline"
									>
										{logsLoadingMore ? t("loadingMore") : t("loadMore")}
									</button>
								</div>
							)}
						</div>
					)}
				</div>
			</div>
		</SitePage>
	);
}
