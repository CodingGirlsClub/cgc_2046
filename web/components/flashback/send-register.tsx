import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { usePaymentErrorTranslator } from "@/lib/payment-errors";
import { useStageTitleFocus } from "./use-reduced-motion";
import type { TodayFormState } from "./write";

/**
 * 寄出浮层（原型 E/F：覆盖在显影场景上，不换页）+ 注册引导（R11/R27/R29）。
 *
 * 流程：浮层打开即自动寄出（submitToday → setQuoteLicense → sendToWall），
 * 标题「照片正在贴上墙。」是过程陈述；成功后原地转为一步注册引导——
 * 手机验证码 find-or-create + 绑定（会话经 httpOnly cookie），**可跳过**：
 * 跳过后同样寄出成功，凭链接继续回访（R1）。失败给「再试一次」（可重试）。
 *
 * 全部 mutation 由父级注入（测试可换桩）。
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

	const [phase, setPhase] = useState<"sending" | "sent" | "failed" | "bound">("sending");
	const [error, setError] = useState<string | null>(null);
	const [phone, setPhone] = useState("");
	const [code, setCode] = useState("");
	const [codeSent, setCodeSent] = useState(false);

	/** 寄出（effect 首跑与「再试一次」共用）：首个语句即 await——effect 内不
	 *  同步 setState（react-hooks/set-state-in-effect），失败/成功态都在 await 之后落 */
	const handleSend = useCallback(async () => {
		const todayOk = await onSubmitToday(form);
		if (!todayOk) {
			setError(errorT("flashback_invalid_input", t("errorSend")));
			setPhase("failed");
			return;
		}
		if (form.quoteLevel !== "off") {
			await onSetQuoteLicense(form);
		}
		const wallOk = await onSendToWall();
		if (!wallOk) {
			setError(errorT("flashback_invalid_input", t("errorSend")));
			setPhase("failed");
			return;
		}
		setPhase("sent");
	}, [errorT, form, onSubmitToday, onSendToWall, onSetQuoteLicense, t]);

	// 浮层打开即寄出（原型 E/F：照片正在贴上墙——过程陈述，不需要再点一次）。
	// timer 0 起跑：setState 落在 effect 同步栈之外（同 journey.tsx 的既有先例，
	// 规避 react-hooks/set-state-in-effect 的级联渲染告警）。
	useEffect(() => {
		const timer = window.setTimeout(() => void handleSend(), 0);
		return () => window.clearTimeout(timer);
		// eslint-disable-next-line react-hooks/exhaustive-deps -- 浮层打开一次性寄出
	}, []);

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

	const errorLine = error ? (
		<p role="alert" className="fb-hint">
			{error}
		</p>
	) : null;

	if (phase === "bound") {
		return (
			<div className="fb-send-step">
				<h2 className="fb-send-title" id="fb-send-title" ref={titleRef} tabIndex={-1}>
					{t("boundTitle")}
				</h2>
				<p className="fb-promise">{t("boundNote")}</p>
				<button type="button" className="fb-cta fb-cta-primary" onClick={onDone}>
					{t("enterCapsule")}
				</button>
			</div>
		);
	}

	if (phase === "failed") {
		return (
			<div className="fb-send-step">
				<h2 className="fb-send-title" id="fb-send-title" ref={titleRef} tabIndex={-1}>
					{t("failedTitle")}
				</h2>
				{errorLine}
				<button
					type="button"
					className="fb-cta fb-cta-primary"
					onClick={() => {
						setError(null);
						setPhase("sending");
						void handleSend();
					}}
				>
					{t("retry")}
				</button>
			</div>
		);
	}

	return (
		<div className="fb-send-step">
			<h2 className="fb-send-title" id="fb-send-title" ref={titleRef} tabIndex={-1}>
				{t("title")}
			</h2>

			{phase === "sending" ? (
				<p className="fb-lead" role="status">
					{t("lead")}
				</p>
			) : (
				<>
					{/* 期望管理（R29）：愿望不会消失 */}
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
						{errorLine}
						<button type="button" className="fb-cta" onClick={onDone}>
							{t("skip")}
						</button>
						<p className="fb-hint">{t("skipHint")}</p>
					</div>
				</>
			)}
		</div>
	);
}
