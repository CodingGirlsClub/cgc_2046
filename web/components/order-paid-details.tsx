"use client";

/**
 * 支付成功明细（订单页 /orders/[id] 与收银弹框 paid 态共用同口径）：
 * 活动名 / 档位名 / 订单号小字两列（label + value）。
 *
 * 行按数据可得性渲染——无活动名上下文（sessionStorage 交接缺失）或旧单
 * 无快照时该行不渲染，不留空行。订单号超长中段省略展示（lib/payment
 * .truncateOutTradeNo），复制按钮复制全量原值（复制交互先例：
 * mcp-token-issue-panel「已复制」2s 复位）。
 */

import { useEffect, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { copyText } from "@/lib/clipboard";
import { truncateOutTradeNo } from "@/lib/payment";

export default function OrderPaidDetails({
	eventTitle = null,
	tierName = null,
	outTradeNo = null,
}: {
	/** 活动/课程名（无上下文则不渲染该行） */
	eventTitle?: string | null;
	/** 档位名（tierSnapshot 解析；旧单无快照则不渲染该行） */
	tierName?: string | null;
	/** 商户订单号（截断展示 + 复制全量） */
	outTradeNo?: string | null;
}) {
	const t = useTranslations("orders");
	const [copied, setCopied] = useState(false);
	// 「已复制」2s 复位定时器：连续复制重置计时；卸载时清理
	const copiedTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
	useEffect(() => {
		return () => {
			if (copiedTimerRef.current) clearTimeout(copiedTimerRef.current);
		};
	}, []);

	if (!eventTitle && !tierName && !outTradeNo) return null;

	return (
		<dl
			className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-[13px]"
			data-testid="order-paid-details"
		>
			{eventTitle ? (
				<>
					<dt className="text-ink-3">{t("paidEventLabel")}</dt>
					<dd className="text-ink" data-testid="order-paid-event">
						{eventTitle}
					</dd>
				</>
			) : null}
			{tierName ? (
				<>
					<dt className="text-ink-3">{t("paidTierLabel")}</dt>
					<dd className="text-ink" data-testid="order-paid-tier">
						{tierName}
					</dd>
				</>
			) : null}
			{outTradeNo ? (
				<>
					<dt className="text-ink-3">{t("paidOrderNoLabel")}</dt>
					<dd className="flex items-center gap-2 text-ink">
						<span className="font-mono" data-testid="order-paid-out-trade-no">
							{truncateOutTradeNo(outTradeNo)}
						</span>
						<button
							type="button"
							data-testid="order-paid-copy"
							className="rounded-large border border-line px-2 py-0.5 text-xs text-ink-3 hover:border-line-strong hover:text-ink"
							onClick={() => {
								void copyText(outTradeNo).then((ok) => {
									if (!ok) return;
									setCopied(true);
									if (copiedTimerRef.current) clearTimeout(copiedTimerRef.current);
									copiedTimerRef.current = setTimeout(() => setCopied(false), 2000);
								});
							}}
						>
							{copied ? t("copiedOrderNo") : t("copyOrderNo")}
						</button>
					</dd>
				</>
			) : null}
		</dl>
	);
}
