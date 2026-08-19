"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useMutation } from "@apollo/client/react";
import { useRouter } from "next/navigation";
import { useTranslations } from "next-intl";
import { client } from "@/lib/apollo-client";
import {
	graphqlErrorDetails,
	REQUEST_PHONE_CODE,
	SIGN_IN_WITH_PHONE_CODE,
	type PhoneCodePurpose,
} from "@/lib/graphql/auth";
import { resolveNextTarget } from "./use-auth-submit";

/** 浏览器定时器句柄(window.setInterval 返回 number)。 */
type IntervalHandle = number | undefined;

/**
 * 手机验证码登录(plan 002 U3/U5)。
 *
 * - sendCode:requestPhoneCode 发送验证码,成功后按 retryAfterSeconds 进入倒计时;
 *   后端错误 code 经 graphqlErrorDetails 映射 i18n。
 * - submit:signInWithPhoneCode 成功后 resetStore(同 use-auth-submit 先例)
 *   并跳转 next(同源校验);用户不存在由后端自动建号。
 * - 倒计时:1s 递减(payment-checkout-dialog 先例),卸载清理。
 */
export function useSmsLogin() {
	const router = useRouter();
	const t = useTranslations("auth.sms");
	const [error, setError] = useState<string | null>(null);
	const [countdown, setCountdown] = useState(0);
	const timerRef = useRef<IntervalHandle>(undefined);
	const [requestCode, requestState] = useMutation(REQUEST_PHONE_CODE);
	const [signIn, signInState] = useMutation(SIGN_IN_WITH_PHONE_CODE);

	useEffect(() => {
		return () => window.clearInterval(timerRef.current);
	}, []);

	const startCountdown = useCallback((seconds: number) => {
		window.clearInterval(timerRef.current);
		setCountdown(seconds);
		timerRef.current = window.setInterval(() => {
			setCountdown((current) => {
				if (current <= 1) {
					window.clearInterval(timerRef.current);
					timerRef.current = undefined;
					return 0;
				}
				return current - 1;
			});
		}, 1000);
	}, []);

	const sendCode = useCallback(
		async (phone: string, purpose: PhoneCodePurpose = "LOGIN") => {
			setError(null);
			try {
				const { data } = await requestCode({ variables: { phone, purpose } });
				if (data?.requestPhoneCode?.sent) {
					startCountdown(data.requestPhoneCode.retryAfterSeconds);
					return true;
				}
				setError(t("sendFailed"));
				return false;
			} catch (e) {
				setError(smsErrorMessage(e, t));
				return false;
			}
		},
		[requestCode, startCountdown, t],
	);

	const submit = useCallback(
		async (phone: string, code: string) => {
			setError(null);
			try {
				const { data } = await signIn({ variables: { phone, code } });
				if (data?.signInWithPhoneCode?.id) {
					await client.resetStore();
					const nextRaw = new URLSearchParams(window.location.search).get("next");
					router.push(resolveNextTarget(nextRaw, window.location.origin));
					return;
				}
				setError(t("signInFailed"));
			} catch (e) {
				setError(smsErrorMessage(e, t));
			}
		},
		[signIn, router, t],
	);

	return {
		sendCode,
		submit,
		countdown,
		sending: requestState.loading,
		busy: signInState.loading,
		error,
		setError,
	};
}

/** 后端错误 code → i18n 文案;未知错误给网络兜底。 */
export function smsErrorMessage(
	e: unknown,
	t: (key: string) => string,
): string {
	switch (graphqlErrorDetails(e)?.code) {
		case "invalid_phone":
			return t("errorInvalidPhone");
		case "rate_limited":
			return t("errorRateLimited");
		case "invalid_or_expired_code":
			return t("errorInvalidCode");
		case "sms_send_failed":
			return t("sendFailed");
		default:
			return t("signInFailed");
	}
}
