"use client";

import { useTranslations } from "next-intl";
import { richTags } from "./pow";

/**
 * Hero（R2 九段 IA 第一段）：十周年封面复刻 + 三入口 CTA + 十周年刻度条。
 *
 * - 三入口按 F1/F2/F3 的「先读再走」顺序锚到页内对应段落（我要参加 → 节奏卡与
 *   FAQ；成为志愿者 → 职位与批次卡；赞助合作 → Partnership 段），落地页链接由各段
 *   自己的 CTA 承担（R3）。
 * - 刻度条 = 2016 成立 → 第 10 年 → 2026 · 2¹⁰＝1,024 场：把「为什么是 1,024」
 *   在首屏讲完（2 的幂叙事母题）。
 * - 声波柱高度沿 2 的幂走，装饰性（aria-hidden）。
 */
const WAVE = [8, 12, 16, 24, 32, 24, 48, 32, 64, 48, 80, 64, 100, 80, 64, 48, 32, 24];

export default function CampaignHero() {
	const t = useTranslations("hackerstart1024.hero");

	return (
		<div className="hs24-hero-wrap">
			<div className="hs24-container">
				<section className="hs24-hero" aria-labelledby="hs24-hero-title">
					<p className="hs24-hero__eyebrow">{t("eyebrow")}</p>
					<span className="hs24-hero__slot">{t("slot")}</span>
					<h1 className="hs24-hero__title" id="hs24-hero-title">
						{t("title")}
					</h1>
					<p className="hs24-hero__sub">{t("sub")}</p>
					<p className="hs24-hero__nums">
						<span>{t.rich("nums.sessions", richTags)}</span>
						<span>{t.rich("nums.start", richTags)}</span>
						<span>{t.rich("nums.batch", richTags)}</span>
					</p>
					<div className="hs24-hero__cta">
						<a href="#hs24-join" className="hs24-cta--white">
							{t("join")}
						</a>
						<a href="#hs24-volunteer" className="hs24-cta--outline">
							{t("volunteer")}
						</a>
						<a href="#hs24-brand" className="hs24-cta--outline">
							{t("brand")}
						</a>
					</div>
					<div className="hs24-wave" aria-hidden="true">
						{WAVE.map((height, index) => (
							<i key={index} style={{ height: `${height}%` }} />
						))}
					</div>
				</section>

				<div className="hs24-hero-foot">
					<div className="hs24-dots" aria-hidden="true">
						<i />
						<i />
						<i />
						<i />
					</div>
					<div className="hs24-scale" role="img" aria-label={t("scaleAria")}>
						<span className="hs24-scale__tick">{t("scaleStart")}</span>
						<span className="hs24-scale__rail">
							<span className="hs24-scale__fill" />
							<span className="hs24-scale__dot" />
							<span className="hs24-scale__now">{t("scaleNow")}</span>
						</span>
						<span className="hs24-scale__tick hs24-scale__tick--end">
							{t.rich("scaleEnd", richTags)}
						</span>
					</div>
					<p className="hs24-hero-hook">{t.rich("hook", richTags)}</p>
				</div>
			</div>
		</div>
	);
}
