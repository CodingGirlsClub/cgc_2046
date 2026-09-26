"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslations, useLocale } from "next-intl";
import { Link } from "@/i18n/navigation";
import {
	appliedStamp,
	scatterLabelOf,
	yearsAgo,
	type FlashbackAnswer,
	type FlashbackDreamTarget,
	type FlashbackProfile,
	type FlashbackProgress,
} from "@/lib/graphql/flashback";
import { FogText } from "./fog-text";
import Write, { type TodayFormState } from "./write";
import { useCardFlip } from "./use-card-flip";
import { usePrefersReducedMotion, useStageTitleFocus, useOnceCallback } from "./use-reduced-motion";

/** 自由文本题（R7「实际存在的题」）：PII 行（full_name/phone/email）不进正面 */
const FREE_TEXT_KEYS = ["self_intro", "funny_thing", "os", "social_media"] as const;

/**
 * 拍立得显影（R7）：中速显影（1.2s——全流程唯一的慢时刻留给「认出自己」），
 * 显影完成写 revealed 行为事件（四时刻之二，由父级 onRevealed 落 mutation）。
 * reduced-motion：跳过显影直达终态（CSS 变量归零 + 立即 onRevealed）。
 *
 * 第 3 件（原型 E「点击照片翻面写字」）：卡面点击 / CTA → 两段式 3D 翻面，
 * 背面即「今天的你」表单（原独立写字阶段并入本卡背面）——语义不变：背面提交后
 * 由父级进寄出阶段（onWriteNext）。翻回正面用同一容器反向翻。
 *
 * 圆梦线（dream）同屏展示 1024 圆梦 CTA 两态（R9）：本城有已发布场次直链
 * Event 报名页；无则落 Initiative 公开页 + 兜底出口（写字寄出留联系方式）。
 * CTA 只在正面（背面是书写面）。
 */
export default function Reveal({
	profile,
	line,
	dreamTarget,
	quizChoice,
	startOnBack = false,
	onRevealed,
	role,
	answers,
	progress,
	onWriteNext,
}: {
	profile: FlashbackProfile;
	line: "memory" | "dream";
	dreamTarget: FlashbackDreamTarget | null;
	quizChoice: "correct" | "wrong" | "dunno" | null;
	/** 回访（AE9）：已填今天但未寄出 → 直接落在背面书写面 */
	startOnBack?: boolean;
	onRevealed: () => void;
	role: string;
	answers: FlashbackAnswer[];
	progress: FlashbackProgress;
	onWriteNext: (form: TodayFormState) => void;
}) {
	const t = useTranslations("flashback.reveal");
	const questionT = useTranslations("flashback.questionLabels");
	// yearsAgo 单源在 intro namespace（两线开场共用同一句相对年数文案）
	const introT = useTranslations("flashback.intro");
	const reduced = usePrefersReducedMotion();
	const titleRef = useStageTitleFocus<HTMLHeadingElement>([line]);
	const locale = useLocale();
	const notifyRevealed = useOnceCallback(onRevealed);
	const { face, phase, flip } = useCardFlip(startOnBack ? "back" : "front", reduced);
	/** 显影只跑一次：翻回正面不重播（重播会把「唯一的慢时刻」变成噪声）；
	 *  reduced-motion 直接在渲染期取终态（不在 effect 里 setState） */
	const [animationDone, setAnimationDone] = useState(false);
	const developed = reduced || animationDone;

	const handleDeveloped = useCallback(() => {
		setAnimationDone(true);
		notifyRevealed();
	}, [notifyRevealed]);

	// reduced-motion：不等待动画即记 revealed（ref 防重，零 setState）
	useEffect(() => {
		if (reduced) notifyRevealed();
	}, [reduced, notifyRevealed]);

	const years = yearsAgo(profile.appliedAt);
	const stamp = appliedStamp(profile.appliedAt);
	const clock = profile.appliedAt
		? new Date(profile.appliedAt).toLocaleTimeString(locale, {
				hour: "2-digit",
				minute: "2-digit",
		  })
		: null;
	const whenText = stamp
		? t("wroteAt", {
				years: introT("yearsAgo", { years }),
				date: stamp,
				time: clock ?? "",
			})
		: t("wroteAtUnknown");

	const archiveName = profile.archive?.name ?? "";
	const feedback =
		quizChoice === "dunno"
			? t("dunnoFeedback", { event: archiveName })
			: quizChoice === "correct"
				? t("correctFeedback")
				: quizChoice === "wrong"
					? t("wrongFeedback", { label: scatterLabelOf(profile.archive) })
					: null;

	const freeAnswers = (profile.answers ?? []).filter(
		(answer) => (FREE_TEXT_KEYS as readonly string[]).includes(answer.questionKey),
	);
	// 身份 chip 只落城市与职业；性别不在卡面展示（owner review 2026-09）
	const identityChips = [profile.city, profile.occupationThen].filter(
		(value): value is string => Boolean(value),
	);

	const flipClasses = `fb-flip-swap${phase === "out" ? " fb-flip-swap--out" : ""}${
		phase === "in" ? " fb-flip-swap--in" : ""
	}`;

	return (
		<section className="fb-stage fb-stage-pad">
			{face === "front" ? (
				<>
					<h2 className="fb-stage-title" ref={titleRef} tabIndex={-1}>
						{feedback ?? t("title")}
					</h2>
					<div className={flipClasses}>
						<button
							type="button"
							className={`fb-polaroid fb-grain fb-reveal-card${developed ? "" : " fb-develop"}`}
							data-testid="fb-polaroid"
							data-face="front"
							onAnimationEnd={handleDeveloped}
							onClick={() => flip("back")}
							aria-describedby="fb-flip-hint"
						>
							<span className="fb-answers">
								{freeAnswers.map((answer) => (
									<span className="fb-answer" key={answer.id}>
										<span className="fb-answer-q">
											{questionT.has(answer.questionKey) ? questionT(answer.questionKey) : answer.questionKey}
										</span>
										<span className="fb-answer-a">
											<FogText
												text={answer.rawText}
												spans={answer.fogSpans}
												selfView
												placeholder={t("fogMark")}
											/>
										</span>
									</span>
								))}
								<span className="fb-identity">
									{identityChips.map((chip) => (
										<span key={chip}>{chip}</span>
									))}
								</span>
							</span>
							<span className="fb-card-caption">
								<span className="fb-caption-tilt">{profile.fullName}</span>
								<span>{whenText}</span>
							</span>
						</button>
					</div>

					{line === "memory" && (
						<div className="fb-btc-note">
							{t("btcNote")} 
							<a
								className="fb-btc-mail"
								href="mailto:info@codingirlsclub.com?subject=%E6%AF%94%E7%89%B9%E5%B8%81%E5%A5%96%E5%93%81%E5%85%91%E4%BB%98"
							>
								{t("btcContact")}
							</a>
						</div>
					)}

					{line === "dream" &&
						(dreamTarget ? (
							<Link
								href={`/events/${dreamTarget.eventSlug}`}
								className="fb-cta fb-cta-primary fb-dream-cta"
							>
								{t("dreamCtaEvent", { title: dreamTarget.eventTitle })}
							</Link>
						) : (
							<div className="fb-dream-fallback">
								<Link href="/initiatives" className="fb-cta fb-cta-primary fb-dream-cta">
									{t("dreamCtaInitiatives")}
								</Link>
								<p className="fb-promise">{t("dreamFallback")}</p>
							</div>
						))}

					<button type="button" className="fb-cta" onClick={() => flip("back")}>
						{t("writeBack")}
					</button>
					<p className="fb-hint" id="fb-flip-hint">
						{t("writeBackHint")}
					</p>
				</>
			) : (
				<>
					<div className={flipClasses}>
						<Write
							role={role}
							answers={answers}
							progress={progress}
							onNext={onWriteNext}
							data-face="back"
						/>
					</div>
					<button type="button" className="fb-cta" onClick={() => flip("front")}>
						{t("flipBack")}
					</button>
				</>
			)}
		</section>
	);
}
