"use client";

import { useEffect, useState } from "react";
import { useMutation } from "@apollo/client/react";
import { useTranslations } from "next-intl";
import QRCode from "qrcode";
import {
	graphqlErrorDetails,
	WECHAT_LOGIN_START,
	type WechatLoginStartResult,
} from "@/lib/graphql/auth";

interface QrState {
	qrUrl: string;
	imageDataUrl: string;
}

/**
 * 微信扫码登录面板(plan 002 U4/U5)。
 *
 * 挂载即 wechatLoginStart 拿 qrconnect URL,本地用 qrcode 生成二维码图。
 * 用户扫码后微信跳转 /login/wechat-callback?code=&state= 完成登录/绑定。
 * 凭证未配置(WECHAT_WEB_APPID/SECRET 缺失)→ 门禁文案,其余登录方式不受影响。
 */
export default function WechatQrPanel() {
	const t = useTranslations("auth.wechat");
	const [qr, setQr] = useState<QrState | null>(null);
	const [error, setError] = useState<string | null>(null);
	const [start] = useMutation(WECHAT_LOGIN_START);

	useEffect(() => {
		let cancelled = false;

		const load = async () => {
			try {
				// next 透传:当前 /login?next= 带入 redirect_uri(plan 002,state 只防伪)
				const next = new URLSearchParams(window.location.search).get("next");
				const { data } = await start({ variables: { next } });
				const result: WechatLoginStartResult | null | undefined =
					data?.wechatLoginStart;
				if (!result) {
					if (!cancelled) setError(t("unavailable"));
					return;
				}
				const imageDataUrl = await QRCode.toDataURL(result.qrUrl, {
					width: 200,
					margin: 1,
				});
				if (!cancelled) setQr({ qrUrl: result.qrUrl, imageDataUrl });
			} catch (e) {
				if (cancelled) return;
				setError(
					graphqlErrorDetails(e)?.code === "wechat_login_unavailable"
						? t("unavailable")
						: t("loadFailed"),
				);
			}
		};

		load();
		return () => {
			cancelled = true;
		};
	}, [start, t]);

	if (error) {
		return (
			<div className="auth-wechat-panel" role="alert">
				<p className="auth-wechat-hint">{error}</p>
			</div>
		);
	}

	if (!qr) {
		return (
			<div className="auth-wechat-panel">
				<div className="auth-wechat-qr auth-wechat-qr--loading" aria-busy="true" />
				<p className="auth-wechat-hint">{t("loading")}</p>
			</div>
		);
	}

	return (
		<div className="auth-wechat-panel">
			{/* eslint-disable-next-line @next/next/no-img-element -- dataURL 二维码不走 next/image */}
			<img className="auth-wechat-qr" src={qr.imageDataUrl} alt={t("qrAlt")} />
			<p className="auth-wechat-hint">{t("scanHint")}</p>
		</div>
	);
}
