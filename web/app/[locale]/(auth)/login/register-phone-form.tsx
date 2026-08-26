"use client";

import { useState, type FormEvent } from "react";
import { useMutation } from "@apollo/client/react";
import { useRouter, useSearchParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import { client } from "@/lib/apollo-client";
import { SIGN_UP_WITH_PHONE, graphqlErrorDetails } from "@/lib/graphql/auth";
import { navigateAfterLogin } from "./use-auth-submit";
import { useSmsLogin } from "./use-sms-login";
import { PasswordField, PasswordStrength } from "./auth-form";

/**
 * 手机号注册表单（/register 邮箱 → 手机号）。
 *
 * 手机号 + 短信验证码（purpose REGISTER）+ 密码（确认 + 强度条，复用
 * auth-form 导出的 PasswordField/PasswordStrength）。提交走
 * signUpWithPhone：验码 → 已注册提示直接登录 → 建号自动登录跳 next。
 */
export default function RegisterPhoneForm() {
	const router = useRouter();
	const searchParams = useSearchParams();
	// next 单源（kimi 评审 #2）：useSearchParams 取代渲染期读 window——
	// SSR 期 window undefined 会导致 href hydration mismatch。
	const nextRaw = searchParams?.get("next") ?? null;
	const t = useTranslations("auth.sms");
	const errT = useTranslations("auth");
	const errorsT = useTranslations("auth.errors");
	const termsT = useTranslations("auth.terms");
	const { sendCode, countdown, sending, error: sendError, setError: setSendError } =
		useSmsLogin();
	const [signUp, signUpState] = useMutation(SIGN_UP_WITH_PHONE);
	const [phone, setPhone] = useState("");
	const [code, setCode] = useState("");
	const [password, setPassword] = useState("");
	const [confirmPassword, setConfirmPassword] = useState("");
	const [showPassword, setShowPassword] = useState(false);
	const [showConfirmPassword, setShowConfirmPassword] = useState(false);
	const [error, setError] = useState<string | null>(null);
	// 发码失败（限流/非法手机号/短信投递）与提交错误共用同一 alert
	const displayError = error ?? sendError;

	const handleSend = async () => {
		if (!phone.trim()) {
			setError(t("errorInvalidPhone"));
			return;
		}
		setError(null);
		setSendError(null);
		await sendCode(phone.trim(), "REGISTER");
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
		// 字节长度（8..72）与后端 validate_register_password 对齐——bcrypt 上限
		// 72 字节，UTF-16 码元数会漏判多字节密码（kimi 评审 #3/#6）
		const passwordBytes = new TextEncoder().encode(password).length;
		if (passwordBytes < 8 || passwordBytes > 72) {
			setError(errT("error.invalidPasswordLength"));
			return;
		}
		if (password !== confirmPassword) {
			setError(errT("error.passwordMismatch"));
			return;
		}

		try {
			const { data } = await signUp({
				variables: {
					input: { phone: phone.trim(), code: code.trim(), password },
				},
			});
			if (data?.signUpWithPhone?.result) {
				await client.resetStore();
				navigateAfterLogin(router, nextRaw);
				return;
			}
			// result null + errors：registration_failed 等，重试提示
			setError(errorsT("registerFailedRetry"));
		} catch (e) {
			// 抛错路径：phone_already_registered / invalid_or_expired_code / rate_limited
			const errorCode = graphqlErrorDetails(e)?.code ?? null;
			if (errorCode === "phone_already_registered") {
				setError(errorsT("phoneAlreadyRegistered"));
				return;
			}
			if (errorCode === "invalid_or_expired_code") {
				setError(t("errorInvalidCode"));
				return;
			}
			if (errorCode === "rate_limited") {
				setError(t("errorRateLimited"));
				return;
			}
			if (errorCode === "invalid_password") {
				setError(errT("error.invalidPasswordLength"));
				return;
			}
			setError(errorsT("registerFailedRetry"));
		}
	};

	return (
		<div className="auth-form-body">
			<form className="auth-form" onSubmit={handleSubmit} noValidate>
				{displayError && (
					<div role="alert" className="auth-alert">
						{displayError}
					</div>
				)}

				<div className="auth-field">
					<input
						id="register-phone"
						name="phone"
						className="auth-input"
						type="tel"
						placeholder={t("placeholderPhone")}
						value={phone}
						onChange={(event) => {
							setPhone(event.target.value);
							setError(null);
							setSendError(null);
						}}
						autoComplete="tel"
						autoFocus
						required
					/>
				</div>

				<div className="auth-field">
					<div className="auth-sms-code-row">
						<input
							id="register-phone-code"
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
							disabled={sending || countdown > 0 || !phone.trim()}
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

				<div className="auth-field">
					<PasswordField
						id="register-password"
						placeholder={errT("placeholder.password")}
						value={password}
						onChange={(value) => {
							setPassword(value);
							setError(null);
						}}
						visible={showPassword}
						onToggle={() => setShowPassword((current) => !current)}
						autoComplete="new-password"
					/>
					<PasswordStrength password={password} />
				</div>

				<div className="auth-field">
					<PasswordField
						id="register-confirm-password"
						placeholder={errT("placeholder.confirmPassword")}
						value={confirmPassword}
						onChange={(value) => {
							setConfirmPassword(value);
							setError(null);
						}}
						visible={showConfirmPassword}
						onToggle={() => setShowConfirmPassword((current) => !current)}
						autoComplete="new-password"
					/>
				</div>

				<button
					type="submit"
					className="auth-submit"
					disabled={signUpState.loading}
					aria-busy={signUpState.loading}
				>
					{signUpState.loading
						? errT("submit.processing")
						: errT("submit.registerAndContinue")}
				</button>
			</form>
			<p className="auth-switch">
				<span aria-hidden="true" />
				<Link
					href={nextRaw ? `/login?next=${encodeURIComponent(nextRaw)}` : "/login"}
					className="auth-inline-link auth-switch__action"
				>
					{errT("switch.returnLogin")}
				</Link>
			</p>
			<p className="auth-terms">
				{termsT("registerAction")}{termsT("agreePrefix")}
				<Link href="/terms">{termsT("serviceTerms")}</Link>
				{termsT("and")}
				<Link href="/privacy">{termsT("privacyPolicy")}</Link>
			</p>
		</div>
	);
}
