"use client";

/**
 * 高风险支付操作两段确认交互（R2 对齐：refundOrder / retryRefund / waivePayment）。
 *
 * 后端确认流（复用 Mcp.PendingOperation，确认摘要由后端生成）：
 * 1. `request(kind, id)` 第一段——建 pending（不落业务库）→ 打开确认弹层，
 *    弹层文案 = 后端返回的 summary（前端只透传，不自行拼操作内容）；
 * 2. 弹层确认 → `confirm()`（confirmOperation）真正执行 → 关弹层 + onCompleted
 *    刷新；取消 → `cancel()`（cancelOperation，后端标记 cancelled 不执行）。
 *
 * 消费方：payments-management / offering-payments-panel 两面板共用；面板只持有
 * 弹层 JSX（testid 前缀与 i18n 命名空间不同），状态机与 mutation 接线收敛于此。
 *
 * 已知取舍：弹层打开期间直接发起另一操作会覆盖 pendingOp——被覆盖的 pending
 * 失去确认入口，随 TTL（默认 10 分钟）自然过期，永不执行（无 confirm 不落库）。
 */

import { useState } from "react";
import { client } from "@/lib/apollo-client";
import {
	CANCEL_OPERATION,
	CONFIRM_OPERATION,
	REFUND_ORDER,
	RETRY_REFUND,
	WAIVE_PAYMENT,
	type PendingConfirmation,
} from "@/lib/graphql/orders";
import { usePaymentErrorTranslator } from "@/lib/payment-errors";

export type PaymentOperationKind = "refund" | "waive" | "retry";

export interface PendingPaymentOperation {
	kind: PaymentOperationKind;
	pendingId: string;
	/** 后端生成的确认摘要（弹层透传） */
	summary: string;
}

const REQUEST = {
	refund: { mutation: REFUND_ORDER, dataKey: "refundOrder", failureKey: "refundFailed" },
	waive: { mutation: WAIVE_PAYMENT, dataKey: "waivePayment", failureKey: "waiveFailed" },
	retry: { mutation: RETRY_REFUND, dataKey: "retryRefund", failureKey: "retryFailed" },
} as const;

export function usePaymentOperation({
	t,
	onCompleted,
}: {
	/** 面板命名空间翻译器（兜底文案键：refundFailed/waiveFailed/retryFailed/operationFailed/cancelFailed） */
	t: (key: string) => string;
	/** 确认执行成功后的刷新（列表/统计重拉） */
	onCompleted: () => Promise<void> | void;
}) {
	const translatePaymentError = usePaymentErrorTranslator();
	const [pendingOp, setPendingOp] = useState<PendingPaymentOperation | null>(null);
	const [busy, setBusy] = useState(false);
	const [actionError, setActionError] = useState<string | null>(null);

	/** 第一段：建 pending 开弹层；业务失败（状态/权限/不存在）进 actionError */
	async function request(kind: PaymentOperationKind, id: string) {
		if (busy) return;
		const { mutation, dataKey, failureKey } = REQUEST[kind];
		setBusy(true);
		setActionError(null);
		try {
			const { data } = await client.mutate({ mutation, variables: { id } });
			// 三 mutation 返回同形状 PendingConfirmation（TypedDocumentNode 泛型合并困难，窄化为结构形状）
			const payload = (data as Record<string, PendingConfirmation> | undefined)?.[dataKey];
			if (payload?.pendingId && payload.summary) {
				setPendingOp({ kind, pendingId: payload.pendingId, summary: payload.summary });
			} else {
				setActionError(translatePaymentError(payload?.errors?.[0]?.code, t(failureKey)));
			}
		} catch (e) {
			setActionError(
				translatePaymentError(e instanceof Error ? e.message : null, t(failureKey)),
			);
		} finally {
			setBusy(false);
		}
	}

	/** 第二段：确认执行；成功后关弹层并刷新（失败保留弹层，可重试或取消） */
	async function confirm() {
		if (!pendingOp || busy) return;
		setBusy(true);
		setActionError(null);
		try {
			const { data } = await client.mutate({
				mutation: CONFIRM_OPERATION,
				variables: { pendingId: pendingOp.pendingId },
			});
			const payload = data?.confirmOperation;
			if (payload?.status === "confirmed") {
				setPendingOp(null);
				// 刷新失败（网络等）不掩盖已成功的事实：面板 load 自带 listError 通道
				try {
					await onCompleted();
				} catch {
					/* 静默：下轮交互/手动刷新恢复 */
				}
			} else {
				setActionError(
					translatePaymentError(payload?.errors?.[0]?.code, t("operationFailed")),
				);
			}
		} catch (e) {
			setActionError(
				translatePaymentError(e instanceof Error ? e.message : null, t("operationFailed")),
			);
		} finally {
			setBusy(false);
		}
	}

	/** 第二段：取消。终态（已确认/已取消/已过期）一律关弹层——无 confirm 永不执行，
	 * 取消意图已满足；仅传输层失败保留弹层可重试（避免弹层卡死） */
	async function cancel() {
		if (!pendingOp || busy) return;
		setBusy(true);
		setActionError(null);
		try {
			const { data } = await client.mutate({
				mutation: CANCEL_OPERATION,
				variables: { pendingId: pendingOp.pendingId },
			});
			const payload = data?.cancelOperation;
			if (payload?.status !== "cancelled") {
				setActionError(
					translatePaymentError(payload?.errors?.[0]?.code, t("cancelFailed")),
				);
			}
			setPendingOp(null);
		} catch (e) {
			setActionError(
				translatePaymentError(e instanceof Error ? e.message : null, t("cancelFailed")),
			);
		} finally {
			setBusy(false);
		}
	}

	return { pendingOp, busy, actionError, request, confirm, cancel };
}
