"use client";

/**
 * 缴费闭环 U11/KTD10：订单页 /orders/[id]。
 *
 * - 凭据分派（R13）：wechat_native → 二维码渲染（qrcode dataURL）；alipay
 *   page/wap → 支付宝跳转链接（web 端不用 window 自动跳转——弹转按钮，防
 *   弹窗拦截与误触）；jsapi → 引导小程序。
 * - 轮询（R14）：orderStatus 2s×30s（lib/payment.nextPollTick 决策），paid →
 *   成功态 + 回跳入口；超窗转手动刷新态。
 * - 倒计时（R6）：expire_at 每 500ms 刷新；过期态提示。
 * - 换渠道（R11）：replaceProvider（旧单 cancelled + 新单新凭据，本页就地刷新）。
 *
 * 组件测试面：倒计时渲染/过期态与轮询编排断言（见 page.test.tsx）。
 */

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { useParams } from "next/navigation";
import QRCode from "qrcode";
import { client } from "@/lib/apollo-client";
import {
	ORDER_STATUS,
	REPLACE_PROVIDER,
	type Order,
	type PaymentProvider,
} from "@/lib/graphql/orders";
import { useAuthed } from "@/lib/use-authed";
import {
	POLL_TOTAL_MS,
	PROVIDER_LABEL,
	WEB_ENABLED_PROVIDERS,
	countdownText,
	dispatchCredential,
	formatAmount,
	nextPollTick,
	type CredentialDispatch,
	type OrderPollStatus,
} from "@/lib/payment";
import { translatePaymentError } from "@/lib/payment-errors";

const COUNTDOWN_TICK_MS = 500;

/** 下单页 → 订单页的凭据交接（读后即焚；坏 JSON 静默落 unsupported 分派） */
function readSessionCredential(orderId: string): unknown {
	const raw = sessionStorage.getItem(`order-credential:${orderId}`);
	if (!raw) return null;
	try {
		return JSON.parse(raw);
	} catch {
		return null;
	}
}

/** 换渠道候选：WEB_ENABLED_PROVIDERS 单源派生（与下单页灰置口径一致），
 *  排除当前渠道；当前渠道不在签约集（旧单）时返回全量签约候选 */
function switchCandidates(current: string): PaymentProvider[] {
	return WEB_ENABLED_PROVIDERS.filter((p) => p !== current);
}

export default function OrderDetailPage() {
	const params = useParams<{ id: string }>();
	const orderId = params?.id ?? "";
	const { authed, confirmed } = useAuthed();

	const [order, setOrder] = useState<Order | null>(null);
	// 下单页交接凭据（sessionStorage 读后即焚；lazy init 避免 effect 内 setState）
	const [credential, setCredential] = useState<unknown>(() =>
		readSessionCredential(orderId),
	);
	const [generatedQr, setGeneratedQr] = useState<string | null>(null);
	const [loadState, setLoadState] = useState<"loading" | "ok" | "error">("loading");
	const [pollElapsed, setPollElapsed] = useState(0);
	const [manualMode, setManualMode] = useState(false);
	const [nowMs, setNowMs] = useState(() => Date.now());
	const [switching, setSwitching] = useState(false);
	const [switchError, setSwitchError] = useState<string | null>(null);

	const status = (order?.status ?? "pending") as OrderPollStatus;

	const fetchStatus = useCallback(async () => {
		const { data } = await client.query({
			query: ORDER_STATUS,
			variables: { id: orderId },
			fetchPolicy: "network-only",
		});
		if (data?.orderStatus) setOrder(data.orderStatus);
		return (data?.orderStatus?.status ?? "pending") as OrderPollStatus;
	}, [orderId]);

	// 首拉：orderStatus + createOrder/replaceProvider 途经本页时凭据从
	// sessionStorage 取（new 页 replace 路由后凭据不落 URL/query）
	useEffect(() => {
		if (!orderId || !authed) return;
		let cancelled = false;

		client
			.query({ query: ORDER_STATUS, variables: { id: orderId } })
			.then(({ data }) => {
				if (cancelled) return;
				if (data?.orderStatus) {
					setOrder(data.orderStatus);
					setLoadState("ok");
				} else {
					setLoadState("error");
				}
			})
			.catch(() => {
				if (!cancelled) setLoadState("error");
			});

		return () => {
			cancelled = true;
		};
	}, [orderId, authed]);

	useEffect(() => {
		sessionStorage.removeItem(`order-credential:${orderId}`);
	}, [orderId]);

	// 二维码渲染：qr_code 凭据 → dataURL（qrcode MIT）
	const dispatch: CredentialDispatch = useMemo(
		() => dispatchCredential(credential),
		[credential],
	);

	useEffect(() => {
		if (dispatch.mode !== "qr") return;
		let cancelled = false;
		QRCode.toDataURL(dispatch.url, { width: 220, margin: 1 }).then((url) => {
			if (!cancelled) setGeneratedQr(url);
		}).catch(() => {
			if (!cancelled) setGeneratedQr(null);
		});
		return () => {
			cancelled = true;
		};
	}, [dispatch]);

	// 二维码展示位（非 qr 凭据时为 null，走占位/其他分派）
	const qrDataUrl = dispatch.mode === "qr" ? generatedQr : null;
	// 渠道化扫码引导（P1 文案）：alipay_qr 与 wechat_native 同走 qr_code 凭据，
	// 文案按 provider 区分，避免支付宝渠道错误引导「使用微信扫码」。
	const isAlipayQr = order?.provider === "alipay_qr";
	// P2 刷新凭据丢失：sessionStorage 读后即焚，刷新后 credential=null；
	// 订单 pending 时提示换渠道恢复（换渠道按钮高亮 primary 引导）。
	const credentialLost =
		dispatch.mode === "unsupported" &&
		credential === null &&
		status === "pending";

	// 手动态（R14 超窗/用户暂停）：pollElapsed 超 30s 派生，无需 effect 写 state
	const windowExpired = pollElapsed >= POLL_TOTAL_MS;
	const manual = manualMode || windowExpired;

	// 轮询（R14）：pending 且未超窗才推进；决策全部走 nextPollTick 纯函数
	useEffect(() => {
		if (loadState !== "ok" || !authed || manualMode || windowExpired) return;
		const tick = nextPollTick(pollElapsed, status);
		if (!tick.continue) return;

		const timer = setTimeout(() => {
			void fetchStatus().finally(() => {
				setPollElapsed((e) => e + (tick.delayMs ?? 0));
			});
		}, tick.delayMs ?? 0);

		return () => clearTimeout(timer);
	}, [loadState, authed, pollElapsed, status, fetchStatus, manualMode, windowExpired]);

	// 倒计时刷新（R6）
	useEffect(() => {
		if (loadState !== "ok") return;
		const timer = setInterval(() => setNowMs(Date.now()), COUNTDOWN_TICK_MS);
		return () => clearInterval(timer);
	}, [loadState]);

	async function switchProvider(next: PaymentProvider) {
		if (!order) return;
		setSwitching(true);
		setSwitchError(null);
		try {
			const { data } = await client.mutate({
				mutation: REPLACE_PROVIDER,
				variables: { input: { orderId: order.id, provider: next } },
			});
			const payload = data?.replaceProvider;
			if (payload?.result) {
				setOrder(payload.result);
				setCredential(payload.metadata?.credential ?? null);
				setPollElapsed(0);
				setManualMode(false);
			} else {
				// replaceProvider 错误面：order has already been processed（并发双换）、
				// :provider_not_configured（未签约渠道）——经翻译层，不透传原文/裸原子
				setSwitchError(
					translatePaymentError(
						payload?.errors[0]?.message,
						"切换渠道失败，请重试",
					),
				);
			}
		} catch (e) {
			setSwitchError(
				translatePaymentError(
					e instanceof Error ? e.message : null,
					"切换渠道失败，请重试",
				),
			);
		} finally {
			setSwitching(false);
		}
	}

	if (!authed || !confirmed) {
		return (
			<main className="mx-auto grid w-full max-w-lg gap-4 px-4 py-10">
				<div className="join-card text-center">
					<h1 className="text-lg font-medium">请先登录</h1>
					<p className="mt-2 text-sm text-ink-3">订单信息仅报名人本人可见。</p>
				</div>
			</main>
		);
	}

	const remain = countdownText(nowMs, order?.expireAt);
	const expired = remain === "已过期";
	const paid = status === "paid";

	return (
		<main className="mx-auto grid w-full max-w-lg gap-4 px-4 py-10" data-testid="order-detail">
			{loadState === "loading" ? (
				<div className="h-48 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
			) : loadState === "error" || !order ? (
				<div className="join-card text-center">
					<h1 className="text-lg font-medium">订单不可访问</h1>
					<p className="mt-2 text-sm text-ink-3">
						订单不存在或不是你的订单。可从
						<Link href="/participations" className="underline">我的报名</Link>
						重新进入。
					</p>
				</div>
			) : (
				<>
					<div className="join-card" data-testid="order-summary">
						<div className="flex items-start justify-between gap-3">
							<div>
								<h1 className="text-lg font-medium">
									{paid ? "支付成功" : expired ? "订单已过期" : "等待支付"}
								</h1>
								<p className="mt-1 text-sm text-ink-3">
									{PROVIDER_LABEL[order.provider] ?? order.provider} · ¥
									{formatAmount(order.amountCents)}
								</p>
							</div>
							<span
								data-testid="order-countdown"
								className={`rounded-full border px-2.5 py-1 text-xs ${
									expired || paid
										? "border-line text-ink-3"
										: "border-amber-400/40 text-amber-300"
								}`}
							>
								{paid ? "已支付" : remain}
							</span>
						</div>

						{paid ? (
							<div className="mt-4 grid gap-2 text-sm">
								<p role="status" data-testid="order-paid">
									✓ 支付完成，报名已确认。
								</p>
								<Link
									href="/participations"
									className="justify-self-start rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line"
								>
									查看我的报名
								</Link>
							</div>
						) : expired ? (
							<p className="mt-4 text-sm text-ink-3" data-testid="order-expired-note">
								订单超时未支付，名额已释放。可重新报名后再下单。
							</p>
						) : manual ? (
							<div className="mt-4 grid gap-2" data-testid="order-manual-mode">
								<p className="text-[13px] text-ink-3">
									自动刷新已暂停（30 秒）。完成支付后请手动刷新确认。
								</p>
								<button
									type="button"
									onClick={() => {
										setPollElapsed(0);
										setManualMode(false);
									}}
									className="justify-self-start rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line"
								>
									刷新状态
								</button>
							</div>
						) : (
							<p className="mt-4 text-[13px] text-ink-3" data-testid="order-polling">
								正在确认支付状态…（每 2 秒自动刷新）
							</p>
						)}
					</div>

					{!paid && !expired ? (
						<div className="join-card" data-testid="order-credential">
							{dispatch.mode === "qr" ? (
								<div className="grid justify-items-center gap-3">
									{qrDataUrl ? (
										// eslint-disable-next-line @next/next/no-img-element
										<img
											src={qrDataUrl}
											alt={isAlipayQr ? "支付宝支付二维码" : "微信支付二维码"}
											width={220}
											height={220}
											data-testid="order-qr"
											className="rounded-large border border-line bg-white p-2"
										/>
									) : (
										<div className="grid h-[220px] w-[220px] place-items-center rounded-large border border-line bg-soft-2 text-xs text-ink-3">
											二维码生成中…
										</div>
									)}
									<p className="text-[13px] text-ink-3">
										{isAlipayQr
											? "使用支付宝扫一扫完成支付"
											: "使用微信扫码完成支付"}
									</p>
								</div>
							) : dispatch.mode === "redirect" ? (
								<div className="grid gap-2">
									<a
										href={dispatch.url}
										target="_blank"
										rel="noreferrer"
										className="rounded-large border border-line-strong bg-card px-4 py-2 text-center text-sm font-medium text-ink hover:border-line"
										data-testid="order-redirect"
									>
										前往支付宝支付
									</a>
									<p className="text-[13px] text-ink-3">
										新窗口完成支付后回到本页，状态将自动确认。
									</p>
								</div>
							) : (
								<div
									className="grid gap-2"
									data-testid="order-credential-unsupported"
								>
									<p className="text-sm text-ink-3">
										{credentialLost
											? "支付凭据已失效，请更换支付方式重新获取。"
											: dispatch.reason}
									</p>
									{credentialLost ? (
										<p className="text-[13px] text-ink-3">
											点击下方「更换支付方式」即可重新发起支付，无需重新报名。
										</p>
									) : null}
								</div>
							)}
						</div>
					) : null}

					{!paid && !expired ? (
						<div className="join-card" data-testid="order-switch">
							<h2 className="text-sm font-medium text-ink">更换支付方式</h2>
							<div className="mt-3 flex flex-wrap gap-2">
								{switchCandidates(order.provider).map((p) => (
									<button
										key={p}
										type="button"
										disabled={switching}
										onClick={() => void switchProvider(p)}
										className={
											credentialLost
												? "join-button join-button--primary"
												: "rounded-large border border-line bg-card px-3 py-1.5 text-sm text-ink-2 hover:border-line-strong disabled:opacity-50"
										}
										data-testid={`switch-${p}`}
									>
										{PROVIDER_LABEL[p]}
									</button>
								))}
							</div>
							{switchError ? (
								<p role="alert" className="mt-3 text-[13px] text-red-300">
									{switchError}
								</p>
							) : null}
						</div>
					) : null}
				</>
			)}
		</main>
	);
}
