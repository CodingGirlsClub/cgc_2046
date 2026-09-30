import { useCallback, useState } from "react";
import { useAuthed } from "@/lib/auth-provider";
import { Link } from "@/i18n/navigation";
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
import { currentSuggestion, nextSuggestion, quoteSuggestions, type QuoteSuggestion } from "./quote-suggestion";
import { useStageTitleFocus } from "./use-reduced-motion";
import type { TodayFormState } from "./write";

type QuotePick = Pick<QuoteSuggestion, "questionKey" | "start" | "len">;

/**
 * 寄出浮层（原型 E/F：覆盖在显影场景上，不换页）+ 注册引导（R11/R27/R29）。
 *
 * 流程：浮层打开先停「检查当年的你」——当年答案逐句列出，本人逐句自选
 * 雾/亮（初始 = enter 载荷 fogSpans，KTD4 本人永远看到完整原文，雾态只作
 * 视觉标记不模糊文字）；点「确认寄出」才把**相对载荷有变化**的雾区间逐条
 * 落库（flashbackAdjustFog，任一失败即中止寄出——此刻尚未上墙，retry 整段
 * 重来无副作用），全部成功后才按原序列寄出（submitToday → setQuoteLicense
 * （选了放句时）→ sendToWall），保证卡上墙第一眼的对外可见状态就是用户的选择。
 *
 * 金句授权在寄出这一刻明确地问（#1022，单独同意）：未授权且有推荐句时，
 * 预览这句 + 墙上署名，两个同分量按钮「寄出，并把这句匿名放进金句墙」/
 * 「寄出到相册」，永不预选；已开授权档则不再询问、也不改档。
 * 寄出成功后原地转为一步注册引导——手机验证码 find-or-create + 绑定（会话经
 * httpOnly cookie），**可跳过**：跳过后同样寄出成功，凭链接继续回访（R1）。
 * 失败给「再试一次」（可重试）；检查步「再想想」返回写字面，零 mutation。
 *
 * 全部 mutation 由父级注入（测试可换桩）。
 */
export default function SendRegister({
	form,
	answers,
	fullName,
	surname,
	anonymousAttribution,
	quoteLevel,
	hasSelectedQuotes = false,
	initialTodayFogSpans,
	maskedPhone,
	maskedEmail,
	bound = false,
	onClaim,
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
	/** 本人姓名（推荐句排除含全名/名的句子，防匿名被自己的名字戳破） */
	fullName: string;
	surname?: string | null;
	/** 墙上匿名署名（后端单源，与上墙后逐字一致） */
	anonymousAttribution: string;
	/** 只有开档且已选句才跳过；零句仍需完成明确选句。 */
	quoteLevel: string;
	hasSelectedQuotes?: boolean;
	/** 服务端既有 today 雾区间（enter 载荷；预填 review 的初始雾态——盲初值闭环；null/缺省从空起步） */
	initialTodayFogSpans?: Record<string, FlashbackFogSpan[]> | null;
	maskedPhone?: string | null;
	maskedEmail?: string | null;
	bound?: boolean;
	onClaim: () => Promise<boolean>;
	onSubmitToday: (input: TodayFormState) => Promise<boolean>;
	onSendToWall: () => Promise<boolean>;
	/** 匿名档 + 这一句（寄出时的授权只有匿名一档；实名在长廊授权面板改） */
	onSetQuoteLicense: (picks: QuotePick[]) => Promise<boolean>;
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
	const { authed, confirmed } = useAuthed();
	const [claiming, setClaiming] = useState(false);
	const questionT = useTranslations("flashback.questionLabels");
	const writeT = useTranslations("flashback.write");
	const errorT = usePaymentErrorTranslator();
	const titleRef = useStageTitleFocus<HTMLHeadingElement>([]);

	const [phase, setPhase] = useState<"review" | "sending" | "sent" | "failed" | "bound">("review");
	const [error, setError] = useState<string | null>(null);
	/** PR #960 评审 2：登录链接只属于「收好动作被拒（卡属于别的账号）」的分支 */
	const [errorShowLogin, setErrorShowLogin] = useState(false);
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

	/** 推荐句随检查页雾态实时重算；已开授权档且已选句不再询问（空候选 = 单按钮寄出） */
	const suggestions =
		(quoteLevel === "off" || !hasSelectedQuotes) ? quoteSuggestions(answers, spansByAnswer, fullName, surname) : [];
	const [chosen, setChosen] = useState<QuoteSuggestion | null>(null);
	const suggestion = currentSuggestion(suggestions, chosen);
	/** 本次寄出带的那句（确认时定格，失败重试沿用；null = 只寄出到相册） */
	const [sendingQuote, setSendingQuote] = useState<QuotePick | null>(null);

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

	/** 寄出（确认与失败重试共用）：先把变化的雾区间落库再上墙；quote 非空则先授权这一句 */
	const handleSend = useCallback(async (quote: QuotePick | null) => {
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
		if (quote) {
			// 授权失败同样暂停寄出（D3 历史静默吞：用户以为已授权、卡照样上墙）
			const licenseOk = await onSetQuoteLicense([quote]);
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

	const handleConfirm = (quote: QuoteSuggestion | null) => {
		const pick = quote && { questionKey: quote.questionKey, start: quote.start, len: quote.len };
		setSendingQuote(pick);
		setError(null);
		setErrorShowLogin(false);
		setPhase("sending");
		void handleSend(pick);
	};

	const handleRequestCode = async () => {
		setError(null);
		setErrorShowLogin(false);
		const ok = await onRequestPhoneCode(phone, "REGISTER");
		if (ok) {
			setCodeSent(true);
		} else {
			setError(errorT("invalid_phone", t("errorCode")));
		}
	};

	const handleBind = async () => {
		setError(null);
		setErrorShowLogin(false);
		try {
			const ok = await onRegisterBind(phone, code);
			if (ok) {
				setPhase("bound");
			} else {
				setError(errorT("invalid_or_expired_code", t("errorCode")));
			}
		} catch (err) {
			// mutation 被拒会抛错：按服务端 code 提示（验证码错 / 这张卡已属于另一个账号 / 限流…）
			const code = graphqlErrorDetails(err)?.code ?? "invalid_or_expired_code";
			setError(errorT(code, t("errorCode")));
			// 卡属于别的账号：下一步是去登录那个账号；验证码错误只重试
			setErrorShowLogin(code === "flashback_recover_account_conflict");
		}
	};

	const handleClaim = async () => {
		if (claiming) return;
		setClaiming(true);
		setError(null);
		setErrorShowLogin(false);
		try {
			if (await onClaim()) setPhase("bound");
			else setError(t("claimFailed"));
		} catch (err) {
			const code = graphqlErrorDetails(err)?.code ?? "flashback_invalid_input";
			setError(errorT(code, t("claimFailed")));
			// 卡属于别的账号：下一步是去登录那个账号
			setErrorShowLogin(code === "flashback_recover_account_conflict");
		} finally {
			setClaiming(false);
		}
	};

	const errorLine = error ? (
		<div role="alert" className="fb-error">
			<p>{error}</p>
			{errorShowLogin && <Link href="/login?next=%2Fflashback%2Fcapsule">{t("login")}</Link>}
		</div>
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
				{suggestion ? (
					<>
						{/* 与金句墙同一张卡（样式同源）：所见即所得 */}
						<figure className="fb-quote-item fb-quote-choice" data-testid="fb-quote-choice">
							<figcaption className="fb-quote-cite">{t("quoteChoiceTitle")}</figcaption>
							<blockquote className="fb-quote-text">{`「${suggestion.sentence}」`}</blockquote>
							<div className="fb-quote-choice-meta">
								<cite className="fb-quote-cite">{anonymousAttribution}</cite>
								{suggestions.length > 1 && (
									<button
										type="button"
										className="fb-quote-like"
										onClick={() => setChosen(nextSuggestion(suggestions, suggestion))}
									>
										{t("quoteShuffle")}
									</button>
								)}
							</div>
						</figure>
						{/* 单独同意：两按钮同分量（同样式、同宽），永不预选 */}
						<div className="fb-quote-choice-actions">
							<button type="button" className="fb-cta fb-cta-primary" onClick={() => handleConfirm(suggestion)}>
								{t("confirmSendWithQuote")}
							</button>
							<button type="button" className="fb-cta fb-cta-primary" onClick={() => handleConfirm(null)}>
								{t("confirmSendAlbumOnly")}
							</button>
						</div>
						<p className="fb-hint">{t("quoteChoiceNote")}</p>
					</>
				) : (
					<button type="button" className="fb-cta fb-cta-primary" onClick={() => handleConfirm(null)}>
						{t("confirmSend")}
					</button>
				)}
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
		setErrorShowLogin(false);
						setPhase("sending");
						void handleSend(sendingQuote);
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
					{/* 授权在寄出之前落库，走到 sent 即已上墙 */}
					{sendingQuote && (
						<p className="fb-promise">
							{t("sentWithQuote")} <Link href="/flashback/voices">{t("voicesLink")}</Link>
						</p>
					)}
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
						{bound ? (
							<>
								<p>{t("alreadyKept")}</p>
								<Link href={confirmed && authed ? "/flashback/capsule" : "/login?next=%2Fflashback%2Fcapsule"}>{t(confirmed && authed ? "enterCapsule" : "login")}</Link>
							</>
						) : !confirmed ? (
							<p role="status">{t("checkingAccount")}</p>
						) : authed ? (
							<button type="button" className="fb-cta fb-cta-primary" disabled={claiming} onClick={handleClaim}>{t(claiming ? "claiming" : "claim")}</button>
						) : !codeSent ? (
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
