"use client";

import { Suspense, useEffect, useRef, useState, type FormEvent } from "react";
import { useMutation } from "@apollo/client/react";
import { useRouter, useSearchParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import { client } from "@/lib/apollo-client";
import {
	BIND_WECHAT_WITH_PHONE,
	graphqlErrorDetails,
	SIGN_IN_WITH_WECHAT,
} from "@/lib/graphql/auth";
import { resolveNextTarget } from "../use-auth-submit";
import { smsErrorMessage, useSmsLogin } from "../use-sms-login";

/**
 * 微信扫码回调页(plan 002 U4/U5)。
 *
 * 微信跳转 /login/wechat-callback?code=&state=(&next= 由 qrconnect 透传)。
 * 本页运行在 QR 面板 iframe 内（D2：微信自渲染扫码页）——登录成功后顶层
 * 导航接管（同源可写 window.top），顶层离开登录页:
 * - signInWithWechat → SIGNED_IN:resetStore 后跳 next;
 * - NEEDS_BINDING:强制手机验证码绑定/建号(bindWechatWithPhone,WECHAT_BIND 验码);
 * - state 重放/过期/换票失败 → 错误文案 + 返回登录。
 * next 只从 URL 参数取(state 只防伪);resolveNextTarget 同源校验防开跳转。
 */
// 登录成功导航：iframe 内（D2 QR 面板）时接管顶层（同源才可写，跨源兜底本窗口）
function navigateAfterLogin(
	router: { push: (path: string) => void },
	nextRaw: string | null,
) {
	const path = resolveNextTarget(nextRaw, window.location.origin);
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
	const [bindTicket, setBindTicket] = useState<string | null>(null);
	const [error, setError] = useState<string | null>(null);
	const [signInWithWechat] = useMutation(SIGN_IN_WITH_WECHAT);
	const [bind, bindState] = useMutation(BIND_WECHAT_WITH_PHONE);
	const { sendCode, countdown, sending } = useSmsLogin();
	const [phone, setPhone] = useState("");
	const [code, setCode] = useState("");
	const [bindError, setBindError] = useState<string | null>(null);

	const oauthCode = searchParams?.get("code");
	const oauthState = searchParams?.get("state");
	const missingParams = !oauthCode || !oauthState;

	useEffect(() => {
		if (!oauthCode || !oauthState) return;
		if (startedRef.current) return;
		startedRef.current = true;

		let cancelled = false;
		const run = async () => {
			try {
				const { data } = await signInWithWechat({
					variables: { code: oauthCode, state: oauthState },
				});
				if (cancelled) return;
				const result = data?.signInWithWechat;
				if (result?.status === "SIGNED_IN") {
					await client.resetStore();
					navigateAfterLogin(router, searchParams?.get("next") ?? null);
					return;
				}
				if (result?.status === "NEEDS_BINDING" && result.bindTicket) {
					setBindTicket(result.bindTicket);
					return;
				}
				setError(t("signInFailed"));
			} catch {
				if (!cancelled) setError(t("signInFailed"));
			}
		};

		run();
		return () => {
			cancelled = true;
		};
	}, [searchParams, oauthCode, oauthState, signInWithWechat, router, t]);

	const handleBind = async (event: FormEvent<HTMLFormElement>) => {
		event.preventDefault();
		if (!bindTicket) return;
		setBindError(null);
		try {
			const { data } = await bind({
				variables: { bindTicket, phone: phone.trim(), code: code.trim() },
			});
			if (data?.bindWechatWithPhone?.id) {
				await client.resetStore();
				navigateAfterLogin(router, searchParams?.get("next") ?? null);
				return;
			}
			setBindError(t("bindFailed"));
		} catch (e) {
			const code = graphqlErrorDetails(e)?.code;
			setBindError(
				code === "invalid_bind_ticket" || code === "ticket_expired"
					? t("ticketInvalid")
					: smsErrorMessage(e, t),
			);
		}
	};

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

	if (bindTicket) {
		return (
			<div className="auth-form-body">
				<form className="auth-form" onSubmit={handleBind} noValidate>
					<p className="auth-wechat-hint">{t("bindHint")}</p>
					{bindError && (
						<div role="alert" className="auth-alert">
							{bindError}
						</div>
					)}

					<div className="auth-field">
						<label className="auth-field__label" htmlFor="wechat-bind-phone">
							{t("fieldPhone")}
						</label>
						<input
							id="wechat-bind-phone"
							name="phone"
							className="auth-input"
							type="tel"
							placeholder={t("placeholderPhone")}
							value={phone}
							onChange={(event) => {
								setPhone(event.target.value);
								setBindError(null);
							}}
							autoComplete="tel"
							autoFocus
							required
						/>
					</div>

					<div className="auth-field">
						<label className="auth-field__label" htmlFor="wechat-bind-code">
							{t("fieldCode")}
						</label>
						<div className="auth-sms-code-row">
							<input
								id="wechat-bind-code"
								name="code"
								className="auth-input"
								type="text"
								inputMode="numeric"
								maxLength={6}
								placeholder={t("placeholderCode")}
								value={code}
								onChange={(event) => {
									setCode(event.target.value);
									setBindError(null);
								}}
								autoComplete="one-time-code"
								required
							/>
							<button
								type="button"
								className="auth-sms-send"
								disabled={sending || countdown > 0 || !phone.trim()}
								onClick={() => sendCode(phone.trim(), "WECHAT_BIND")}
							>
								{countdown > 0
									? t("resendCountdown", { seconds: countdown })
									: sending
										? t("sending")
										: t("sendCode")}
							</button>
						</div>
					</div>

					<button type="submit" className="auth-submit" disabled={bindState.loading}>
						{bindState.loading ? t("binding") : t("bindSubmit")}
					</button>
				</form>
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
