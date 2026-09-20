"use client";

import { Fragment } from "react";
import { useTranslations } from "next-intl";
import { richTags } from "./pow";
import { rawArray } from "./raw-array";

/**
 * 我们是谁（R2 第 7 段）+ 赞助合作 Partnership（R2 第 8 段）。
 *
 * 赞助段以「你能得到什么」为主体（五项收益，从最硬讲起），正向表述；
 * 合作边界（多品牌同批 / 课程统一研发 / 零抽成）收在 lead 一句话里。
 * 口径纪律（R4/AE7）：历史累计只出现在 who 段十年数字带与曝光条目的
 * 括号标注里；512-2,048 参与者口径必须自带「本轮计划」标注。
 * 注意：benefits 是对象 keyed（与 caps 同构）——next-intl 的 t.rich 不支持
 * 数组索引路径（principles[0].d 会渲染成 key 字面量），数组一律走 t.raw 纯文本。
 */

const BRAND_EMAIL = "partners@codinggirlsclub.com";

const BENEFIT_KEYS = ["reach", "data", "network", "esg", "exposure"] as const;

export function WhoWeAreSection() {
	const t = useTranslations("hackerstart1024.who");
	const stats = rawArray<{ v: string; l: string }>(t.raw("stats"));
	const endorse = rawArray<{ text: string; url?: string }>(
		t.raw("endorse"),
	);

	return (
		<section className="hs24-section" aria-labelledby="hs24-who-title">
			<div className="hs24-container">
				<div className="hs24-badge-row">
					<span className="hs24-badge">{t("badge")}</span>
					<span className="hs24-badge-label">{t("label")}</span>
				</div>
				<h2 className="hs24-title" id="hs24-who-title">
					{t.rich("title", richTags)}
				</h2>
				<p className="hs24-lead">{t("lead")}</p>

				{/* 十年数字带：整体标注为历史累计口径（2016-2025），与本轮计划分开 */}
				<div className="hs24-stats">
					{stats.map((stat) => (
						<div key={stat.l} className="hs24-stat">
							<div className="hs24-stat__v">{stat.v}</div>
							<div className="hs24-stat__l">{stat.l}</div>
						</div>
					))}
				</div>
				<p className="hs24-stats__cap">{t("statsCap")}</p>

				{/* 证据墙：有稳定来源的挂真链接，无稳定链接的（共青团中央获奖、果壳网）保留文字 */}
				<div className="hs24-endorse">
					{endorse.map((item) =>
						item.url ? (
							<a
								key={item.text}
								href={item.url}
								target="_blank"
								rel="noopener noreferrer"
							>
								{item.text} ↗
							</a>
						) : (
							<span key={item.text}>{item.text}</span>
						),
					)}
				</div>

				<div className="hs24-lever">{t("lever")}</div>
			</div>
		</section>
	);
}

export function BrandSection() {
	const t = useTranslations("hackerstart1024.brand");
	const openqs = rawArray<{ t: string; d: string }>(t.raw("openqs"));
	const structure = rawArray<string>(t.raw("structure"));
	const caps = ["course", "ops", "data"] as const;

	return (
		<section className="hs24-section" id="hs24-brand" aria-labelledby="hs24-brand-title">
			<div className="hs24-section__corner" aria-hidden="true" />
			<div className="hs24-container">
				<div className="hs24-badge-row">
					<span className="hs24-badge hs24-badge--mint">{t("badge")}</span>
					<span className="hs24-badge-label">{t("label")}</span>
				</div>
				<h2 className="hs24-title" id="hs24-brand-title">
					{t.rich("title", richTags)}
				</h2>
				<p className="hs24-lead">{t("lead")}</p>

				{/* 五项收益（Value Ladder，从最硬讲起） */}
				<p className="hs24-sub">{t("benefitsTitle")}</p>
				<div className="hs24-ladder">
					{BENEFIT_KEYS.map((key, index) => (
						<div key={key} className="hs24-ladder__step">
							<span className="hs24-ladder__n">
								{String(index + 1).padStart(2, "0")}
							</span>
							<span className="hs24-ladder__t">{t(`benefits.${key}.t`)}</span>
							<span className="hs24-ladder__d">
								{t.rich(`benefits.${key}.d`, richTags)}
							</span>
						</div>
					))}
				</div>
				<p className="hs24-ladder__cap">{t("benefitsCap")}</p>

				{/* 交付能力三列（P5） */}
				<p className="hs24-sub">{t("capsTitle")}</p>
				<div className="hs24-cap3">
					{caps.map((key, index) => (
						<div key={key} className="hs24-tile">
							<div className="hs24-tile__t">
								<span className="hs24-tile__n">{index + 1}</span>
								{t(`caps.${key}.t`)}
							</div>
							<div className="hs24-tile__d">
								{t.rich(`caps.${key}.d`, richTags)}
							</div>
						</div>
					))}
				</div>

				{/* 可以一起做的事（P9） */}
				<p className="hs24-sub">{t("openqsTitle")}</p>
				<div className="hs24-openqs">
					{openqs.map((topic) => (
						<div key={topic.t} className="hs24-openq">
							<div className="hs24-openq__t">{topic.t}</div>
							<div className="hs24-openq__d">{topic.d}</div>
						</div>
					))}
				</div>
				<p className="hs24-openq__cap">{t("openqsCap")}</p>

				<div className="hs24-pill">
					{structure.map((item, index) => (
						<Fragment key={item}>
							{index > 0 ? <span aria-hidden="true">·</span> : null}
							<span>{item}</span>
						</Fragment>
					))}
				</div>

				<a href={`mailto:${BRAND_EMAIL}`} className="hs24-cta--rose">
					{t("cta")}
				</a>
				<p className="hs24-cta-note">{t("ctaNote")}</p>
			</div>
		</section>
	);
}
