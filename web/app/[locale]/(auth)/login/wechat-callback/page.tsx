"use client";

import { Suspense, useEffect, useRef, useState } from "react";
import { useMutation } from "@apollo/client/react";
import { useRouter, useSearchParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import { client } from "@/lib/apollo-client";
import { SIGN_IN_WITH_WECHAT } from "@/lib/graphql/auth";
import { navigateAfterLogin } from "../use-auth-submit";

/**
 * 微信扫码回调页(plan 002 U4/U5)。
 *
 * 微信跳转 /login/wechat-callback?code=&state=(&next= 由 qrconnect 透传)。
 * 本页运行在 QR 面板 iframe 内（D2：微信自渲染扫码页）——登录成功后顶层
 * 导航接管（同源可写 window.top），顶层离开登录页:
 * - signInWithWechat → SIGNED_IN:resetStore 后跳 next;
 * - NEEDS_BINDING:同样顶层接管跳回 /login?bind_ticket= ——登录页原地
 *   切换为手机绑定表单(卡片壳/品牌区/QR 面板不动,用户无换页感);
 * - state 重放/过期/换票失败 → 错误文案 + 返回登录。
 * next 只从 URL 参数取(state 只防伪);resolveNextTarget 同源校验防开跳转。
 */
// 跳转登录页绑定模式（iframe 内顶层接管，与 SIGNED_IN 路径对称）
function navigateToBindPage(
	router: { push: (path: string) => void },
	bindTicket: string,
	nextRaw: string | null,
) {
	const params = new URLSearchParams({ bind_ticket: bindTicket });
	if (nextRaw) params.set("next", nextRaw);
	const path = `/login?${params.toString()}`;
	if (window.self !== window.top) {
		try {
			window.top!.location.assign(path);
			return;
		} catch {
			// 跨源顶层（理论不可达，防御）：退回本窗口
		}
	}
	router.push(path);
}

function WechatCallbackContent() {
	const router = useRouter();
	const searchParams = useSearchParams();
	// advisor02 A12：dev StrictMode 双跑防重（state 单次消费，二跑必败出假错误）
	const startedRef = useRef(false);
	const t = useTranslations("auth.wechatCallback");
	const [error, setError] = useState<string | null>(null);
	const [signInWithWechat] = useMutation(SIGN_IN_WITH_WECHAT);

	const oauthCode = searchParams?.get("code");
	const oauthState = searchParams?.get("state");
	const missingParams = !oauthCode || !oauthState;

	useEffect(() => {
		if (!oauthCode || !oauthState) return;
		if (startedRef.current) return;
		startedRef.current = true;

		// 不设 cancelled 短路（advisor02 R2-1）：mutation 由 startedRef 保证
		// 单发，dev StrictMode 首跑 cleanup 后唯一一次请求的成功回调若被
		// cancelled 丢弃，页面会停在 processing。成功路径是顶层导航，
		// 卸载后的 setState 无害。
		const run = async () => {
			try {
				const { data } = await signInWithWechat({
					variables: { code: oauthCode, state: oauthState },
				});
				const result = data?.signInWithWechat;
				if (result?.status === "SIGNED_IN") {
					await client.resetStore();
					navigateAfterLogin(router, searchParams?.get("next") ?? null);
					return;
				}
				if (result?.status === "NEEDS_BINDING" && result.bindTicket) {
					navigateToBindPage(
						router,
						result.bindTicket,
						searchParams?.get("next") ?? null,
					);
					return;
				}
				setError(t("signInFailed"));
			} catch {
				setError(t("signInFailed"));
			}
		};

		run();
	}, [searchParams, oauthCode, oauthState, signInWithWechat, router, t]);

	if (missingParams || error) {
		return (
			<div className="auth-form-body">
				<div role="alert" className="auth-alert">
					{missingParams ? t("missingParams") : error}
				</div>
				<Link href="/login" className="auth-inline-link">
					{t("backToLogin")}
				</Link>
			</div>
		);
	}

	return (
		<div className="auth-form-body">
			<p className="auth-wechat-hint">{t("processing")}</p>
		</div>
	);
}

export default function WechatCallbackPage() {
	return (
		<Suspense>
			<WechatCallbackContent />
		</Suspense>
	);
}
