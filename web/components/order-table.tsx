"use client";

/**
 * 管理面订单表格（工作区缴费页与活动/课程详情面板共用）。
 *
 * - 列：展开 · 报名人 ·（活动/课程）· 档位 · 金额 · 渠道 · 状态 · 下单时间 · 操作
 * - 报名人身份锚点 = 掩码手机 → 邮箱兜底（决策 1a/2c）；会员号恒有，展示名
 *   只是可选附加，不参与「能否识别」。
 * - 操作资格单源 = lib/order-actions（镜像后端 precondition），不得在 JSX 内
 *   自行比较状态。
 * - 展开行只读：订单号/交易号/时间线/押金同意留痕；操作仍只在行内，避免同一
 *   动作两个入口。
 */

import { Fragment, useState } from "react";
import { useTranslations } from "next-intl";
import type { Order } from "@/lib/graphql/orders";
import { ORDER_STATUS_LABEL, PROVIDER_LABEL, formatAmount } from "@/lib/payment";
import { formatDateTime } from "@/lib/format";
import { ENROLLMENT_STATUS_LABEL } from "@/lib/graphql/participations";
import { OFFERING_LABEL } from "@/lib/graphql/events";
import { orderActions } from "@/lib/order-actions";
import type { PaymentOperationKind } from "@/lib/use-payment-operation";

const STATUS_BADGE_CLASS: Record<string, string> = {
	pending: "border-amber-400/40 text-amber-300",
	paid: "border-emerald-400/40 text-emerald-300",
	refunding: "border-sky-400/40 text-sky-300",
	refunded: "border-line text-ink-3",
	refund_failed: "border-red-400/40 text-red-300",
	cancelled: "border-line text-ink-3",
	expired: "border-line text-ink-3",
	forfeited: "border-line text-ink-3",
};

export function OrderStatusBadge({ status }: { status: string }) {
	const labelsT = useTranslations();

	return (
		<span
			data-testid={`order-badge-${status}`}
			className={`rounded-full border px-2.5 py-1 text-xs ${
				STATUS_BADGE_CLASS[status] ?? "border-line text-ink-3"
			}`}
		>
			{labelsT(ORDER_STATUS_LABEL[status] ?? status)}
		</span>
	);
}

/** 报名人：手机掩码优先、邮箱兜底；副行固定会员号（+ 可选展示名） */
export function EnrolleeCell({ order }: { order: Order }) {
	const primary = order.learnerPhoneMasked ?? order.learnerEmail ?? "—";
	const secondary = [order.learnerMemberNumber, order.learnerName].filter(Boolean).join(" · ");

	return (
		<div className="min-w-[140px]">
			<p className="text-ink">{primary}</p>
			{secondary ? <p className="mt-0.5 text-xs text-ink-3">{secondary}</p> : null}
		</div>
	);
}

function DetailItem({ label, value }: { label: string; value: string }) {
	return (
		<div className="flex gap-2">
			<dt className="shrink-0 text-ink-3">{label}</dt>
			<dd className="text-ink-2">{value}</dd>
		</div>
	);
}

export interface OrderTableProps {
	orders: Order[];
	manage: boolean;
	busy: boolean;
	onRequest: (kind: PaymentOperationKind, id: string) => void;
	/** 工作区视图显示「活动/课程」列；详情面板已知活动，不重复 */
	showOffering?: boolean;
	/** testid 前缀：工作区 ""，详情 "offering"（沿用既有测试钩子） */
	testIdPrefix?: string;
}

export function OrderTable({
	orders,
	manage,
	busy,
	onRequest,
	showOffering = false,
	testIdPrefix = "",
}: OrderTableProps) {
	const t = useTranslations("payments");
	const labelsT = useTranslations();
	const [expandedId, setExpandedId] = useState<string | null>(null);

	const tid = (action: string, id: string) =>
		testIdPrefix ? `${testIdPrefix}-${action}-${id}` : `${action}-${id}`;

	const columnCount = showOffering ? 9 : 8;

	return (
		<div className="overflow-x-auto">
			<table className="w-full min-w-[880px] text-left text-sm">
				<thead>
					<tr className="text-[13px] text-ink-3">
						<th className="w-8 px-2 py-2 font-normal" aria-label={t("detailToggleAria")} />
						<th className="px-3 py-2 font-normal">{t("thEnrollee")}</th>
						{showOffering ? <th className="px-3 py-2 font-normal">{t("thOffering")}</th> : null}
						<th className="px-3 py-2 font-normal">{t("thTier")}</th>
						<th className="px-3 py-2 font-normal">{t("thAmount")}</th>
						<th className="px-3 py-2 font-normal">{t("thChannel")}</th>
						<th className="px-3 py-2 font-normal">{t("thStatus")}</th>
						<th className="px-3 py-2 font-normal">{t("thCreatedAt")}</th>
						<th className="px-3 py-2 font-normal">{t("thActions")}</th>
					</tr>
				</thead>
				<tbody>
					{orders.map((order) => {
						const actions = orderActions(order);
						const expanded = expandedId === order.id;
						const enrollmentStatus = order.enrollmentStatus
							? labelsT(
									(ENROLLMENT_STATUS_LABEL as Record<string, string>)[
										order.enrollmentStatus
									] ?? order.enrollmentStatus,
								)
							: "—";

						return (
							<Fragment key={order.id}>
								<tr className="border-t border-line" data-testid={`order-row-${order.id}`}>
									<td className="px-2 py-2 align-top">
										<button
											type="button"
											aria-expanded={expanded}
											aria-label={expanded ? t("detailCollapse") : t("detailExpand")}
											onClick={() => setExpandedId(expanded ? null : order.id)}
											className="rounded border border-line px-1.5 py-0.5 text-xs text-ink-3 hover:border-line-strong"
											data-testid={tid("detail", order.id)}
										>
											{expanded ? "▾" : "▸"}
										</button>
									</td>
									<td className="px-3 py-2 align-top">
										<EnrolleeCell order={order} />
									</td>
									{showOffering ? (
										<td className="px-3 py-2 align-top text-ink-2">
											<span className="block">{order.offeringTitle ?? "—"}</span>
											<span className="mt-0.5 block text-xs text-ink-3">
												{order.offeringKind
													? labelsT(
															(OFFERING_LABEL as Record<string, string>)[
																order.offeringKind
															] ?? order.offeringKind,
														)
													: "—"}
											</span>
										</td>
									) : null}
									<td className="px-3 py-2 align-top text-ink-2">{order.tierName ?? "—"}</td>
									<td className="px-3 py-2 align-top text-ink">
										¥{formatAmount(order.amountCents)}
									</td>
									<td className="px-3 py-2 align-top text-ink-3">
										{labelsT(PROVIDER_LABEL[order.provider] ?? order.provider)}
									</td>
									<td className="px-3 py-2 align-top">
										<OrderStatusBadge status={order.status} />
									</td>
									<td className="px-3 py-2 align-top text-[13px] text-ink-2">
										{formatDateTime(order.insertedAt)}
									</td>
									<td className="px-3 py-2 align-top">
										<div className="flex flex-wrap gap-2">
											{manage && actions.refund ? (
												<button
													type="button"
													disabled={busy}
													onClick={() => onRequest("refund", order.id)}
													className="rounded-large border border-red-400/40 px-3 py-1 text-xs text-red-300 hover:border-red-400/70 disabled:opacity-50"
													data-testid={tid("refund", order.id)}
												>
													{t("refund")}
												</button>
											) : null}
											{manage && actions.waive ? (
												<button
													type="button"
													disabled={busy}
													onClick={() => onRequest("waive", order.enrollmentId)}
													className="rounded-large border border-line-strong px-3 py-1 text-xs text-ink-2 hover:border-line disabled:opacity-50"
													data-testid={tid("waive", order.id)}
												>
													{t("waive")}
												</button>
											) : null}
											{manage && actions.retry ? (
												<button
													type="button"
													disabled={busy}
													onClick={() => onRequest("retry", order.id)}
													className="rounded-large border border-red-400/40 px-3 py-1 text-xs text-red-300 hover:border-red-400/70 disabled:opacity-50"
													data-testid={tid("retry", order.id)}
												>
													{t("retryRefund")}
												</button>
											) : null}
										</div>
									</td>
								</tr>
								{expanded ? (
									<tr
										className="border-t border-line bg-soft-2/30"
										data-testid={tid("detail-row", order.id)}
									>
										<td colSpan={columnCount} className="px-3 py-3">
											<div className="grid gap-4 sm:grid-cols-2">
												<div>
													<p className="text-[13px] font-medium text-ink-2">
														{t("detailOrderTitle")}
													</p>
													<dl className="mt-2 grid gap-1 text-[13px]">
														<DetailItem
															label={t("detailInsertedAt")}
															value={formatDateTime(order.insertedAt)}
														/>
														<DetailItem label={t("detailOutTradeNo")} value={order.outTradeNo} />
														<DetailItem
															label={t("detailTransactionId")}
															value={order.transactionId ?? "—"}
														/>
														<DetailItem
															label={t("detailExpireAt")}
															value={formatDateTime(order.expireAt)}
														/>
														<DetailItem
															label={t("detailRefundedAt")}
															value={formatDateTime(order.refundedAt)}
														/>
														<DetailItem
															label={t("detailCancelReason")}
															value={order.cancelReason ?? "—"}
														/>
														{order.depositConsentAt ? (
															<DetailItem
																label={t("detailDepositConsentAt")}
																value={formatDateTime(order.depositConsentAt)}
															/>
														) : null}
														{order.depositTermsVersion ? (
															<DetailItem
																label={t("detailDepositTermsVersion")}
																value={order.depositTermsVersion}
															/>
														) : null}
													</dl>
												</div>
												<div>
													<p className="text-[13px] font-medium text-ink-2">
														{t("detailEnrollmentTitle")}
													</p>
													<dl className="mt-2 grid gap-1 text-[13px]">
														<DetailItem
															label={t("detailEnrollmentInsertedAt")}
															value={formatDateTime(order.enrollmentInsertedAt)}
														/>
														<DetailItem
															label={t("detailEnrollmentStatus")}
															value={enrollmentStatus}
														/>
														{showOffering ? null : (
															<DetailItem
																label={t("thOffering")}
																value={order.offeringTitle ?? "—"}
															/>
														)}
													</dl>
												</div>
											</div>
										</td>
									</tr>
								) : null}
							</Fragment>
						);
					})}
				</tbody>
			</table>
		</div>
	);
}
