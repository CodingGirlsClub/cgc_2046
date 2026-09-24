import { useCallback, useState } from "react";
import { useTranslations } from "next-intl";
import { usePaymentErrorTranslator } from "@/lib/payment-errors";
import {
	sentencesWithFogMark,
	type FlashbackAnswer,
	type FlashbackFogSpan,
} from "@/lib/graphql/flashback";
import { useStageTitleFocus } from "./use-reduced-motion";
import type { TodayFormState } from "./write";

/**
 * 寄出浮层（原型 E/F：覆盖在显影场景上，不换页）+ 注册引导（R11/R27/R29）。
 *
 * 流程：浮层打开先停「检查当年的你」——当年答案逐句列出，本人逐句自选
 * 雾/亮（初始 = enter 载荷 fogSpans，KTD4 本人永远看到完整原文，雾态只作
 * 视觉标记不模糊文字）；点「确认寄出」才把**相对载荷有变化**的雾区间逐条
 * 落库（flashbackAdjustFog，任一失败即中止寄出——此刻尚未上墙，retry 整段
 * 重来无副作用），全部成功后才按原序列寄出（submitToday → setQuoteLicense
 * （非 off）→ sendToWall），保证卡上墙第一眼的对外可见状态就是用户的选择。
 * 寄出成功后原地转为一步注册引导——手机验证码 find-or-create + 绑定（会话经
 * httpOnly cookie），**可跳过**：跳过后同样寄出成功，凭链接继续回访（R1）。
 * 失败给「再试一次」（可重试）；检查步「再想想」返回写字面，零 mutation。
 *
 * 全部 mutation 由父级注入（测试可换桩）。
 */
export default function SendRegister({
	form,
	answers,
	maskedPhone,
	maskedEmail,
	onSubmitToday,
	onSendToWall,
	onSetQuoteLicense,
	onAdjustFog,
	onRegisterBind,
	onRequestPhoneCode,
	onBack,
	onDone,
}: {
	form: TodayFormState;
	/** 当年答案（enter 载荷；检查步逐句列出的数据源） */
	answers: FlashbackAnswer[];
	maskedPhone?: string | null;
	maskedEmail?: string | null;
	onSubmitToday: (input: TodayFormState) => Promise<boolean>;
	onSendToWall: () => Promise<boolean>;
	onSetQuoteLicense: (form: TodayFormState) => Promise<boolean>;
	onAdjustFog: (answerId: string, spans: FlashbackFogSpan[]) => Promise<boolean>;
	onRegisterBind: (phone: string, code: string) => Promise<boolean>;
	onRequestPhoneCode: (phone: string, purpose: "REGISTER" | "CHANGE_PHONE") => Promise<boolean>;
	/** 「再想想」出口：返回写字面（关浮层），不触发任何 mutation */
	onBack: () => void;
	onDone: () => void;
}) {
	const t = useTranslations("flashback.sendRegister");
	const questionT = useTranslations("flashback.questionLabels");
	const errorT = usePaymentErrorTranslator();
	const titleRef = useStageTitleFocus<HTMLHeadingElement>([]);

	const [phase, setPhase] = useState<"review" | "sending" | "sent" | "failed" | "bound">("review");
	const [error, setError] = useState<string | null>(null);
	const [phone, setPhone] = useState("");
	const [code, setCode] = useState("");
	const [codeSent, setCodeSent] = useState(false);
	/** 检查步逐句雾选（answerId → spans；初始 = enter 载荷 fogSpans） */
	const [spansByAnswer, setSpansByAnswer] = useState<Record<string, FlashbackFogSpan[]>>(() =>
		Object.fromEntries(answers.map((answer) => [answer.id, [...(answer.fogSpans ?? [])]])),
	);

	const toggleSentence = (answerId: string, sentence: { start: number; len: number }) => {
		setSpansByAnswer((prev) => {
			const current = prev[answerId] ?? [];
			// 句与区间交界即视为雾（与 sentencesWithFogMark 的命中口径一致）
			const intersects = (span: { start: number; len: number }) =>
				span.start < sentence.start + sentence.len && sentence.start < span.start + span.len;
			const fogged = current.some(intersects);
			const rest = current.filter((span) => !intersects(span));
			return {
				...prev,
				[answerId]: fogged ? rest : [...rest, { start: sentence.start, len: sentence.len }],
			};
		});
	};

	/** 寄出（「确认寄出」与失败重试共用）：先把变化的雾区间落库再上墙 */
	const handleSend = useCallback(async () => {
		for (const answer of answers) {
			const next = normalizeSpans(spansByAnswer[answer.id]);
			if (sameSpans(next, normalizeSpans(answer.fogSpans))) continue;
			const fogOk = await onAdjustFog(answer.id, next);
			if (!fogOk) {
				setError(t("errorFog"));
				setPhase("failed");
				return;
			}
		}
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
	}, [answers, spansByAnswer, onAdjustFog, errorT, form, onSubmitToday, onSendToWall, onSetQuoteLicense, t]);

	const handleConfirm = () => {
		setError(null);
		setPhase("sending");
		void handleSend();
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

	const errorLine = error ? (
		<p role="alert" className="fb-hint">
			{error}
		</p>
	) : null;

	if (phase === "review") {
		return (
			<div className="fb-send-step">
				<h2 className="fb-send-title" id="fb-send-title" ref={titleRef} tabIndex={-1}>
					{t("reviewTitle")}
				</h2>
				<p className="fb-lead">{t("reviewLead")}</p>
				<div className="fb-review">
					{answers.map((answer) => (
						<div key={answer.id} className="fb-review-answer">
							<p className="fb-review-question">
								{questionT.has(answer.questionKey) ? questionT(answer.questionKey) : answer.questionKey}
							</p>
							<div className="fb-review-sentences">
								{sentencesWithFogMark(answer.rawText, spansByAnswer[answer.id]).map((sentence) => (
									<button
										key={sentence.start}
										type="button"
										className={`fb-review-sentence${sentence.fogged ? " fb-review-sentence--fog" : ""}`}
										aria-pressed={sentence.fogged}
										onClick={() => toggleSentence(answer.id, sentence)}
									>
										<span className="fb-review-sentence-text">{sentence.text}</span>
										{sentence.fogged && (
											<span className="fb-review-fog-badge" aria-hidden="true">
												{t("fogBadge")}
											</span>
										)}
									</button>
								))}
							</div>
						</div>
					))}
				</div>
				<button type="button" className="fb-cta fb-cta-primary" onClick={handleConfirm}>
					{t("confirmSend")}
				</button>
				<button type="button" className="fb-cta" onClick={onBack}>
					{t("thinkMore")}
				</button>
			</div>
		);
	}

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

/** 雾区间归一（比较/落库前）：丢非法、按 start/len 排序；reason 是导入元数据，不参与比较 */
function normalizeSpans(spans: FlashbackFogSpan[] | null | undefined): FlashbackFogSpan[] {
	return [...(spans ?? [])]
		.filter((s) => Number.isInteger(s.start) && Number.isInteger(s.len) && s.start >= 0 && s.len > 0)
		.sort((a, b) => a.start - b.start || a.len - b.len);
}

function sameSpans(a: FlashbackFogSpan[], b: FlashbackFogSpan[]): boolean {
	return a.length === b.length && a.every((s, i) => s.start === b[i].start && s.len === b[i].len);
}

