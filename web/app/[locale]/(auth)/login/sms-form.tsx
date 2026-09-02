"use client";

import { Link } from "@/i18n/navigation";
import { useState, type FormEvent } from "react";
import { useMutation } from "@apollo/client/react";
	import { useRouter } from "next/navigation";
	import { useSearchParams } from "next/navigation";
	import { useTranslations } from "next-intl";
import { client } from "@/lib/apollo-client";
import {
	BIND_WECHAT_WITH_PHONE,
	graphqlErrorDetails,
} from "@/lib/graphql/auth";
import { navigateAfterLogin } from "./use-auth-submit";
import { useSmsLogin, smsErrorMessage } from "./use-sms-login";

/**
 * 手机验证码登录表单(plan 002 U5)。
 *
 * 手机号 + 6 位验证码;发送按钮带 retryAfterSeconds 倒计时(后端返回 60s);
 * 用户不存在由后端自动建号(国内 C 端主流模式)。
 *
 * bindTicket 传入时切换为微信首登绑定模式(AuthShell 于 tabs 位置渲染
 * 「验证手机号」标题区):发码 purpose=WECHAT_BIND、提交走
 * bindWechatWithPhone、票据失效提示重新扫码——表单结构与登录模式复用。
 */
export default function SmsForm({ bindTicket }: { bindTicket?: string }) {
	const router = useRouter();
	const bindMode = bindTicket != null;
	const t = useTranslations("auth.sms");
	const bindT = useTranslations("auth.wechatCallback");
	const termsT = useTranslations("auth.terms");
	const authT = useTranslations("auth");

	// 绑定成功后的跳转目标（/login?bind_ticket=&next= 由 wechat-callback 透传）
	const nextParam = () =>
		typeof window === "undefined" ? null : new URLSearchParams(window.location.search).get("next");
	const { sendCode, submit, countdown, sending, busy, error, setError } =
		useSmsLogin();
	const [bind, bindState] = useMutation(BIND_WECHAT_WITH_PHONE);
	const [phone, setPhone] = useState("");
	const [code, setCode] = useState("");
	const searchParams = useSearchParams();
	const nextRaw = searchParams?.get("next") ?? null;
	const switchHref =
		"/register" + (nextRaw ? `?next=${encodeURIComponent(nextRaw)}` : "");

	const handleSend = async () => {
		if (!phone.trim()) {
			setError(t("errorInvalidPhone"));
			return;
		}
		await sendCode(phone.trim(), bindMode ? "WECHAT_BIND" : "LOGIN");
	};

	const handleBind = async () => {
		try {
			const { data } = await bind({
				variables: { bindTicket: bindTicket!, phone, code },
			});
			if (data?.bindWechatWithPhone?.id) {
				await client.resetStore();
				navigateAfterLogin(router, nextParam());
				return;
			}
			setError(bindT("bindFailed"));
		} catch (e) {
			const errorCode = graphqlErrorDetails(e)?.code;
			if (
				errorCode === "invalid_bind_ticket" ||
				errorCode === "ticket_expired"
			) {
				setError(bindT("ticketInvalid"));
				return;
			}
			setError(smsErrorMessage(e, bindT));
		}
	};

	const handleSubmit = async (event: FormEvent<HTMLFormElement>) => {
		event.preventDefault();
		if (!phone.trim()) {
			setError(t("errorInvalidPhone"));
			return;
		}
		if (!/^\d{6}$/.test(code.trim())) {
			setError(t("errorInvalidCode"));
			return;
		}
		if (bindMode) {
			await handleBind();
			return;
		}
		await submit(phone.trim(), code.trim());
	};

	return (
		<>
		<form className="auth-form" onSubmit={handleSubmit} noValidate>
			{bindMode && (
				<p className="auth-wechat-hint">{bindT("bindHint")}</p>
			)}
			{error && (
				<div role="alert" className="auth-alert">
					{error}
				</div>
			)}

			<div className="auth-field">
				<input
					id="auth-sms-phone"
					name="phone"
					className="auth-input"
					type="tel"
					placeholder={t("placeholderPhone")}
					value={phone}
					onChange={(event) => {
						setPhone(event.target.value);
						setError(null);
					}}
					autoComplete="tel"
					autoFocus
					required
				/>
			</div>

			<div className="auth-field">
				<div className="auth-sms-code-row">
					<input
						id="auth-sms-code"
						name="code"
						className="auth-input"
						type="text"
						inputMode="numeric"
						maxLength={6}
						placeholder={t("placeholderCode")}
						value={code}
						onChange={(event) => {
							setCode(event.target.value);
							setError(null);
						}}
						autoComplete="one-time-code"
						required
					/>
					<button
						type="button"
						className="auth-sms-send"
						disabled={sending || countdown > 0}
						onClick={handleSend}
					>
						{countdown > 0
							? t("resendCountdown", { seconds: countdown })
							: sending
								? t("sending")
								: t("sendCode")}
					</button>
				</div>
			</div>

			<button type="submit" className="auth-submit" disabled={busy || bindState.loading}>
				{bindMode
					? (bindState.loading ? bindT("binding") : bindT("bindSubmit"))
					: (busy ? t("signingIn") : t("submit"))}
			</button>
		</form>
		{!bindMode && (
			<p className="auth-switch">
				<Link href={switchHref} className="auth-inline-link auth-switch__action">
					{authT("switch.createAccount")}
				</Link>
			</p>
		)}
		{!bindMode && (
			<p className="auth-terms">
				{termsT("loginAction")}{termsT("agreePrefix")}
				<Link href="/terms">{termsT("serviceTerms")}</Link>
				{termsT("and")}
				<Link href="/privacy">{termsT("privacyPolicy")}</Link>
			</p>
		)}
		</>
	);
}
