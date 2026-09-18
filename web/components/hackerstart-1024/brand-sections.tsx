"use client";

import { Fragment } from "react";
import { useTranslations } from "next-intl";
import { Pow, richTags } from "./pow";
import { rawArray } from "./raw-array";

/**
 * 我们是谁（R2 第 7 段）+ 品牌专场合作（R2 第 8 段）。
 *
 * 口径纪律（R4/AE7）在这一段最吃重，两处标注互不混用：
 * - 历史累计：十年数字带整体挂「2016-2025 历史累计」标注（statsCap），
 *   「过去十年」只出现在杠杆句里与本轮的对照位置。
 * - 本轮计划：64 场公式行下挂 planCap，价值阶梯的激活用户条目写「本轮计划」。
 */

const BRAND_EMAIL = "partners@codinggirlsclub.com";

/** 64 场公式行（P6 复刻）：浅粉 × 薄荷 ＝ 深玫红，运算符是装饰（aria-hidden） */
const FORMULA = [
	{ key: "seats", tone: "pink", operator: "×" },
	{ key: "sessions", tone: "mint", operator: "＝" },
	{ key: "nationwide", tone: "solid", operator: null },
] as const;

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
	const perks = rawArray<{ t: string; d: string }>(t.raw("perks"));
	const ladder = rawArray<{ t: string; d: string }>(t.raw("ladder"));
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

				{/* 16 × 64 ＝ 1,024（P6 复刻）：幂标记挂在各方格主数字后 */}
				<div className="hs24-formula">
					{FORMULA.map((cell) => (
						<Fragment key={cell.key}>
							{cell.operator ? (
								<span className="hs24-fop" aria-hidden="true">
									{cell.operator}
								</span>
							) : null}
							<div className={`hs24-fcell hs24-fcell--${cell.tone}`}>
								<div className="hs24-fcell__v">
									{t(`formula.${cell.key}.value`)}
									<Pow exponent={t(`formula.${cell.key}.pow`)} />
								</div>
								<div className="hs24-fcell__l">
									{t(`formula.${cell.key}.label`)}
								</div>
							</div>
						</Fragment>
					))}
				</div>
				<p className="hs24-plan-cap">{t("planCap")}</p>

				<div className="hs24-tiles">
					{perks.map((perk, index) => (
						<div key={perk.t} className="hs24-tile">
							<div className="hs24-tile__t">
								<span className="hs24-tile__n">{index + 1}</span>
								{perk.t}
							</div>
							<div className="hs24-tile__d">{perk.d}</div>
						</div>
					))}
				</div>

				{/* 示例命名胶囊（P6） */}
				<div className="hs24-pill">
					<span>{t("pill")}</span>
				</div>

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

				{/* 六层价值阶梯（P7，从最硬讲起） */}
				<p className="hs24-sub">{t("ladderTitle")}</p>
				<div className="hs24-ladder">
					{ladder.map((step, index) => (
						<div key={step.t} className="hs24-ladder__step">
							<span className="hs24-ladder__n">
								{String(index + 1).padStart(2, "0")}
							</span>
							<span className="hs24-ladder__t">{step.t}</span>
							<span className="hs24-ladder__d">{step.d}</span>
						</div>
					))}
				</div>
				<p className="hs24-ladder__cap">{t("ladderCap")}</p>

				{/* 开放共创议题（P9） */}
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
