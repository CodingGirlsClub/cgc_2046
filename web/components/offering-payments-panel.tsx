"use client";

/**
 * 活动经营面：本活动的钱一屏可见可操作（organizer-payment U7，R3/R5/R6/R7）。
 *
 * - 自包含面板（KTD1，先例 sponsorship-management）：自取数、自带测试文件，
 *   插入 OfferingDetailPage 的全宽面板栈；manage（canManageEvents）门控渲染
 *   （AE6），非 manage 不渲染（也不发订单查询）。
 * - 收费状态（R3）：免费态收敛为一行免费状态（不拉订单查询，AE4）。
 * - 四数统计（R5）：带 offering 参数的 workspacePaymentStats（与工作区口径
 *   同源，KTD3）。
 * - 订单台账（R6）：OrderTable 共享组件（报名人身份锚点 / 下单时间 / 行内
 *   展开）；取数与 keyset 分页收敛在 lib/use-workspace-orders。
 * - 行内操作资格：lib/order-actions 单源（退款 paid / 免缴 payment_pending /
 *   重试 refund_failed）——免缴判定看报名状态而非订单状态，与后端 CAS 前提
 *   一致（订单 pending ≠ 报名 payment_pending）。
 */

import { useEffect, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { client } from "@/lib/apollo-client";
import { WORKSPACE_PAYMENT_STATS } from "@/lib/graphql/orders";
import {
	ORDER_STATUS_FILTER_VALUES,
	ORDER_STATUS_LABEL,
	formatAmount,
	parsePaymentStats,
	type PaymentStats,
} from "@/lib/payment";
import { usePaymentOperation } from "@/lib/use-payment-operation";
import { useWorkspaceOrders, DEFAULT_VISIBLE_STATUSES } from "@/lib/use-workspace-orders";
import { OrderTable } from "@/components/order-table";

export default function OfferingPaymentsPanel({
	workspaceId,
	offeringId,
	kind,
	manage,
	pricingEnabled,
	depositEnabled = false,
}: {
	workspaceId: string;
	offeringId: string;
	kind: "event" | "course";
	manage: boolean;
	pricingEnabled: boolean;
	/** 押金场（pricingEnabled=false 但有收款面）：免费态收敛必须同时排除押金 */
	depositEnabled?: boolean;
}) {
	const t = useTranslations("offeringPayments");
	const labelsT = useTranslations();

	const [statusFilter, setStatusFilter] = useState("");
	const [stats, setStats] = useState<PaymentStats | null>(null);
	const [statsError, setStatsError] = useState(false);

	// 与工作区页统一口径："" = 默认（非终态 + 已退款 + 已没收）；"all" = 全部状态
	const effectiveStatus = statusFilter === "all" ? undefined : statusFilter;
	const defaultStatuses = statusFilter === "all" ? [] : DEFAULT_VISIBLE_STATUSES;

	const { orders, loadState, hasMore, loadingMore, reload, loadMore } = useWorkspaceOrders({
		workspaceId,
		enabled: manage,
		status: effectiveStatus,
		eventId: kind === "event" ? offeringId : undefined,
		courseId: kind === "course" ? offeringId : undefined,
		defaultStatuses,
	});

	// 退款/免缴/重试两段确认：pendingOp（待确认弹层）+ busy + actionError 全在 hook
	const { pendingOp, busy, actionError, request, confirm, cancel } = usePaymentOperation({
		t,
		onCompleted: () => Promise.all([reload(), loadStats()]).then(() => undefined),
	});

	async function loadStats() {
		if (!manage) return;

		setStatsError(false);
		try {
			const panelKey = kind === "event" ? "eventId" : "courseId";
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

	// 初拉统计（offering 维度变化时；ref 防串台）
	const loadedFor = useRef("");
	useEffect(() => {
		if (!manage) return;
		const key = `${workspaceId}:${offeringId}`;
		if (loadedFor.current === key) return;
		loadedFor.current = key;
		void loadStats();
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [workspaceId, offeringId, manage]);

	if (!manage) return null;

	// F13：免费态且无任何订单/统计负担 → 收敛一行；有已付历史则完整面板
	if (
		!pricingEnabled &&
		!depositEnabled &&
		orders.length === 0 &&
		!statsError &&
		(stats?.collectedCents ?? 0) === 0
	) {
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

	const statusFilters = [
		{ value: "", label: t("filterDefault") },
		{ value: "all", label: t("filterAll") },
		...ORDER_STATUS_FILTER_VALUES.map((value) => ({
			value,
			label: labelsT(ORDER_STATUS_LABEL[value]),
		})),
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
						{(stats?.forfeitedCents ?? 0) > 0 ? (
							<StatCard label={t("statForfeited")} value={stats?.forfeitedCents} />
						) : null}
						<StatCard label={t("statPending")} value={stats?.pendingCents} />
						<StatCard label={t("statRefunded")} value={stats?.refundedCents} />
						<StatCard
							label={t("statRefundFailed")}
							value={stats?.refundFailedCents}
							danger={stats?.refundFailedCents ? stats.refundFailedCents > 0 : false}
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
							onChange={(e) => setStatusFilter(e.target.value)}
							className="ui-select ui-select--sm"
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

				{pendingOp ? (
					<div
						className="mt-3 rounded-large border border-amber-400/30 bg-amber-500/10 p-3"
						role="group"
						aria-label={t("confirmTitle")}
					>
						{/* 摘要由后端生成（含金额/渠道/后果），前端只透传 */}
						<p className="text-sm text-amber-200" data-testid="offering-op-summary">
							{pendingOp.summary}
						</p>
						<div className="mt-3 flex flex-wrap gap-2">
							<button
								type="button"
								className="join-button join-button--primary"
								disabled={busy}
								onClick={() => void confirm()}
								data-testid="offering-op-confirm"
							>
								{busy ? t("confirmBusy") : t("confirmExecute")}
							</button>
							<button
								type="button"
								className="join-button"
								disabled={busy}
								onClick={() => void cancel()}
								data-testid="offering-op-cancel"
							>
								{t("confirmCancel")}
							</button>
						</div>
					</div>
				) : null}

				{loadState === "loading" ? (
					<div className="mt-3 h-16 animate-pulse rounded-large bg-soft-2" />
				) : loadState === "error" ? (
					<p className="mt-3 text-sm text-ink-3" role="alert">
						{t("loadFailed")}
						<button type="button" className="underline" onClick={() => void reload()}>
							{t("retry")}
						</button>
					</p>
				) : orders.length === 0 ? (
					<p className="mt-3 text-sm text-ink-3" data-testid="offering-orders-empty">
						{t("emptyOrders")}
					</p>
				) : (
					<div className="mt-3">
						<OrderTable
							orders={orders}
							manage={manage}
							busy={busy}
							onRequest={(op, id) => void request(op, id)}
							testIdPrefix="offering"
						/>
						{hasMore ? (
							<div className="mt-3 flex justify-center">
								<button
									type="button"
									className="rounded-large border border-line px-4 py-2 text-sm text-ink-2 hover:border-line-strong disabled:opacity-50"
									disabled={loadingMore}
									onClick={() => void loadMore()}
									data-testid="offering-load-more"
								>
									{loadingMore ? t("loadingMore") : t("loadMore")}
								</button>
							</div>
						) : null}
					</div>
				)}
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
