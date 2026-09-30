"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useMutation } from "@apollo/client/react";
import { useTranslations } from "next-intl";
import {
	graphqlErrorDetails,
	REQUEST_PHONE_CODE,
} from "@/lib/graphql/auth";

/** 浏览器定时器句柄(window.setInterval 返回 number)。 */
type IntervalHandle = number | undefined;

/** Shared code delivery for phone changes and live legacy WeChat bindings; no sign-in side effects. */
export function usePhoneCode() {
	const t = useTranslations("auth.sms");
	const [error, setError] = useState<string | null>(null);
	const [countdown, setCountdown] = useState(0);
	const timerRef = useRef<IntervalHandle>(undefined);
	const [requestCode, requestState] = useMutation(REQUEST_PHONE_CODE);

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
		async (phone: string, purpose: "WECHAT_BIND" | "CHANGE_PHONE") => {
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

	return {
		sendCode,
		countdown,
		sending: requestState.loading,
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
