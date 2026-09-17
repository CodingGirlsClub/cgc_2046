"use client";

import { useTranslations } from "next-intl";
import { yearsAgo, type FlashbackLine, type FlashbackProfile } from "@/lib/graphql/flashback";
import { usePrefersReducedMotion, useStageTitleFocus } from "./use-reduced-motion";

/**
 * 开场（R4 记忆线快门 / R9 圆梦线信封——同页分流）。
 *
 * - 记忆线：暗场 +「闪念间 / In a flash」+ 呼吸快门；按下白光一闪进散照
 *   （白光 overlay 由父级旅程状态机统一播放，本组件只发 onShutter）；
 * - 圆梦线：信封——「有一封信，寄了 N 年才到」（N 按 appliedAt 动态计算，R3），
 *   拆开进入当年答案显影（onOpen 即父级切 reveal）。
 * - 相对年数回落（AE1）：appliedAt 缺失时文案退为「当年」。
 */
export default function Intro({
	line,
	profile,
	onShutter,
	onOpen,
}: {
	line: FlashbackLine;
	profile?: FlashbackProfile | null;
	onShutter: () => void;
	onOpen: () => void;
}) {
	const t = useTranslations("flashback.intro");
	const reduced = usePrefersReducedMotion();
	const titleRef = useStageTitleFocus<HTMLHeadingElement>([line]);

	const years = yearsAgo(profile?.appliedAt);
	const yearsText = profile?.appliedAt ? t("yearsAgo", { years }) : t("yearsUnknown");

	if (line === "dream") {
		return (
			<section className="fb-stage fb-stage-pad">
				<h2 className="fb-stage-title" ref={titleRef} tabIndex={-1}>
					{t("envelopeTitle", { years: yearsText })}
				</h2>
				<p className="fb-lead">{t("envelopeLead")}</p>
				<button type="button" className="fb-cta fb-cta-primary" onClick={onOpen}>
					{t("openEnvelope")}
				</button>
				<p className="fb-hint">{t("envelopeHint")}</p>
			</section>
		);
	}

	return (
		<section className="fb-stage">
			<div className="fb-kicker">IN A FLASH · {t("kicker")}</div>
			<h2 className="fb-stage-title" ref={titleRef} tabIndex={-1}>
				{t("title")}
			</h2>
			<p className="fb-lead">{t("lead")}</p>
			<button
				type="button"
				className={`fb-shutter${reduced ? "" : " fb-breathe"}`}
				onClick={onShutter}
				aria-label={t("shutterAria")}
			/>
			<p className="fb-hint">{t("hint")}</p>
		</section>
	);
}
