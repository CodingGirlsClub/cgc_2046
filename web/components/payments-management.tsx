"use client";

/**
 * 缴费管理面板（plan 024 U11/R15/R18/R24）。
 *
 * - 统计卡：workspacePaymentStats（JsonString，U10 决策 3——parsePaymentStats
 *   解析 snake_case int 键）；已收/待收/已退三分量。
 * - 订单列表：workspaceOrders（状态筛选 + tier/报名人信息计算字段）。
 * - 退款（R15）：paid 单 → refundOrder（确认弹窗，两步式同 participations
 *   取消报名先例）；refund_failed 单可再退（后端 start_refund 只吃 paid，此处
 *   v1 列出面只对 paid 提供入口）。
 * - 免缴（R18）：enrollmentStatus === payment_pending 的行 → waivePayment。
 * - 门控：manage = myAbilities 含 manage_members（Owner/Admin）；按钮渲染
 *   面门控 + 后端 policy 兜底（双保险）。
 *
 * 组件测试面：状态徽章、退款确认流、免缴按角色显隐（见 test）。
 */

import { useEffect, useRef, useState } from "react";
import { client } from "@/lib/apollo-client";
import {
	REFUND_ORDER,
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

const REFUND_CONFIRMATION =
	"将原路全额退款，报名同时取消并释放名额，此操作不可恢复。";

const STATUS_FILTERS: { value: string; label: string }[] = [
	{ value: "", label: "全部状态" },
	{ value: "pending", label: ORDER_STATUS_LABEL.pending },
	{ value: "paid", label: ORDER_STATUS_LABEL.paid },
	{ value: "refunding", label: ORDER_STATUS_LABEL.refunding },
	{ value: "refunded", label: ORDER_STATUS_LABEL.refunded },
	{ value: "refund_failed", label: ORDER_STATUS_LABEL.refund_failed },
	{ value: "cancelled", label: ORDER_STATUS_LABEL.cancelled },
	{ value: "expired", label: ORDER_STATUS_LABEL.expired },
];

const STATUS_BADGE_CLASS: Record<string, string> = {
	pending: "border-amber-400/40 text-amber-300",
	paid: "border-emerald-400/40 text-emerald-300",
	refunding: "border-sky-400/40 text-sky-300",
	refunded: "border-line text-ink-3",
	refund_failed: "border-red-400/40 text-red-300",
	cancelled: "border-line text-ink-3",
	expired: "border-line text-ink-3",
};

export function OrderStatusBadge({ status }: { status: string }) {
	return (
		<span
			data-testid={`order-badge-${status}`}
			className={`rounded-full border px-2.5 py-1 text-xs ${
				STATUS_BADGE_CLASS[status] ?? "border-line text-ink-3"
			}`}
		>
			{ORDER_STATUS_LABEL[status] ?? status}
		</span>
	);
}

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
	if (statsError) {
		return (
			<div
				className="rounded-large border border-line bg-card p-4 text-sm text-ink-3"
				data-testid="stats-error"
			>
				统计加载失败 ·{" "}
				<button type="button" className="underline" onClick={onRetryStats} data-testid="stats-retry">
					重试
				</button>
			</div>
		);
	}

	const cards = [
		{ label: "已收", cents: stats?.collectedCents ?? 0, testid: "stats-collected", danger: false },
		{ label: "待收", cents: stats?.pendingCents ?? 0, testid: "stats-pending", danger: false },
		{ label: "已退", cents: stats?.refundedCents ?? 0, testid: "stats-refunded", danger: false },
		{
			label: "退款失败待处理",
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

interface OrderRowActions {
	order: Order;
	manage: boolean;
	busy: boolean;
	onRequestRefund: (order: Order) => void;
	onWaive: (order: Order) => void;
}

function OrderRow({ order, manage, busy, onRequestRefund, onWaive }: OrderRowActions) {
	const canRefund = manage && order.status === "paid";
	const canWaive = manage && order.enrollmentStatus === "payment_pending";

	return (
		<tr data-testid={`order-row-${order.id}`} className="border-t border-line">
			<td className="px-3 py-2 text-[13px] text-ink-2">{order.learnerEmail ?? "—"}</td>
			<td className="px-3 py-2 text-[13px] text-ink-2">{order.tierName ?? "—"}</td>
			<td className="px-3 py-2 text-[13px] text-ink-2">¥{formatAmount(order.amountCents)}</td>
			<td className="px-3 py-2 text-[13px] text-ink-3">
				{PROVIDER_LABEL[order.provider] ?? order.provider}
			</td>
			<td className="px-3 py-2">
				<OrderStatusBadge status={order.status} />
			</td>
			<td className="px-3 py-2">
				<div className="flex flex-wrap gap-2">
					{canRefund ? (
						<button
							type="button"
							disabled={busy}
							onClick={() => onRequestRefund(order)}
							className="rounded-large border border-red-400/40 px-3 py-1 text-xs text-red-300 hover:border-red-400/70 disabled:opacity-50"
							data-testid={`refund-${order.id}`}
						>
							退款
						</button>
					) : null}
					{canWaive ? (
						<button
							type="button"
							disabled={busy}
							onClick={() => onWaive(order)}
							className="rounded-large border border-line-strong px-3 py-1 text-xs text-ink-2 hover:border-line disabled:opacity-50"
							data-testid={`waive-${order.id}`}
						>
							免缴
						</button>
					) : null}
				</div>
			</td>
		</tr>
	);
}

export default function PaymentsManagement({
	workspaceId,
	manage,
}: {
	workspaceId: string;
	manage: boolean;
}) {
	const [statusFilter, setStatusFilter] = useState("");
	const [orders, setOrders] = useState<Order[]>([]);
	const [stats, setStats] = useState<PaymentStats | null>(null);
	const [statsError, setStatsError] = useState(false);
	const [loadState, setLoadState] = useState<"loading" | "ok" | "error">("loading");
	const [busy, setBusy] = useState(false);
	const [refundTarget, setRefundTarget] = useState<Order | null>(null);
	const [actionError, setActionError] = useState<string | null>(null);

	async function load(filter: string) {
		setLoadState("loading");
		try {
			const { data } = await client.query({
				query: WORKSPACE_ORDERS,
				variables: {
					workspaceId,
					filter: filter ? { status: { eq: filter } } : null,
				},
			});
			setOrders(data?.workspaceOrders?.results ?? []);
			setLoadState("ok");
		} catch {
			setLoadState("error");
		}
	}

	async function loadStats() {
		setStatsError(false);
		try {
			const { data } = await client.query({
				query: WORKSPACE_PAYMENT_STATS,
				variables: { workspaceId },
			});
			setStats(parsePaymentStats(data?.workspacePaymentStats));
		} catch {
			setStats(null);
			setStatsError(true);
		}
	}

	// 初拉（workspaceId 变化时；ref 防串台）
	const loadedFor = useRef("");
	useEffect(() => {
		if (!workspaceId || loadedFor.current === workspaceId) return;
		loadedFor.current = workspaceId;
		void load(statusFilter);
		void loadStats();
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [workspaceId]);

	async function confirmRefund() {
		if (!refundTarget) return;
		setBusy(true);
		setActionError(null);
		try {
			const { data } = await client.mutate({
				mutation: REFUND_ORDER,
				variables: { id: refundTarget.id },
			});
			if (data?.refundOrder?.result) {
				setRefundTarget(null);
				await Promise.all([load(statusFilter), loadStats()]);
			} else {
				setActionError(data?.refundOrder?.errors?.[0]?.message ?? "退款发起失败");
			}
		} catch (e) {
			setActionError(e instanceof Error ? e.message : "退款发起失败");
		} finally {
			setBusy(false);
		}
	}

	async function waive(order: Order) {
		setBusy(true);
		setActionError(null);
		try {
			const { data } = await client.mutate({
				mutation: WAIVE_PAYMENT,
				variables: { id: order.enrollmentId },
			});
			if (data?.waivePayment?.result) {
				await Promise.all([load(statusFilter), loadStats()]);
			} else {
				setActionError(data?.waivePayment?.errors?.[0]?.message ?? "免缴失败");
			}
		} catch (e) {
			setActionError(e instanceof Error ? e.message : "免缴失败");
		} finally {
			setBusy(false);
		}
	}

	return (
		<div className="grid gap-4">
			<StatsCards stats={stats} statsError={statsError} onRetryStats={() => void loadStats()} />

			<div className="rounded-large border border-line bg-card p-4">
				<div className="flex flex-wrap items-center justify-between gap-3">
					<h2 className="text-sm font-medium text-ink">订单列表</h2>
					<label className="flex items-center gap-2 text-[13px] text-ink-3">
						状态筛选
						<select
							value={statusFilter}
							onChange={(e) => {
								setStatusFilter(e.target.value);
								void load(e.target.value);
							}}
							className="rounded-large border border-line bg-soft-2 px-2 py-1 text-sm text-ink"
							data-testid="status-filter"
						>
							{STATUS_FILTERS.map((f) => (
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
						aria-label="确认退款"
					>
						<p className="text-sm text-amber-200">
							{REFUND_CONFIRMATION}（¥{formatAmount(refundTarget.amountCents)}）
						</p>
						<div className="mt-3 flex flex-wrap gap-2">
							<button
								type="button"
								className="join-button join-button--primary"
								disabled={busy}
								onClick={() => void confirmRefund()}
								data-testid="refund-confirm"
							>
								{busy ? "退款中…" : "确认退款"}
							</button>
							<button
								type="button"
								className="join-button"
								disabled={busy}
								onClick={() => setRefundTarget(null)}
								data-testid="refund-cancel"
							>
								保留订单
							</button>
						</div>
					</div>
				) : null}

				{loadState === "loading" ? (
					<div className="mt-3 h-16 animate-pulse rounded-large bg-soft-2" />
				) : loadState === "error" ? (
					<p className="mt-3 text-sm text-ink-3" role="alert">
						订单加载失败，
						<button
							type="button"
							className="underline"
							onClick={() => void load(statusFilter)}
						>
							重试
						</button>
					</p>
				) : orders.length === 0 ? (
					<p className="mt-3 text-sm text-ink-3" data-testid="orders-empty">
						暂无订单。
					</p>
				) : (
					<div className="mt-3 overflow-x-auto">
						<table className="w-full min-w-[720px] text-left text-sm">
							<thead>
								<tr className="text-[13px] text-ink-3">
									<th className="px-3 py-2 font-normal">报名人</th>
									<th className="px-3 py-2 font-normal">档位</th>
									<th className="px-3 py-2 font-normal">金额</th>
									<th className="px-3 py-2 font-normal">渠道</th>
									<th className="px-3 py-2 font-normal">状态</th>
									<th className="px-3 py-2 font-normal">操作</th>
								</tr>
							</thead>
							<tbody>
								{orders.map((order) => (
									<OrderRow
										key={order.id}
										order={order}
										manage={manage}
										busy={busy}
										onRequestRefund={setRefundTarget}
										onWaive={(o) => void waive(o)}
									/>
								))}
							</tbody>
						</table>
					</div>
				)}
			</div>
		</div>
	);
}
