"use client";

import { useEffect, useState } from "react";
import { useMutation } from "@apollo/client/react";
import { useTranslations } from "next-intl";
import {
	WECHAT_LOGIN_START,
	type WechatLoginStartResult,
} from "@/lib/graphql/auth";

/**
 * 微信扫码登录面板（plan 002 U4/U5；advisor02 M1 按 D2 重写）。
 *
 * qrconnect URL 必须由微信自渲染（iframe）：二维码 → 手机确认 → redirect
 * 全程在微信托管页面内完成，回调落回本浏览器（httpOnly cookie 可达）。
 * 严禁用 qrcode 库自渲染该 URL——那会让流程发生在手机内嵌浏览器里，
 * 桌面端登录断链（D2 决策）。
 *
 * expiresInSeconds（M7）：到期显示刷新按钮重新出码；unavailable（凭证
 * 未配置）→ 降级提示换用其他方式，不渲染扫码卡。
 */
export default function WechatQrPanel() {
	const t = useTranslations("auth.wechat");
	const [start] = useMutation(WECHAT_LOGIN_START);
	const [result, setResult] = useState<WechatLoginStartResult | null>(null);
	const [phase, setPhase] = useState<"loading" | "ready" | "unavailable">("loading");
	const [expiresAt, setExpiresAt] = useState<number | null>(null);
	const [nowMs, setNowMs] = useState(() => Date.now());
	const [reload, setReload] = useState(0);

	// 倒计时刷新（payment-checkout-dialog 先例）
	useEffect(() => {
		const timer = setInterval(() => setNowMs(Date.now()), 1000);
		return () => clearInterval(timer);
	}, []);

	// 过期为渲染期派生（set-state-in-effect 规则）
	const expired = phase === "ready" && expiresAt != null && nowMs >= expiresAt;

	useEffect(() => {
		let cancelled = false;

		const load = async () => {
			setPhase("loading");
			try {
				// next 透传：当前 /login?next= 带入 redirect_uri（state 只防伪）
				const next = new URLSearchParams(window.location.search).get("next");
				const { data } = await start({ variables: { next } });
				const res: WechatLoginStartResult | null | undefined =
					data?.wechatLoginStart;
				if (cancelled) return;
				if (!res) {
					setPhase("unavailable");
					return;
				}
				setResult(res);
				setExpiresAt(Date.now() + res.expiresInSeconds * 1000);
				setPhase("ready");
				setNowMs(Date.now());
			} catch {
				// 出码失败统一按 unavailable 降级（advisor02 R2-3：原先三元
				// 两侧同值；异常细分对用户可操作面无差异——都是换方式登录）
				if (!cancelled) setPhase("unavailable");
			}
		};

		load();
		return () => {
			cancelled = true;
		};
	}, [start, reload]);

	if (phase === "unavailable") {
		return (
			<div className="auth-wechat-panel" role="alert">
				<p className="auth-wechat-hint">{t("unavailable")}</p>
			</div>
		);
	}

	if (phase === "loading" || !result) {
		return (
			<div className="auth-wechat-panel">
				<div className="auth-wechat-qr auth-wechat-qr--loading" aria-busy="true" />
				<p className="auth-wechat-hint">{t("loading")}</p>
			</div>
		);
	}

	if (expired) {
		return (
			<div className="auth-wechat-panel">
				<div className="auth-wechat-qr auth-wechat-qr--loading" />
				<p className="auth-wechat-hint">{t("expired")}</p>
				<button
					type="button"
					className="auth-sms-send"
					onClick={() => setReload((n) => n + 1)}
				>
					{t("refresh")}
				</button>
			</div>
		);
	}

	return (
		<div className="auth-wechat-panel">
			{/* key 随 reload 递增，刷新时强制重建 iframe 避免微信页缓存 */}
			<iframe
				key={reload}
				className="auth-wechat-qr-frame"
				src={result.qrUrl}
				title={t("qrAlt")}
			/>
			<p className="auth-wechat-hint">{t("scanHint")}</p>
		</div>
	);
}
