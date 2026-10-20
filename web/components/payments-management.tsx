"use client";

/**
 * 缴费管理面板（工作区级财务台账；plan 024 U11/R15/R18/R24）。
 *
 * - 统计卡：workspacePaymentStats（JsonString，U10 决策 3——parsePaymentStats
 *   解析 snake_case int 键）；已收/待收/已退/退款失败待处理/没收。
 * - 订单台账：OrderTable（共享组件）——报名人身份锚点、活动/课程列、下单
 *   时间、行内展开；取数与 keyset 分页收敛在 lib/use-workspace-orders。
 * - 操作资格：lib/order-actions 单源（退款 paid / 免缴 payment_pending /
 *   重试 refund_failed），与活动详情面板共用同一套判定。
 * - 门控：manage = myAbilities 含 manage_members（Owner/Admin）；按钮渲染
 *   面门控 + 后端 policy 兜底（双保险）。
 */

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
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
import { OFFERING_LABEL } from "@/lib/graphql/events";
import { fetchWorkspaceOfferings } from "@/lib/events";

/**
 * U2-R3：stats 加载失败呈现错误态（「统计加载失败 · 重试」），不再伪装 ¥0.00。
 * U1-R1：第四分量「退款失败待处理」（refund_failed 总额，非 0 时红色强调）。
 */
export function StatsCards({
	stats,
	statsError,
	onRetryStats,
}: {
	stats: PaymentStats | null;
	statsError: boolean;
	onRetryStats: () => void;
}) {
	const t = useTranslations("payments");
	if (statsError) {
		return (
			<div
				className="rounded-large border border-line bg-card p-4 text-sm text-ink-3"
				data-testid="stats-error"
			>
				{t("statsLoadFailed")}{" "}
				<button type="button" className="underline" onClick={onRetryStats} data-testid="stats-retry">
					{t("retry")}
				</button>
			</div>
		);
	}

	// 已收 = 仅 paid 合计：押金被判 no-show 后从「已收」消失但钱仍由平台持有，
	// 故单独列出没收桶（>0 才渲染，避免常挂空卡；KTD7/R9）
	const forfeitedCents = stats?.forfeitedCents ?? 0;

	const cards = [
		{ label: t("statCollected"), cents: stats?.collectedCents ?? 0, testid: "stats-collected", danger: false },
		...(forfeitedCents > 0
			? [
					{
						label: t("statForfeited"),
						cents: forfeitedCents,
						testid: "stats-forfeited",
						danger: false,
					},
				]
			: []),
		{ label: t("statPending"), cents: stats?.pendingCents ?? 0, testid: "stats-pending", danger: false },
		{ label: t("statRefunded"), cents: stats?.refundedCents ?? 0, testid: "stats-refunded", danger: false },
		{
			label: t("statRefundFailed"),
			cents: stats?.refundFailedCents ?? 0,
			testid: "stats-refund-failed",
			danger: true,
		},
	];

	return (
		<div className="grid gap-3 sm:grid-cols-4">
			{cards.map((c) => (
				<div key={c.label} className="rounded-large border border-line bg-card p-4" data-testid={c.testid}>
					<p className="text-[13px] text-ink-3">{c.label}</p>
					<p
						className={`mt-1 text-lg font-medium ${c.danger && c.cents > 0 ? "text-red-300" : "text-ink"}`}
					>
						¥{formatAmount(c.cents)}
					</p>
				</div>
			))}
		</div>
	);
}

export default function PaymentsManagement({
	workspaceId,
	manage,
}: {
	workspaceId: string;
	manage: boolean;
}) {
	const t = useTranslations("payments");
	const labelsT = useTranslations();
	const statusFilters = [
		{ value: "", label: t("filterDefault") },
		{ value: "all", label: t("filterAll") },
		...ORDER_STATUS_FILTER_VALUES.map((value) => ({
			value,
			label: labelsT(ORDER_STATUS_LABEL[value]),
		})),
	];
	const [statusFilter, setStatusFilter] = useState("");
	// U9/R8：活动筛选——订单列表与统计卡都按选中的活动/课程收敛
	const [offerings, setOfferings] = useState<
		Array<{ id: string; title: string; kind: "event" | "course" }>
	>([]);
	const [offeringFilter, setOfferingFilter] = useState("");
	const [stats, setStats] = useState<PaymentStats | null>(null);
	const [statsError, setStatsError] = useState(false);

	const selectedOffering = offerings.find((o) => o.id === offeringFilter);

	// 统计口径跟随活动/课程筛选（stats query 自带 eventId/courseId）；
	// 「全部活动与课程」时保持工作区全量口径
	const statsVariables = useMemo(
		() => ({
			workspaceId,
			...(selectedOffering?.kind === "event" ? { eventId: selectedOffering.id } : {}),
			...(selectedOffering?.kind === "course" ? { courseId: selectedOffering.id } : {}),
		}),
		[workspaceId, selectedOffering?.id, selectedOffering?.kind],
	);

	const loadStats = useCallback(async () => {
		if (!workspaceId) return;

		setStatsError(false);
		try {
			const { data } = await client.query({
				query: WORKSPACE_PAYMENT_STATS,
				variables: statsVariables,
			});
			setStats(parsePaymentStats(data?.workspacePaymentStats));
		} catch {
			setStats(null);
			setStatsError(true);
		}
	}, [workspaceId, statsVariables]);

	// 默认口径与活动详情面板一致：非终态 + 已退款 + 已没收；
	// "all" 是显式的全部状态（含 cancelled/expired）
	const effectiveStatus = statusFilter === "all" ? undefined : statusFilter;
	const defaultStatuses = statusFilter === "all" ? [] : DEFAULT_VISIBLE_STATUSES;

	const { orders, loadState, hasMore, loadingMore, reload, loadMore } = useWorkspaceOrders({
		workspaceId,
		status: effectiveStatus,
		eventId: selectedOffering?.kind === "event" ? selectedOffering.id : undefined,
		courseId: selectedOffering?.kind === "course" ? selectedOffering.id : undefined,
		defaultStatuses,
	});

	// 退款/免缴/重试两段确认：pendingOp（待确认弹层）+ busy + actionError 全在 hook
	const { pendingOp, busy, actionError, request, confirm, cancel } = usePaymentOperation({
		t,
		onCompleted: () => Promise.all([reload(), loadStats()]).then(() => undefined),
	});

	const loadedFor = useRef("");
	useEffect(() => {
		if (!workspaceId || loadedFor.current === workspaceId) return;
		loadedFor.current = workspaceId;
		void Promise.all([
			fetchWorkspaceOfferings(workspaceId, "event"),
			fetchWorkspaceOfferings(workspaceId, "course"),
		]).then(([events, courses]) => {
			setOfferings([
				...events.map((e) => ({ id: e.id, title: e.title, kind: "event" as const })),
				...courses.map((c) => ({ id: c.id, title: c.title, kind: "course" as const })),
			]);
		}).catch(() => {
			// 筛选器选项拉取失败只影响下拉内容；订单列表仍可用
			setOfferings([]);
		});
	}, [workspaceId]);

	// 统计跟随筛选：选中活动/课程即换口径（loadStats 的依赖已含筛选）
	useEffect(() => {
		void loadStats();
	}, [loadStats]);

	const eventOfferings = offerings.filter((o) => o.kind === "event");
	const courseOfferings = offerings.filter((o) => o.kind === "course");

	return (
		<div className="grid gap-4">
			<p className="text-[13px] text-ink-3" data-testid="stats-scope">
				{selectedOffering
					? t("statsScopeOffering", { title: selectedOffering.title })
					: t("statsScopeAll")}
			</p>
			<StatsCards stats={stats} statsError={statsError} onRetryStats={() => void loadStats()} />

			<div className="rounded-large border border-line bg-card p-4">
				<div className="flex flex-wrap items-center justify-between gap-3">
					<h2 className="text-sm font-medium text-ink">{t("listTitle")}</h2>
					<div className="flex flex-wrap items-center gap-3">
						<label className="flex items-center gap-2 text-[13px] text-ink-3">
							{t("filterOffering")}
							<select
								value={offeringFilter}
								onChange={(e) => setOfferingFilter(e.target.value)}
								className="ui-select ui-select--sm"
								data-testid="offering-filter"
							>
								<option value="">{t("filterOfferingAll")}</option>
								{eventOfferings.length > 0 ? (
									<optgroup label={labelsT(OFFERING_LABEL.event)}>
										{eventOfferings.map((o) => (
											<option key={o.id} value={o.id}>
												{o.title}
											</option>
										))}
									</optgroup>
								) : null}
								{courseOfferings.length > 0 ? (
									<optgroup label={labelsT(OFFERING_LABEL.course)}>
										{courseOfferings.map((o) => (
											<option key={o.id} value={o.id}>
												{o.title}
											</option>
										))}
									</optgroup>
								) : null}
							</select>
						</label>
						<label className="flex items-center gap-2 text-[13px] text-ink-3">
							{t("filterLabel")}
							<select
								value={statusFilter}
								onChange={(e) => setStatusFilter(e.target.value)}
								className="ui-select ui-select--sm"
								data-testid="status-filter"
							>
								{statusFilters.map((f) => (
									<option key={f.value} value={f.value}>
										{f.label}
									</option>
								))}
							</select>
						</label>
					</div>
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
						<p className="text-sm text-amber-200" data-testid="op-summary">
							{pendingOp.summary}
						</p>
						<div className="mt-3 flex flex-wrap gap-2">
							<button
								type="button"
								className="join-button join-button--primary"
								disabled={busy}
								onClick={() => void confirm()}
								data-testid="op-confirm"
							>
								{busy ? t("confirmBusy") : t("confirmExecute")}
							</button>
							<button
								type="button"
								className="join-button"
								disabled={busy}
								onClick={() => void cancel()}
								data-testid="op-cancel"
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
					<p className="mt-3 text-sm text-ink-3" data-testid="orders-empty">
						{t("emptyOrders")}
					</p>
				) : (
					<div className="mt-3">
						<OrderTable
							orders={orders}
							manage={manage}
							busy={busy}
							onRequest={(kind, id) => void request(kind, id)}
							showOffering
						/>
						{hasMore ? (
							<div className="mt-3 flex justify-center">
								<button
									type="button"
									className="rounded-large border border-line px-4 py-2 text-sm text-ink-2 hover:border-line-strong disabled:opacity-50"
									disabled={loadingMore}
									onClick={() => void loadMore()}
									data-testid="load-more"
								>
									{loadingMore ? t("loadingMore") : t("loadMore")}
								</button>
							</div>
						) : null}
					</div>
				)}
			</div>
		</div>
	);
}
