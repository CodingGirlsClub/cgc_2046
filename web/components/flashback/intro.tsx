"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { yearsAgo, type FlashbackLine, type FlashbackProfile } from "@/lib/graphql/flashback";
import { usePrefersReducedMotion, useStageTitleFocus } from "./use-reduced-motion";

/**
 * 开场（R4 记忆线快门 / R9 圆梦线信封——同页分流）。
 *
 * - 记忆线：暗场 +「闪念间 / In a flash」+ 呼吸快门；按下白光一闪进散照
 *   （白光 overlay 由父级旅程状态机统一播放，本组件只发 onShutter）；
 * - 圆梦线：信封物件——「有一封信，寄了 N 年才到」（N 按 appliedAt 动态计算，R3）；
 *   点信封 → 翻盖旋开（fb-flap 1s）+ 信纸升起（fb-letter-out 1.2s，延迟 0.8s，
 *   原型 C 的拆信仪式）→ 动画收尾切当年答案显影（onOpen，父级切 reveal）。
 *   reduced-motion：跳过动画直接拆开（既有 media 块已把两条动画关掉）。
 * - 相对年数回落（AE1）：appliedAt 缺失时文案退为「当年」。
 */
/** 拆信动画整程（fb-flap 1s + fb-letter-out 1.2s 延迟 0.8s） */
const ENVELOPE_OPEN_MS = 2000;

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

	/** 拆信（第 6 件）：动画收尾才切阶段（flap 1s + 信纸 1.2s 延迟 0.8s = 2.0s） */
	const [opened, setOpened] = useState(false);
	const openEnvelope = () => {
		if (opened) return;
		if (reduced) {
			onOpen();
			return;
		}
		setOpened(true);
		window.setTimeout(onOpen, ENVELOPE_OPEN_MS);
	};

	if (line === "dream") {
		return (
			<section className="fb-stage fb-stage-pad">
				<h2 className="fb-stage-title" ref={titleRef} tabIndex={-1}>
					{t("envelopeTitle", { years: yearsText })}
				</h2>
				<p className="fb-lead">{t("envelopeLead")}</p>
				<button
					type="button"
					className="fb-polaroid fb-envelope"
					data-testid="fb-envelope"
					data-opened={opened ? "true" : "false"}
					aria-label={t("openEnvelope")}
					onClick={openEnvelope}
				>
					<span className="fb-envelope-body">
						<span className={`fb-envelope-letter${opened ? " fb-letter-out" : ""}`}>
							{profile?.fullName ? t("envelopeTo", { name: profile.fullName }) : t("envelopeSeal")}
						</span>
						<span aria-hidden="true" className={`fb-envelope-flap${opened ? " fb-flap" : ""}`}>
							<span className="fb-envelope-mark">✉</span>
						</span>
					</span>
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
