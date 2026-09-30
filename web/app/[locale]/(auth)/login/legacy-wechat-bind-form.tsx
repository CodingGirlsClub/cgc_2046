"use client";

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
import { usePhoneCode, smsErrorMessage } from "@/lib/use-phone-code";

/** Serves existing OAuth bind tickets; ordinary Web registration uses the mini program. */
export default function LegacyWechatBindForm({ bindTicket }: { bindTicket: string }) {
  const router = useRouter();
  const t = useTranslations("auth.sms");
  const bindT = useTranslations("auth.wechatCallback");
  const nextRaw = useSearchParams()?.get("next") ?? null;
  const { sendCode, countdown, sending, error, setError } = usePhoneCode();
  const [bind, bindState] = useMutation(BIND_WECHAT_WITH_PHONE);
  const [phone, setPhone] = useState("");
  const [code, setCode] = useState("");

	const handleSend = async () => {
		if (!phone.trim()) {
			setError(t("errorInvalidPhone"));
			return;
		}
		await sendCode(phone.trim(), "WECHAT_BIND");
	};

	const handleBind = async () => {
		try {
			const { data } = await bind({
				variables: { bindTicket: bindTicket, phone, code },
			});
			if (data?.bindWechatWithPhone?.id) {
				await client.resetStore();
				navigateAfterLogin(router, nextRaw);
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
		await handleBind();
	};

	return (
		<>
		<form className="auth-form" onSubmit={handleSubmit} noValidate>
			<p className="auth-wechat-hint">{bindT("bindHint")}</p>
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

			<button type="submit" className="auth-submit" disabled={bindState.loading}>
        {bindState.loading ? bindT("binding") : bindT("bindSubmit")}
      </button>
    </form>
    </>
  );
}
