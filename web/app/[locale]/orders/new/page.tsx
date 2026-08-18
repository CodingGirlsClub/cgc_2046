"use client";

/**
 * 缴费闭环 U11：下单页 /orders/new?enrollmentId=。
 *
 * 职责：进页守卫（P1）→ provider 选择 → createOrder → 跳转 /orders/[id]
 * （凭据渲染与轮询在那边）。渠道下单失败（无凭据无订单）就地展示错误，可重试。
 *
 * 守卫：拿 enrollmentId 查报名，非 payment_pending → 引导卡（不渲染渠道表单）；
 * payment_pending 且已有 pending 订单 → 直接跳已有订单页（避免重复下单撞
 * 后端 not_payment_pending）。
 *
 * 入口：详情页 payment_pending 态「去支付」/ participations 待支付卡（R5 占位后
 * 2h 限时，R6）。
 */

import Link from "next/link";
import { Suspense, useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { useRouter, useSearchParams } from "next/navigation";
import { client } from "@/lib/apollo-client";
import {
	CREATE_ORDER,
	MY_PENDING_ORDERS,
	type PaymentProvider,
} from "@/lib/graphql/orders";
import { MY_ENROLLMENT } from "@/lib/graphql/events";
import { useAuthed } from "@/lib/use-authed";
import { PROVIDER_LABEL, WEB_ENABLED_PROVIDERS } from "@/lib/payment";
import { usePaymentErrorTranslator } from "@/lib/payment-errors";

/**
 * web 端可下单渠道展示列表（wechat_jsapi 是小程序专属凭据，不在 web 面提供）。
 * enabled 由 WEB_ENABLED_PROVIDERS 单源判定（lib/payment.ts，与订单页换渠道
 * 候选共用）；未签约渠道灰置（alipay_page/alipay_wap——后端签约配置面暂未做，
 * 签约后在 WEB_ENABLED_PROVIDERS 增删即可，见 plan 024 R13 续）。
 */
const WEB_PROVIDERS: { value: PaymentProvider; hint: string }[] = [
	{ value: "wechat_native", hint: "providerWechat" },
	{ value: "alipay_page", hint: "providerAlipayPage" },
	{ value: "alipay_wap", hint: "providerAlipayWap" },
	{ value: "alipay_qr", hint: "providerAlipayQr" },
];

type GuardState =
	| { kind: "checking" }
	| { kind: "ok" }
	| { kind: "redirecting"; orderId: string }
	| { kind: "blocked"; message: string };

function NewOrderForm() {
	const router = useRouter();
	const search = useSearchParams();
	const enrollmentId = search.get("enrollmentId") ?? "";
	const { authed, confirmed } = useAuthed();
	const translatePaymentError = usePaymentErrorTranslator();
	const t = useTranslations("orders");
	const labelsT = useTranslations();

	const [provider, setProvider] = useState<PaymentProvider>("wechat_native");
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState<string | null>(null);
	const [guard, setGuard] = useState<GuardState>({ kind: "checking" });

	// 进页守卫（P1）：报名状态校验 + 已有 pending 订单跳转
	useEffect(() => {
		if (!enrollmentId || !authed || !confirmed) return;
		let cancelled = false;

		(async () => {
			try {
				const { data: enrData } = await client.query({
					query: MY_ENROLLMENT,
					variables: { id: enrollmentId },
				});
				const enrollment = enrData?.myEnrollments?.results?.[0];
				if (!enrollment || enrollment.status !== "payment_pending") {
					if (!cancelled)
						setGuard({
							kind: "blocked",
							message: t("blockedMessage"),
						});
					return;
				}
				const { data: ordData } = await client.query({
					query: MY_PENDING_ORDERS,
					variables: { enrollmentId },
				});
				const existing = ordData?.myOrders?.results?.[0];
				if (existing) {
					if (!cancelled)
						setGuard({ kind: "redirecting", orderId: existing.id });
					return;
				}
				if (!cancelled) setGuard({ kind: "ok" });
			} catch {
				// 守卫查询失败不阻塞下单：错误在 createOrder 时翻译兜底
				if (!cancelled) setGuard({ kind: "ok" });
			}
		})();

		return () => {
			cancelled = true;
		};
	}, [enrollmentId, authed, confirmed, router, t]);

	// 已有 pending 订单 → 直接跳订单页（不重复下单）
	useEffect(() => {
		if (guard.kind !== "redirecting") return;
		router.replace(`/orders/${guard.orderId}`);
	}, [guard, router]);

	async function createOrder() {
		if (!enrollmentId) return;
		setBusy(true);
		setError(null);
		try {
			const { data } = await client.mutate({
				mutation: CREATE_ORDER,
				variables: { input: { enrollmentId, provider } },
			});
			const payload = data?.createOrder;
			if (payload?.result) {
				// 凭据经 sessionStorage 交接（不落 URL；订单页读后即焚）
				if (payload.metadata?.credential) {
					sessionStorage.setItem(
						`order-credential:${payload.result.id}`,
						payload.metadata.credential,
					);
				}
				router.replace(`/orders/${payload.result.id}`);
				return;
			}
			setError(
				translatePaymentError(
					payload?.errors[0]?.code ?? null,
					t("orderFailed"),
				),
			);
		} catch (e) {
			setError(
				translatePaymentError(
					e instanceof Error ? e.message : null,
					t("orderFailed"),
				),
			);
		} finally {
			setBusy(false);
		}
	}

	if (!authed || !confirmed) {
		return (
			<div className="join-card text-center">
				<h1 className="text-lg font-medium">{t("newLoginTitle")}</h1>
				<p className="mt-2 text-sm text-ink-3">{t("newLoginDesc")}</p>
			</div>
		);
	}

	if (!enrollmentId) {
		return (
			<div className="join-card text-center">
				<h1 className="text-lg font-medium">{t("missingEnrollTitle")}</h1>
				<p className="mt-2 text-sm text-ink-3">
					{t("missingEnrollDesc1")}<Link href="/participations" className="underline">{t("myEnrollments")}</Link>{t("missingEnrollDesc2")}
				</p>
			</div>
		);
	}

	if (guard.kind === "blocked") {
		return (
			<div className="join-card text-center" data-testid="order-guard-blocked">
				<h1 className="text-lg font-medium">{t("blockedTitle")}</h1>
				<p className="mt-2 text-sm text-ink-3">{guard.message}</p>
				<div className="mt-5 flex flex-wrap items-center justify-center gap-3">
					<Link
						href="/participations"
						className="rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line"
						data-testid="order-guard-to-participations"
					>
						{t("myEnrollments")}
					</Link>
				</div>
			</div>
		);
	}

	if (guard.kind === "redirecting") {
		return (
			<div
				className="h-40 animate-pulse rounded-large bg-soft-2 ring-1 ring-line"
				data-testid="order-guard-redirecting"
			/>
		);
	}

	if (guard.kind === "checking") {
		return (
			<div className="h-40 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" data-testid="order-guard-loading" />
		);
	}

	return (
		<div className="join-card" data-testid="order-new">
			<h1 className="text-lg font-medium">{t("chooseProvider")}</h1>
			<p className="mt-1 text-sm text-ink-3">
				{t("chooseProviderDesc")}
			</p>

			<fieldset className="mt-5 grid gap-2" data-testid="provider-picker">
				<legend className="text-[13px] text-ink-3">{t("providerField")}</legend>
				{WEB_PROVIDERS.map((p) => {
					const disabled = !WEB_ENABLED_PROVIDERS.includes(p.value);
					return (
						<label
							key={p.value}
							data-testid={`provider-${p.value}`}
							className={`flex cursor-pointer items-center gap-3 rounded-large border px-3 py-3 text-sm ${
								disabled
									? "cursor-not-allowed border-line bg-soft-2 text-ink-3 opacity-60"
									: provider === p.value
										? "border-line-strong bg-soft-2 text-ink"
										: "border-line bg-card text-ink-2"
							}`}
						>
							<input
								type="radio"
								name="provider"
								value={p.value}
								disabled={disabled}
								checked={!disabled && provider === p.value}
								onChange={() => setProvider(p.value)}
							/>
							<span>
								{labelsT(PROVIDER_LABEL[p.value])}
								<span className="ml-2 text-[13px] text-ink-3">{t(p.hint)}</span>
							</span>
							{disabled ? (
								<span className="ml-auto rounded-full bg-amber-100 px-2 py-0.5 text-[11px] text-amber-800">
									{t("notOpen")}
								</span>
							) : null}
						</label>
					);
				})}
			</fieldset>

			{error ? (
				<p role="alert" className="mt-4 text-[13px] text-red-300">
					{error}
				</p>
			) : null}

			<div className="mt-5 flex items-center gap-3">
				<button
					type="button"
					disabled={busy}
					onClick={() => void createOrder()}
					className="rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line disabled:opacity-50"
					data-testid="create-order"
				>
					{busy ? t("ordering") : t("goPay")}
				</button>
				<Link href="/participations" className="text-sm text-ink-3 underline">
					{t("backToEnrollments")}
				</Link>
			</div>
		</div>
	);
}

export default function NewOrderPage() {
	return (
		<main className="mx-auto grid w-full max-w-lg gap-4 px-4 py-10">
			<Suspense fallback={<div className="h-40 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />}>
				<NewOrderForm />
			</Suspense>
		</main>
	);
}
