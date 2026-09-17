"use client";

import { useEffect } from "react";
import { useTranslations, useLocale } from "next-intl";
import { Link } from "@/i18n/navigation";
import {
	appliedStamp,
	yearsAgo,
	type FlashbackDreamTarget,
	type FlashbackProfile,
} from "@/lib/graphql/flashback";
import { FogText } from "./fog-text";
import { usePrefersReducedMotion, useStageTitleFocus, useOnceCallback } from "./use-reduced-motion";

/** 自由文本题（R7「实际存在的题」）：PII 行（full_name/phone/email）不进正面 */
const FREE_TEXT_KEYS = ["self_intro", "funny_thing", "os", "social_media"] as const;

/**
 * 拍立得显影（R7）：中速显影（1.2s——全流程唯一的慢时刻留给「认出自己」），
 * 显影完成写 revealed 行为事件（四时刻之二，由父级 onRevealed 落 mutation）。
 * reduced-motion：跳过显影直达终态（CSS 变量归零 + 立即 onRevealed）。
 *
 * 圆梦线（dream）同屏展示 1024 圆梦 CTA 两态（R9）：本城有已发布场次直链
 * Event 报名页；无则落 Initiative 公开页 + 兜底出口（写字寄出留联系方式）。
 */
export default function Reveal({
	profile,
	line,
	dreamTarget,
	quizChoice,
	onRevealed,
	onWrite,
}: {
	profile: FlashbackProfile;
	line: "memory" | "dream";
	dreamTarget: FlashbackDreamTarget | null;
	quizChoice: "correct" | "dunno" | null;
	onRevealed: () => void;
	onWrite: () => void;
}) {
	const t = useTranslations("flashback.reveal");
	const questionT = useTranslations("flashback.questionLabels");
	// yearsAgo 单源在 intro namespace（两线开场共用同一句相对年数文案）
	const introT = useTranslations("flashback.intro");
	const reduced = usePrefersReducedMotion();
	const titleRef = useStageTitleFocus<HTMLHeadingElement>([line]);
	const locale = useLocale();
	const notifyRevealed = useOnceCallback(onRevealed);

	// reduced-motion：不等待动画，直达终态并记 revealed（ref 防重，零 setState）
	useEffect(() => {
		if (reduced) notifyRevealed();
		// eslint-disable-next-line react-hooks/exhaustive-deps -- 终态通知一次性
	}, [reduced]);

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
				: null;

	const freeAnswers = (profile.answers ?? []).filter(
		(answer) => (FREE_TEXT_KEYS as readonly string[]).includes(answer.questionKey),
	);
	const identityChips = [
		profile.city,
		profile.occupationThen,
		profile.gender,
	].filter((value): value is string => Boolean(value));

	return (
		<section className="fb-stage fb-stage-pad">
			<h2 className="fb-stage-title" ref={titleRef} tabIndex={-1}>
				{feedback ?? t("title")}
			</h2>
			<div
				className="fb-polaroid fb-grain fb-develop"
				onAnimationEnd={notifyRevealed}
				data-testid="fb-polaroid"
			>
				<div className="fb-answers">
					{freeAnswers.map((answer) => (
						<div key={answer.id}>
							<div className="fb-answer-q">
								{questionT.has(answer.questionKey) ? questionT(answer.questionKey) : answer.questionKey}
							</div>
							<div className="fb-answer-a">
								<FogText
									text={answer.rawText}
									spans={answer.fogSpans}
									selfView
									placeholder={t("fogMark")}
								/>
							</div>
						</div>
					))}
					<div className="fb-identity">
						{identityChips.map((chip) => (
							<span key={chip}>{chip}</span>
						))}
					</div>
				</div>
				<div className="fb-card-caption">
					<span className="fb-caption-tilt">{profile.fullName}</span>
					<span>{whenText}</span>
				</div>
			</div>

			{line === "memory" && <div className="fb-btc-note">{t("btcNote")}</div>}

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

			<button type="button" className="fb-cta" onClick={onWrite}>
				{t("writeBack")}
			</button>
			<p className="fb-hint">{t("writeBackHint")}</p>
		</section>
	);
}
