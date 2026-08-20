"use client";

import { Link } from "@/i18n/navigation";
import { useState, type FormEvent } from "react";
import { useTranslations } from "next-intl";
import { useSmsLogin } from "./use-sms-login";

/**
 * 手机验证码登录表单(plan 002 U5)。
 *
 * 手机号 + 6 位验证码;发送按钮带 retryAfterSeconds 倒计时(后端返回 60s);
 * 用户不存在由后端自动建号(国内 C 端主流模式)。
 */
export default function SmsForm() {
	const t = useTranslations("auth.sms");
	const termsT = useTranslations("auth.terms");
	const { sendCode, submit, countdown, sending, busy, error, setError } =
		useSmsLogin();
	const [phone, setPhone] = useState("");
	const [code, setCode] = useState("");

	const handleSend = async () => {
		if (!phone.trim()) {
			setError(t("errorInvalidPhone"));
			return;
		}
		await sendCode(phone.trim());
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
		await submit(phone.trim(), code.trim());
	};

	return (
		<>
		<form className="auth-form" onSubmit={handleSubmit} noValidate>
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

			<button type="submit" className="auth-submit" disabled={busy}>
				{busy ? t("signingIn") : t("submit")}
			</button>
		</form>
		<p className="auth-terms">
			{termsT("loginAction")}{termsT("agreePrefix")}
			<Link href="/terms">{termsT("serviceTerms")}</Link>
			{termsT("and")}
			<Link href="/privacy">{termsT("privacyPolicy")}</Link>
		</p>
		</>
	);
}
