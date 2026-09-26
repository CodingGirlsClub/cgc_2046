import { useCallback, useState } from "react";
import { useTranslations } from "next-intl";
import { usePaymentErrorTranslator } from "@/lib/payment-errors";
import { graphqlErrorDetails } from "@/lib/graphql/auth";
import {
	sentencesWithFogMark,
	TODAY_FIELDS,
	type FlashbackAnswer,
	type FlashbackFogSpan,
} from "@/lib/graphql/flashback";
import { normalizeSpans, sameSpans, toggleSpanIn } from "./fog-toggle";
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
	initialTodayFogSpans,
	maskedPhone,
	maskedEmail,
	onSubmitToday,
	onSendToWall,
	onSetQuoteLicense,
	onAdjustFog,
	onAdjustTodayFog,
	onRegisterBind,
	onRequestPhoneCode,
	onBack,
	onDone,
}: {
	form: TodayFormState;
	/** 当年答案（enter 载荷；检查步逐句列出的数据源） */
	answers: FlashbackAnswer[];
	/** 服务端既有 today 雾区间（enter 载荷；预填 review 的初始雾态——盲初值闭环；null/缺省从空起步） */
	initialTodayFogSpans?: Record<string, FlashbackFogSpan[]> | null;
	maskedPhone?: string | null;
	maskedEmail?: string | null;
	onSubmitToday: (input: TodayFormState) => Promise<boolean>;
	onSendToWall: () => Promise<boolean>;
	onSetQuoteLicense: (form: TodayFormState) => Promise<boolean>;
	onAdjustFog: (answerId: string, spans: FlashbackFogSpan[]) => Promise<boolean>;
	/** today 字段（now/want/need/say）句级雾面落库（U9 双入口：末段寄出必须按服务端最新文本校验） */
	onAdjustTodayFog: (field: string, spans: FlashbackFogSpan[]) => Promise<boolean>;
	onRegisterBind: (phone: string, code: string) => Promise<boolean>;
	onRequestPhoneCode: (phone: string, purpose: "REGISTER" | "CHANGE_PHONE") => Promise<boolean>;
	/** 「再想想」出口：返回写字面（关浮层），不触发任何 mutation */
	onBack: () => void;
	onDone: () => void;
}) {
	const t = useTranslations("flashback.sendRegister");
	const questionT = useTranslations("flashback.questionLabels");
	const writeT = useTranslations("flashback.write");
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

	/** today 字段逐句雾选（fog 字段名 → spans；初始 = 服务端既有雾（盲初值闭环）——
	 * 不预填会让「用户在小程序已设的雾」在 Web 走查里隐形，且脏检查无可比基线 */
	const [spansByField, setSpansByField] = useState<Record<string, FlashbackFogSpan[]>>(() =>
		Object.fromEntries(
			TODAY_FIELDS.map((host) => [host.fog, [...(initialTodayFogSpans?.[host.fog] ?? [])]]),
		),
	);
	// 脏比对直接以 initialTodayFogSpans prop 为基线：闪层期间服务端基线不变

	const toggleSentence = (answerId: string, sentence: { start: number; len: number }) =>
		setSpansByAnswer((prev) => toggleSpanIn(prev, answerId, sentence));

	const toggleTodaySentence = (fog: string, sentence: { start: number; len: number }) =>
		setSpansByField((prev) => toggleSpanIn(prev, fog, sentence));

	const todayLabelOf = (field: (typeof TODAY_FIELDS)[number]["field"]): string => {
		switch (field) {
			case "nowStatus":
				return writeT("nowLabel");
			case "want":
				return writeT("wantLabel");
			case "need":
				return writeT("needLabel");
			case "say":
				return writeT("sayLabel");
		}
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
		// today 雾面必须落在新文本之后（adjustTodayFog 按服务端当前文本校验区间）；
		// 脏检查与服务端基线比对：未变化不发无谓 mutation，全部切回亮必须显式发出（清雾）
		for (const host of TODAY_FIELDS) {
			const next = normalizeSpans(spansByField[host.fog]);
			if (sameSpans(next, normalizeSpans(initialTodayFogSpans?.[host.fog]))) continue;
			const fogOk = await onAdjustTodayFog(host.fog, next);
			if (!fogOk) {
				setError(t("errorTodayFog"));
				setPhase("failed");
				return;
			}
		}
		if (form.quoteLevel !== "off") {
			// 授权失败同样暂停寄出（D3 历史静默吞：用户以为已授权、卡照样上墙）
			const licenseOk = await onSetQuoteLicense(form);
			if (!licenseOk) {
				setError(t("errorLicense"));
				setPhase("failed");
				return;
			}
		}
		const wallOk = await onSendToWall();
		if (!wallOk) {
			setError(errorT("flashback_invalid_input", t("errorSend")));
			setPhase("failed");
			return;
		}
		setPhase("sent");
	}, [answers, initialTodayFogSpans, spansByAnswer, spansByField, onAdjustFog, onAdjustTodayFog, errorT, form, onSubmitToday, onSendToWall, onSetQuoteLicense, t]);

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
		try {
			const ok = await onRegisterBind(phone, code);
			if (ok) {
				setPhase("bound");
			} else {
				setError(errorT("invalid_or_expired_code", t("errorCode")));
			}
		} catch (err) {
			// mutation 被拒会抛错：按服务端 code 提示（验证码错 / 这张卡已属于另一个账号 / 限流…）
			setError(errorT(graphqlErrorDetails(err)?.code ?? "invalid_or_expired_code", t("errorCode")));
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
				{TODAY_FIELDS.some((host) => form[host.field]) && (
					<>
						<p className="fb-lead">{t("reviewTodayTitle")}</p>
						<div className="fb-review">
							{TODAY_FIELDS.map((host) =>
								form[host.field] ? (
									<div key={host.fog} className="fb-review-answer">
										<p className="fb-review-question">{todayLabelOf(host.field)}</p>
										<div className="fb-review-sentences">
											{sentencesWithFogMark(
												form[host.field] ?? "",
												spansByField[host.fog],
											).map((sentence) => (
												<button
													key={sentence.start}
													type="button"
													className={`fb-review-sentence${sentence.fogged ? " fb-review-sentence--fog" : ""}`}
													aria-pressed={sentence.fogged}
													onClick={() => toggleTodaySentence(host.fog, sentence)}
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
								) : null,
							)}
						</div>
					</>
				)}
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
				{/* sent 态标题就是完成时——不再用「照片正在贴上墙。」谎报状态（sentTitle 原是孤儿文案） */}
				{phase === "sent" ? t("sentTitle") : t("title")}
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
