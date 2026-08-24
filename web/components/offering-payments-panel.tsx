"use client";

/**
 * 活动经营面：本活动的钱一屏可见可操作（organizer-payment U7，R3/R5/R6/R7）。
 *
 * - 自包含面板（KTD1，先例 sponsorship-management）：自取数、自带测试文件，
 *   插入 OfferingDetailPage 的全宽面板栈；manage（canManageEvents）门控渲染
 *   （AE6），非 manage 不渲染。
 * - 收费状态（R3）：免费态收敛为一行免费状态（不拉订单查询，AE4）。
 * - 四数统计（R5）：带 offering 参数的 workspacePaymentStats（与工作区口径
 *   同源，KTD3）。
 * - 订单列表（R6）：workspaceOrders 按 event_id/course_id 筛选；默认非终态 +
 *   已退款（终态经状态筛选可见）。
 * - 行内操作（R7）：待付单免缴（waivePayment）、已付单退款（refundOrder，
 *   二次确认先例 payments-management）、refund_failed 单重试（retryRefund）。
 */

import { useEffect, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { client } from "@/lib/apollo-client";
import {
	REFUND_ORDER,
	RETRY_REFUND,
	WAIVE_PAYMENT,
	WORKSPACE_ORDERS,
	WORKSPACE_PAYMENT_STATS,
	type Order,
} from "@/lib/graphql/orders";
import {
	ORDER_STATUS_LABEL,
	PROVIDER_LABEL,
	formatAmount,
	parsePaymentStats,
	type PaymentStats,
} from "@/lib/payment";
import { usePaymentErrorTranslator } from "@/lib/payment-errors";

const STATUS_BADGE_CLASS: Record<string, string> = {
	pending: "bg-soft-2 text-ink-2",
	paid: "bg-emerald-500/10 text-emerald-300",
	refunding: "bg-sky-500/10 text-sky-300",
	refunded: "bg-soft-2 text-ink-3",
	refund_failed: "bg-red-500/10 text-red-300",
	cancelled: "bg-soft-2 text-ink-3",
	expired: "bg-soft-2 text-ink-3",
};

/** U7 keyset 分页页大小（plan Outstanding Question：实施定夺，20/页） */
const PAGE_SIZE = 20;

function statusBadgeClass(status: string): string {
	return STATUS_BADGE_CLASS[status] ?? "bg-soft-2 text-ink-3";
}

export default function OfferingPaymentsPanel({
	workspaceId,
	offeringId,
	kind,
	manage,
	pricingEnabled,
}: {
	workspaceId: string;
	offeringId: string;
	kind: "event" | "course";
	manage: boolean;
	pricingEnabled: boolean;
}) {
	const t = useTranslations("offeringPayments");
	const labelsT = useTranslations();
	const translatePaymentError = usePaymentErrorTranslator();

	const [statusFilter, setStatusFilter] = useState("");
	const [orders, setOrders] = useState<Order[]>([]);
	const [stats, setStats] = useState<PaymentStats | null>(null);
	const [statsError, setStatsError] = useState(false);
	const [loadState, setLoadState] = useState<"loading" | "ok" | "error">("loading");
	const [busy, setBusy] = useState(false);
	const [refundTarget, setRefundTarget] = useState<Order | null>(null);
	const [actionError, setActionError] = useState<string | null>(null);
	// U7 keyset 分页：after = 上一页 endKeyset；满页即可能有下一页
	const [endKeyset, setEndKeyset] = useState<string | null>(null);
	const [hasMore, setHasMore] = useState(false);
	const [loadingMore, setLoadingMore] = useState(false);
	// review F12：请求代守卫——筛选切换后的迟到响应不得覆写/追加新筛选的结果
	const reqGen = useRef(0);

	// 免费态收敛一行（AE4）：不拉订单/统计查询
	const panelKey = kind === "event" ? "eventId" : "courseId";
	async function load(filter: string) {
		// F12：新请求作废在途响应（筛选切换重置游标 + 拒绝迟到覆写）
		const gen = ++reqGen.current;
		setLoadState("loading");
		try {
			// R6 默认视图：非终态 + 已退款；终态（cancelled/expired）经状态筛选可见
			const defaultStatuses = ["pending", "paid", "refunding", "refund_failed", "refunded"];
			const { data } = await client.query({
				query: WORKSPACE_ORDERS,
				variables: {
					workspaceId,
					filter: {
						[panelKey]: { eq: offeringId },
						...(filter
							? { status: { eq: filter } }
							: { status: { in: defaultStatuses } }),
					},
					first: PAGE_SIZE,
				},
			});
			if (gen !== reqGen.current) return;
			const page = data?.workspaceOrders;
			setOrders(page?.results ?? []);
			setEndKeyset(page?.endKeyset ?? null);
			setHasMore((page?.results ?? []).length === PAGE_SIZE);
			setLoadState("ok");
		} catch {
			if (gen === reqGen.current) setLoadState("error");
		}
	}

	async function loadMore(filter: string) {
		if (loadingMore || !endKeyset) return;
		const gen = reqGen.current;
		setLoadingMore(true);
		try {
			const defaultStatuses = ["pending", "paid", "refunding", "refund_failed", "refunded"];
			const { data } = await client.query({
				query: WORKSPACE_ORDERS,
				variables: {
					workspaceId,
					filter: {
						[panelKey]: { eq: offeringId },
						...(filter
							? { status: { eq: filter } }
							: { status: { in: defaultStatuses } }),
					},
					first: PAGE_SIZE,
					after: endKeyset,
				},
			});
			// F12：期间发生了筛选切换（代已前进）→ 丢弃本页（不追加进新筛选）
			if (gen !== reqGen.current) return;
			const page = data?.workspaceOrders;
			setOrders((prev) => [...prev, ...(page?.results ?? [])]);
			setEndKeyset(page?.endKeyset ?? null);
			setHasMore((page?.results ?? []).length === PAGE_SIZE);
		} catch {
			if (gen === reqGen.current) setHasMore(false);
		} finally {
			setLoadingMore(false);
		}
	}

	async function loadStats() {
		setStatsError(false);
		try {
			const { data } = await client.query({
				query: WORKSPACE_PAYMENT_STATS,
				variables: { workspaceId, [panelKey]: offeringId },
			});
			setStats(parsePaymentStats(data?.workspacePaymentStats));
		} catch {
			setStats(null);
			setStatsError(true);
		}
	}

	// 初拉（offering 维度变化时；ref 防串台）
	const loadedFor = useRef("");
	useEffect(() => {
		if (!manage) return;
		// F13：免费活动也拉数据——关闭收费故意保留已付订单，历史与退款
		// 操作不因免费态消失（有已付订单时渲染完整面板）
		const key = `${workspaceId}:${offeringId}`;
		if (loadedFor.current === key) return;
		loadedFor.current = key;
		void load(statusFilter);
		void loadStats();
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [workspaceId, offeringId, manage]);

	if (!manage) return null;

	// F13：免费态且无任何订单/统计负担 → 收敛一行；有已付历史则完整面板
	if (!pricingEnabled && orders.length === 0 && !statsError && (stats?.collectedCents ?? 0) === 0) {
		return (
			<section
				className="rounded-large border border-line bg-card p-4"
				data-testid="offering-payments-panel"
			>
				<h2 className="text-sm font-medium text-ink">{t("title")}</h2>
				<p className="mt-2 text-sm text-ink-3" data-testid="offering-free-status">
					{t("freeStatus")}
				</p>
			</section>
		);
	}

	async function confirmRefund() {
		if (!refundTarget) return;
		await runAction(REFUND_ORDER, { id: refundTarget.id }, "refundOrder", "refundFailed", () =>
			setRefundTarget(null),
		);
	}

	async function waive(order: Order) {
		await runAction(WAIVE_PAYMENT, { id: order.enrollmentId }, "waivePayment", "waiveFailed");
	}

	async function retry(order: Order) {
		await runAction(RETRY_REFUND, { id: order.id }, "retryRefund", "retryFailed");
	}

	async function runAction(
		mutation: Parameters<typeof client.mutate>[0]["mutation"],
		variables: Record<string, string>,
		dataKey: string,
		errorKey: string,
		onOk?: () => void,
	) {
		setBusy(true);
		setActionError(null);
		try {
			const { data } = await client.mutate({ mutation, variables });
			// 三 mutation 返回同形状 { result, errors }（TypedDocumentNode 泛型合并困难，窄化为结构形状）
			const payload = (data as Record<string, { result?: unknown; errors?: Array<{ code?: string }> }> | undefined)?.[dataKey];
			if (payload?.result) {
				onOk?.();
				await Promise.all([load(statusFilter), loadStats()]);
			} else {
				setActionError(
					translatePaymentError(payload?.errors?.[0]?.code, t(errorKey)),
				);
			}
		} catch (e) {
			setActionError(
				translatePaymentError(
					e instanceof Error ? e.message : null,
					t(errorKey),
				),
			);
		} finally {
			setBusy(false);
		}
	}

	const statusFilters = [
		{ value: "", label: t("filterDefault") },
		{ value: "pending", label: labelsT(ORDER_STATUS_LABEL.pending) },
		{ value: "paid", label: labelsT(ORDER_STATUS_LABEL.paid) },
		{ value: "refunding", label: labelsT(ORDER_STATUS_LABEL.refunding) },
		{ value: "refunded", label: labelsT(ORDER_STATUS_LABEL.refunded) },
		{ value: "refund_failed", label: labelsT(ORDER_STATUS_LABEL.refund_failed) },
		{ value: "cancelled", label: labelsT(ORDER_STATUS_LABEL.cancelled) },
		{ value: "expired", label: labelsT(ORDER_STATUS_LABEL.expired) },
	];

	return (
		<section
			className="rounded-large border border-line bg-card p-4"
			data-testid="offering-payments-panel"
		>
			<h2 className="text-sm font-medium text-ink">{t("title")}</h2>

			{/* R5 四数统计（带 offering 参数，与工作区面板同口径） */}
			<div className="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-4">
				{statsError ? (
					<p className="col-span-full text-sm text-ink-3" role="alert">
						{t("statsFailed")}
						<button type="button" className="underline" onClick={() => void loadStats()}>
							{t("retry")}
						</button>
					</p>
				) : (
					<>
						<StatCard label={t("statCollected")} value={stats?.collectedCents} />
						<StatCard label={t("statPending")} value={stats?.pendingCents} />
						<StatCard label={t("statRefunded")} value={stats?.refundedCents} />
						<StatCard
							label={t("statRefundFailed")}
							value={stats?.refundFailedCents}
							danger={stats?.refundFailedCents ? (stats.refundFailedCents > 0) : false}
						/>
					</>
				)}
			</div>

			{/* R6 订单列表 */}
			<div className="mt-4">
				<div className="flex flex-wrap items-center justify-between gap-3">
					<h3 className="text-[13px] font-medium text-ink-2">{t("listTitle")}</h3>
					<label className="flex items-center gap-2 text-[13px] text-ink-3">
						{t("filterLabel")}
						<select
							value={statusFilter}
							onChange={(e) => {
								setStatusFilter(e.target.value);
								void load(e.target.value);
							}}
							className="rounded-large border border-line bg-soft-2 px-2 py-1 text-sm text-ink"
							data-testid="offering-status-filter"
						>
							{statusFilters.map((f) => (
								<option key={f.value} value={f.value}>
									{f.label}
								</option>
							))}
						</select>
					</label>
				</div>

				{actionError ? (
					<p role="alert" className="mt-3 text-[13px] text-red-300">
						{actionError}
					</p>
				) : null}

				{refundTarget ? (
					<div
						className="mt-3 rounded-large border border-amber-400/30 bg-amber-500/10 p-3"
						role="group"
						aria-label={t("confirmRefund")}
					>
						<p className="text-sm text-amber-200">
							{t("refundConfirm")}（¥{formatAmount(refundTarget.amountCents)}）
						</p>
						<div className="mt-3 flex flex-wrap gap-2">
							<button
								type="button"
								className="join-button join-button--primary"
								disabled={busy}
								onClick={() => void confirmRefund()}
								data-testid="offering-refund-confirm"
							>
								{busy ? t("refundBusy") : t("confirmRefund")}
							</button>
							<button
								type="button"
								className="join-button"
								disabled={busy}
								onClick={() => setRefundTarget(null)}
								data-testid="offering-refund-cancel"
							>
								{t("refundCancel")}
							</button>
						</div>
					</div>
				) : null}

				{loadState === "loading" ? (
					<div className="mt-3 h-16 animate-pulse rounded-large bg-soft-2" />
				) : loadState === "error" ? (
					<p className="mt-3 text-sm text-ink-3" role="alert">
						{t("loadFailed")}
						<button type="button" className="underline" onClick={() => void load(statusFilter)}>
							{t("retry")}
						</button>
					</p>
				) : orders.length === 0 ? (
					<p className="mt-3 text-sm text-ink-3" data-testid="offering-orders-empty">
						{t("emptyOrders")}
					</p>
				) : (
					<div className="mt-3 overflow-x-auto">
						<table className="w-full min-w-[720px] text-left text-sm">
							<thead>
								<tr className="text-[13px] text-ink-3">
									<th className="px-3 py-2 font-normal">{t("thEnrollee")}</th>
									<th className="px-3 py-2 font-normal">{t("thTier")}</th>
									<th className="px-3 py-2 font-normal">{t("thAmount")}</th>
									<th className="px-3 py-2 font-normal">{t("thChannel")}</th>
									<th className="px-3 py-2 font-normal">{t("thStatus")}</th>
									<th className="px-3 py-2 font-normal">{t("thActions")}</th>
								</tr>
							</thead>
							<tbody>
								{orders.map((order) => (
									<tr
										key={order.id}
										className="border-t border-line"
										data-testid={`order-row-${order.id}`}
									>
										<td className="px-3 py-2 text-ink">{order.learnerEmail ?? "—"}</td>
										<td className="px-3 py-2 text-ink-2">{order.tierName ?? "—"}</td>
										<td className="px-3 py-2 text-ink">¥{formatAmount(order.amountCents)}</td>
										<td className="px-3 py-2 text-ink-3">
											{labelsT(PROVIDER_LABEL[order.provider] ?? order.provider)}
										</td>
										<td className="px-3 py-2">
											<span
												className={`inline-block rounded-full px-2 py-0.5 text-xs ${statusBadgeClass(order.status)}`}
											>
												{labelsT(ORDER_STATUS_LABEL[order.status] ?? order.status)}
											</span>
										</td>
										<td className="px-3 py-2">
											<div className="flex flex-wrap gap-2">
												{order.status === "pending" && (
													<button
														type="button"
														className="rounded-large border border-line px-2.5 py-1 text-xs text-ink-2 hover:border-line-strong"
														disabled={busy}
														onClick={() => void waive(order)}
														data-testid={`offering-waive-${order.id}`}
													>
														{t("waive")}
													</button>
												)}
												{order.status === "paid" && (
													<button
														type="button"
														className="rounded-large border border-line px-2.5 py-1 text-xs text-ink-2 hover:border-line-strong"
														disabled={busy}
														onClick={() => setRefundTarget(order)}
														data-testid={`offering-refund-${order.id}`}
													>
														{t("refund")}
													</button>
												)}
												{order.status === "refund_failed" && (
													<button
														type="button"
														className="rounded-large border border-red-400/40 px-2.5 py-1 text-xs text-red-300 hover:border-red-400"
														disabled={busy}
														onClick={() => void retry(order)}
														data-testid={`offering-retry-${order.id}`}
													>
														{t("retryRefund")}
													</button>
												)}
											</div>
										</td>
									</tr>
								))}
						</tbody>
					</table>
				</div>
				)}
				{hasMore && loadState === "ok" ? (
					<div className="mt-3 flex justify-center">
						<button
							type="button"
							className="rounded-large border border-line px-4 py-2 text-sm text-ink-2 hover:border-line-strong disabled:opacity-50"
							disabled={loadingMore}
							onClick={() => void loadMore(statusFilter)}
							data-testid="offering-load-more"
						>
							{loadingMore ? t("loadingMore") : t("loadMore")}
						</button>
					</div>
				) : null}
			</div>
		</section>
	);
}

function StatCard({
	label,
	value,
	danger = false,
}: {
	label: string;
	value: number | undefined;
	danger?: boolean;
}) {
	return (
		<div className="rounded-large border border-line bg-soft-2/40 p-3">
			<p className="text-[13px] text-ink-3">{label}</p>
			<p
				className={`mt-1 text-lg font-medium ${danger ? "text-red-300" : "text-ink"}`}
			>
				{value === undefined ? "…" : `¥${formatAmount(value)}`}
			</p>
		</div>
	);
}
