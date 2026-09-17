import { useState } from "react";
import { useTranslations } from "next-intl";
import { usePaymentErrorTranslator } from "@/lib/payment-errors";
import { useStageTitleFocus } from "./use-reduced-motion";
import type { TodayFormState } from "./write";

/**
 * 寄出 + 注册引导（R11/R27/R29）。
 *
 * 寄出 = 提交「今天的你」（含金句授权）→ sendToWall；成功后展示期望管理
 * 文案（R29「你的这些愿望不会消失」）与一步注册引导——手机验证码
 * find-or-create + 绑定（会话经 httpOnly cookie）；**可跳过**：跳过后同样
 * 寄出成功，凭链接继续回访（R1）。全部 mutation 由父级注入（测试可换桩）。
 */
export default function SendRegister({
	form,
	maskedPhone,
	maskedEmail,
	onSubmitToday,
	onSendToWall,
	onSetQuoteLicense,
	onRegisterBind,
	onRequestPhoneCode,
	onDone,
}: {
	form: TodayFormState;
	maskedPhone?: string | null;
	maskedEmail?: string | null;
	onSubmitToday: (input: TodayFormState) => Promise<boolean>;
	onSendToWall: () => Promise<boolean>;
	onSetQuoteLicense: (form: TodayFormState) => Promise<boolean>;
	onRegisterBind: (phone: string, code: string) => Promise<boolean>;
	onRequestPhoneCode: (phone: string, purpose: "REGISTER" | "CHANGE_PHONE") => Promise<boolean>;
	onDone: () => void;
}) {
	const t = useTranslations("flashback.sendRegister");
	const errorT = usePaymentErrorTranslator();
	const titleRef = useStageTitleFocus<HTMLHeadingElement>([]);

	const [phase, setPhase] = useState<"sending" | "sent" | "registering" | "bound">("sending");
	const [error, setError] = useState<string | null>(null);
	const [phone, setPhone] = useState("");
	const [code, setCode] = useState("");
	const [codeSent, setCodeSent] = useState(false);

	const handleSend = async () => {
		setError(null);
		const todayOk = await onSubmitToday(form);
		if (!todayOk) {
			setError(errorT("flashback_invalid_input", t("errorSend")));
			return;
		}
		if (form.quoteLevel !== "off") {
			await onSetQuoteLicense(form);
		}
		const wallOk = await onSendToWall();
		if (!wallOk) {
			setError(errorT("flashback_invalid_input", t("errorSend")));
			return;
		}
		setPhase("sent");
	};

	const handleRequestCode = async () => {
		setError(null);
		const ok = await onRequestPhoneCode(phone, "REGISTER");
		if (ok) {
			setCodeSent(true);
		} else {
			setError(errorT("invalid_phone", t("errorCode")));
		}
	};

	const handleBind = async () => {
		setError(null);
		const ok = await onRegisterBind(phone, code);
		if (ok) {
			setPhase("bound");
		} else {
			setError(errorT("invalid_or_expired_code", t("errorCode")));
		}
	};

	if (phase === "sending") {
		return (
			<section className="fb-stage fb-stage-pad">
				<h2 className="fb-stage-title" ref={titleRef} tabIndex={-1}>
					{t("title")}
				</h2>
				<p className="fb-lead">{t("lead")}</p>
				<button type="button" className="fb-cta fb-cta-primary" onClick={handleSend}>
					{t("send")}
				</button>
				{error && (
					<p role="alert" className="fb-hint">
						{error}
					</p>
				)}
			</section>
		);
	}

	if (phase === "sent" || phase === "registering") {
		return (
			<section className="fb-stage fb-stage-pad">
				<h2 className="fb-stage-title" ref={titleRef} tabIndex={-1}>
					{t("sentTitle")}
				</h2>
				<p className="fb-promise">{t("promise")}</p>
				<div className="fb-register-card">
					<p className="fb-lead">{t("registerPitch")}</p>
					<p className="fb-hint">
						{t("registerCurrent", {
							phone: maskedPhone ?? t("contactNone"),
							email: maskedEmail ?? t("contactNone"),
						})}
					</p>
					{!codeSent ? (
						<>
							<input
								className="fb-field-input fb-register-input"
								placeholder={t("phonePlaceholder")}
								value={phone}
								onChange={(event) => setPhone(event.target.value)}
								aria-label={t("phonePlaceholder")}
								inputMode="tel"
							/>
							<button type="button" className="fb-cta fb-cta-primary" onClick={handleRequestCode}>
								{t("sendCode")}
							</button>
						</>
					) : (
						<>
							<input
								className="fb-field-input fb-register-input"
								placeholder={t("codePlaceholder")}
								value={code}
								onChange={(event) => setCode(event.target.value)}
								aria-label={t("codePlaceholder")}
								inputMode="numeric"
							/>
							<button type="button" className="fb-cta fb-cta-primary" onClick={handleBind}>
								{t("bind")}
							</button>
						</>
					)}
					{error && (
						<p role="alert" className="fb-hint">
							{error}
						</p>
					)}
					<button type="button" className="fb-cta" onClick={onDone}>
						{t("skip")}
					</button>
					<p className="fb-hint">{t("skipHint")}</p>
				</div>
			</section>
		);
	}

	return (
		<section className="fb-stage fb-stage-pad">
			<h2 className="fb-stage-title" ref={titleRef} tabIndex={-1}>
				{t("boundTitle")}
			</h2>
			<p className="fb-promise">{t("boundNote")}</p>
			<button type="button" className="fb-cta fb-cta-primary" onClick={onDone}>
				{t("enterCapsule")}
			</button>
		</section>
	);
}
