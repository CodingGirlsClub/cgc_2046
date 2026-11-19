"use client";

/**
 * LLM 算力收银台二维码支付与轮询面板（工作台算力池充值 & 个人钱包订阅/算力包共用）。
 *
 * - 复用 `lib/payment.ts` 的 `dispatchCredential` 解析渠道凭据（wechat_native / alipay_qr 均为 qr_code）
 * - 通过 `qrcode` 生成 data URL 展示二维码
 * - 通过 `useOrderPolling` 轮询 `llmPaymentOrder` 直至终态（paid / expired / cancelled），
 *   并在卸载或状态进入终态时自动清理定时器与事件监听
 */

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import QRCode from "qrcode";
import { client } from "@/lib/apollo-client";
import {
	LLM_PAYMENT_ORDER,
	type LlmPaymentCheckoutOrder,
	type LlmPaymentOrder,
	type LlmPaymentProvider,
} from "@/lib/graphql/llm-gateway";
import { formatMcAsCny } from "@/lib/llm-credits";
import {
	CREDENTIAL_REASON_LABEL,
	PROVIDER_LABEL,
	dispatchCredential,
	formatAmount,
	httpsRedirectOrFallback,
	type OrderPollStatus,
} from "@/lib/payment";
import { useOrderPolling } from "@/lib/use-order-polling";

export interface LlmQrCheckoutProps {
	order: LlmPaymentCheckoutOrder;
	provider: LlmPaymentProvider;
	credential: unknown;
	onPaid?: (order: LlmPaymentOrder) => void;
	onReset?: () => void;
}

const VALID_POLL_STATUSES = new Set<OrderPollStatus>([
	"pending",
	"paid",
	"cancelled",
	"expired",
]);

function toPollStatus(raw: string): OrderPollStatus {
	return VALID_POLL_STATUSES.has(raw as OrderPollStatus)
		? (raw as OrderPollStatus)
		: "pending";
}

export default function LlmQrCheckout({
	order,
	provider,
	credential,
	onPaid,
	onReset,
}: LlmQrCheckoutProps) {
	const t = useTranslations("llmCheckout");
	const labelsT = useTranslations();

	const [polledOrder, setPolledOrder] = useState<LlmPaymentOrder | null>(null);
	const [qrState, setQrState] = useState<{
		url: string;
		dataUrl: string | null;
		failed: boolean;
	} | null>(null);
	const paidNotifiedOrderIdRef = useRef<string | null>(null);
	const mountedRef = useRef(true);

	useEffect(() => {
		mountedRef.current = true;
		return () => {
			mountedRef.current = false;
		};
	}, []);

	const activePolled =
		polledOrder && polledOrder.id === order.id ? polledOrder : null;
	const currentStatus = activePolled?.status ?? order.status;
	const pollStatus = toPollStatus(currentStatus);
	const isPending = pollStatus === "pending";
	const isPaid = pollStatus === "paid";

	const dispatch = useMemo(() => dispatchCredential(credential), [credential]);

	useEffect(() => {
		if (dispatch.mode !== "qr" || !isPending) return;
		const targetUrl = dispatch.url;
		let cancelled = false;

		QRCode.toDataURL(targetUrl, { width: 220, margin: 1 })
			.then((dataUrl) => {
				if (!cancelled && mountedRef.current) {
					setQrState({ url: targetUrl, dataUrl, failed: false });
				}
			})
			.catch(() => {
				if (!cancelled && mountedRef.current) {
					setQrState({ url: targetUrl, dataUrl: null, failed: true });
				}
			});

		return () => {
			cancelled = true;
		};
	}, [dispatch, isPending]);

	const fetchOrderStatus = useCallback(async () => {
		try {
			const { data } = await client.query({
				query: LLM_PAYMENT_ORDER,
				variables: { id: order.id },
				fetchPolicy: "network-only",
			});
			const fresh = data?.llmPaymentOrder;
			if (!fresh || fresh.id !== order.id || !mountedRef.current) return;
			setPolledOrder(fresh);
			if (fresh.status === "paid" && paidNotifiedOrderIdRef.current !== fresh.id) {
				paidNotifiedOrderIdRef.current = fresh.id;
				onPaid?.(fresh);
			}
		} catch {
			// 轮询瞬态网络抖动静默重试，不中断当前二维码展示
		}
	}, [order.id, onPaid]);

	useOrderPolling({
		enabled: isPending,
		status: pollStatus,
		onTick: fetchOrderStatus,
	});

	useEffect(() => {
		if (!isPending) return;
		const resync = () => {
			if (document.visibilityState === "visible") {
				void fetchOrderStatus();
			}
		};
		window.addEventListener("focus", resync);
		document.addEventListener("visibilitychange", resync);
		return () => {
			window.removeEventListener("focus", resync);
			document.removeEventListener("visibilitychange", resync);
		};
	}, [isPending, fetchOrderStatus]);

	const providerLabel = PROVIDER_LABEL[provider]
		? labelsT(PROVIDER_LABEL[provider])
		: provider;
	const isAlipay = provider === "alipay_qr";
	const qrDataUrl =
		dispatch.mode === "qr" && qrState?.url === dispatch.url
			? qrState.dataUrl
			: null;
	const qrFailed =
		dispatch.mode === "qr" && qrState?.url === dispatch.url && qrState.failed;

	return (
		<div
			className="admin-card admin-card__body"
			data-testid="llm-qr-checkout"
		>
			<div className="flex flex-wrap items-start justify-between gap-3">
				<div>
					<p className="text-sm font-medium text-ink">
						{providerLabel} · ¥{formatAmount(order.amountCents)}
					</p>
					<p className="mt-1 text-xs text-ink-3">
						{t("creditsPreview", { amount: formatMcAsCny(order.creditsMc) })}
					</p>
					<p className="mt-1 font-mono text-xs text-ink-3">
						{t("orderNo", { outTradeNo: order.outTradeNo })}
					</p>
				</div>
				<span
					data-testid="llm-qr-status"
					className={`l-badge ${
						isPaid
							? "l-badge-success"
							: isPending
								? "l-badge-pending"
								: "l-badge-muted"
					}`}
				>
					{isPaid
						? t("statusPaid")
						: currentStatus === "expired"
							? t("statusExpired")
							: currentStatus === "cancelled"
								? t("statusCancelled")
								: t("statusPending")}
				</span>
			</div>

			{isPaid ? (
				<div className="rounded-medium border border-line bg-soft-2 p-3 text-sm text-ink">
					<p role="status" data-testid="llm-qr-paid-banner">
						{t("paidSuccess", { amount: formatMcAsCny(order.creditsMc) })}
					</p>
				</div>
			) : !isPending ? (
				<p className="text-sm text-ink-3" data-testid="llm-qr-terminal-note">
					{t("orderClosedNote")}
				</p>
			) : dispatch.mode === "qr" ? (
				<div className="grid justify-items-center gap-3 py-2">
					{qrDataUrl ? (
						// eslint-disable-next-line @next/next/no-img-element
						<img
							src={qrDataUrl}
							alt={isAlipay ? t("alipayQrAlt") : t("wechatQrAlt")}
							width={220}
							height={220}
							data-testid="llm-qr-image"
							className="rounded-large border border-line bg-white p-2"
						/>
					) : (
						<div className="grid h-[220px] w-[220px] place-items-center rounded-large border border-line bg-soft-2 px-4 text-center text-xs text-ink-3">
							{qrFailed ? t("qrFailed") : t("qrGenerating")}
						</div>
					)}
					<p className="text-xs text-ink-3">
						{isAlipay ? t("scanAlipay") : t("scanWechat")}
					</p>
					<p className="text-xs text-ink-3" data-testid="llm-qr-polling">
						{t("pollingHint")}
					</p>
				</div>
			) : dispatch.mode === "redirect" ? (
				<div className="grid gap-2">
					<a
						href={httpsRedirectOrFallback(dispatch.url, "#")}
						target="_blank"
						rel="noreferrer"
						className="l-btn-primary inline-flex justify-center"
					>
						{t("openCheckoutLink")}
					</a>
					<p className="text-xs text-ink-3">{t("pollingHint")}</p>
				</div>
			) : (
				<p className="text-xs text-ink-3" data-testid="llm-qr-unsupported">
					{labelsT(CREDENTIAL_REASON_LABEL[dispatch.reason])}
				</p>
			)}

			<div className="flex flex-wrap items-center gap-2 pt-1">
				{isPending && (
					<button
						type="button"
						onClick={() => void fetchOrderStatus()}
						className="l-btn-outline"
					>
						{t("refreshStatus")}
					</button>
				)}
				{onReset && (
					<button type="button" onClick={onReset} className="l-btn-ghost">
						{isPaid ? t("done") : t("cancelOrderView")}
					</button>
				)}
			</div>
		</div>
	);
}
