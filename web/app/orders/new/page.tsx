"use client";

/**
 * 缴费闭环 U11：下单页 /orders/new?enrollmentId=。
 *
 * 职责：provider 选择（微信扫码 / 支付宝——web 端两渠道，R13）→ createOrder →
 * 跳转 /orders/[id]（凭据渲染与轮询在那边）。渠道下单失败（无凭据无订单）
 * 就地展示错误，可重试。
 *
 * 入口：详情页 payment_pending 态「去支付」/ participations 待支付卡（R5 占位后
 * 2h 限时，R6）。
 */

import Link from "next/link";
import { Suspense, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { client } from "@/lib/apollo-client";
import { CREATE_ORDER, type PaymentProvider } from "@/lib/graphql/orders";
import { useAuthed } from "@/lib/use-authed";
import { PROVIDER_LABEL } from "@/lib/payment";

/** web 端可下单渠道（wechat_jsapi 是小程序专属凭据，不在 web 面提供） */
const WEB_PROVIDERS: { value: PaymentProvider; hint: string }[] = [
	{ value: "wechat_native", hint: "微信扫码支付" },
	{ value: "alipay_page", hint: "支付宝·电脑网页支付" },
	{ value: "alipay_wap", hint: "支付宝·手机网页支付" },
];

function NewOrderForm() {
	const router = useRouter();
	const search = useSearchParams();
	const enrollmentId = search.get("enrollmentId") ?? "";
	const { authed, confirmed } = useAuthed();

	const [provider, setProvider] = useState<PaymentProvider>("wechat_native");
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState<string | null>(null);

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
			setError(payload?.errors[0]?.message ?? "下单失败，请稍后重试");
		} catch (e) {
			setError(e instanceof Error ? e.message : "下单失败，请稍后重试");
		} finally {
			setBusy(false);
		}
	}

	if (!authed || !confirmed) {
		return (
			<div className="join-card text-center">
				<h1 className="text-lg font-medium">请先登录</h1>
				<p className="mt-2 text-sm text-ink-3">支付前需要登录以确认报名归属。</p>
			</div>
		);
	}

	if (!enrollmentId) {
		return (
			<div className="join-card text-center">
				<h1 className="text-lg font-medium">缺少报名信息</h1>
				<p className="mt-2 text-sm text-ink-3">
					请从<Link href="/participations" className="underline">我的报名</Link>进入待支付报名。
				</p>
			</div>
		);
	}

	return (
		<div className="join-card" data-testid="order-new">
			<h1 className="text-lg font-medium">选择支付方式</h1>
			<p className="mt-1 text-sm text-ink-3">
				报名名额已保留，订单有效期 2 小时（以订单页倒计时为准）。
			</p>

			<fieldset className="mt-5 grid gap-2" data-testid="provider-picker">
				<legend className="text-[13px] text-ink-3">支付渠道</legend>
				{WEB_PROVIDERS.map((p) => (
					<label
						key={p.value}
						data-testid={`provider-${p.value}`}
						className={`flex cursor-pointer items-center gap-3 rounded-large border px-3 py-3 text-sm ${
							provider === p.value
								? "border-line-strong bg-soft-2 text-ink"
								: "border-line bg-card text-ink-2"
						}`}
					>
						<input
							type="radio"
							name="provider"
							value={p.value}
							checked={provider === p.value}
							onChange={() => setProvider(p.value)}
						/>
						<span>
							{PROVIDER_LABEL[p.value]}
							<span className="ml-2 text-[13px] text-ink-3">{p.hint}</span>
						</span>
					</label>
				))}
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
					{busy ? "下单中…" : "去支付"}
				</button>
				<Link href="/participations" className="text-sm text-ink-3 underline">
					返回我的报名
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
