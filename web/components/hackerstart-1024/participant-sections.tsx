"use client";

import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import { richTags } from "./pow";
import { rawArray } from "./raw-array";

/**
 * 参与者侧三段（R2 第 2-4 段）：为什么是现在 → 我要参加（节奏卡 + 班型事实行）
 * → 参与者 FAQ。
 *
 * 「我要参加」的落地页是 /initiatives（R3；F1：先读节奏卡与 FAQ，再由本段 CTA
 * 跳列表页挑城市场次）。
 */

/** 节奏卡配色轮转（设计）：开场 pink → 动手 mint → Demo solid */
const RHYTHM_TONES = ["pink", "mint", "solid"] as const;

export function WhyNowSection() {
	const t = useTranslations("hackerstart1024.why");
	return (
		<section className="hs24-section" aria-labelledby="hs24-why-title">
			<div className="hs24-container">
				<div className="hs24-badge-row">
					<span className="hs24-badge">{t("badge")}</span>
					<span className="hs24-badge-label">{t("label")}</span>
				</div>
				<h2 className="hs24-title" id="hs24-why-title">
					{t.rich("title", richTags)}
				</h2>
				<p className="hs24-lead">{t("lead")}</p>
			</div>
		</section>
	);
}

export function JoinSection() {
	const t = useTranslations("hackerstart1024.join");
	const rhythm = rawArray<{ min: string; t: string; d: string }>(
		t.raw("rhythm"),
	);

	return (
		<section className="hs24-section" id="hs24-join" aria-labelledby="hs24-join-title">
			<div className="hs24-container">
				<div className="hs24-badge-row">
					<span className="hs24-badge">{t("badge")}</span>
					<span className="hs24-badge-label">{t("label")}</span>
				</div>
				<h2 className="hs24-title" id="hs24-join-title">
					{t.rich("title", richTags)}
				</h2>
				<div className="hs24-formula">
					{rhythm.map((cell, index) => (
						<div
							key={cell.t}
							className={`hs24-fcell hs24-fcell--${RHYTHM_TONES[index] ?? "pink"}`}
						>
							<div className="hs24-fcell__v">
								{cell.min}
								<sup>min</sup>
							</div>
							<div className="hs24-fcell__l">
								{cell.t} · {cell.d}
							</div>
						</div>
					))}
				</div>
				<p className="hs24-lead hs24-lead--muted">{t.rich("facts", richTags)}</p>
				<Link href="/initiatives" className="hs24-cta--rose">
					{t("cta")}
				</Link>
				<p className="hs24-cta-note">{t("ctaNote")}</p>
			</div>
		</section>
	);
}

export function FaqSection() {
	const t = useTranslations("hackerstart1024.faq");
	const items = rawArray<{ q: string; a: string }>(t.raw("items"));

	return (
		<section className="hs24-section" aria-labelledby="hs24-faq-title">
			<div className="hs24-container">
				<div className="hs24-badge-row">
					<span className="hs24-badge">{t("badge")}</span>
					<span className="hs24-badge-label">{t("label")}</span>
				</div>
				<h2 className="hs24-title" id="hs24-faq-title">
					{t.rich("title", richTags)}
				</h2>
				<div className="hs24-faq">
					{items.map((item) => (
						<details key={item.q}>
							<summary>{item.q}</summary>
							<p>{item.a}</p>
						</details>
					))}
				</div>
			</div>
		</section>
	);
}
