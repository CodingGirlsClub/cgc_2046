"use client";

/**
 * 公开首页 Landing 页（M2 重构，2026-08；IA 定稿：行动优先，叙事殿后）。
 *
 * 信息架构（每屏只回答一个问题）：
 *   Hero（这是什么：kicker（年份+组织+使命一句）+ slogan 大标题 + 单一主 CTA + 2016→2046 年份刻度条）
 *   → 路径（加入之后会发生什么，三步）
 *   → 最新活动 / 精选课程（现在就能报什么；公开 API 各取前 3，失败降级为入口链接）
 *   → 信任带（为什么值得加入：大数字 + 论文 + 媒体索引 + 合作伙伴）
 *   → 关于我们（组织简介 + 创始人引语 + 2016→2046 里程碑时间线，历史叙事只讲一次）
 *   → 底部 CTA → footer
 *
 * 设计：固定深色门面（.ld-root 重声明暗色 token，html.light 下本页仍为深色，
 * 登录后的应用内页面保持双主题不变）。Linear 原生介质 + 纪念碑式排印，
 * 零图像素材依赖，纯排印与几何。动效仅 Hero 入场 staggered reveal 与按钮
 * 按压反馈；prefers-reduced-motion 在 CSS 侧全降级。
 */

import LanguageSwitcher from "@/components/language-switcher";
import { BrandLockup } from "@/components/brand";
import { Link } from "@/i18n/navigation";
import { useEffect, useState, type CSSProperties } from "react";
import { useTranslations } from "next-intl";
import { fetchPublicOfferings } from "@/lib/public-offerings";
import type { OfferingKind, PublicOfferingItem } from "@/lib/graphql/events";
import OfferingRow from "@/components/offering-row";
import SiteHeader from "@/components/site-header";

const FOUNDED_YEAR = 2016;
const TARGET_YEAR = 2046;

/** Hero 入场延迟阶梯（ms）：kicker → 标题 → 副题 → CTA → 年份刻度 */
function rise(index: number): CSSProperties {
	return { "--d": `${index * 90}ms` } as CSSProperties;
}

/* ---------------- 年份刻度条：2016 ───●─── 2046 ---------------- */

function YearStrip() {
	const t = useTranslations("landing");
	const now = new Date().getFullYear();
	const progress = Math.min(
		1,
		Math.max(0, (now - FOUNDED_YEAR) / (TARGET_YEAR - FOUNDED_YEAR)),
	);
	return (
		<div className="ld-years" role="img" aria-label={t("hero.timelineAria")}>
			<span className="ld-years__tick">{FOUNDED_YEAR}</span>
			<span className="ld-years__rail" aria-hidden="true">
				<span
					className="ld-years__fill"
					style={{ transform: `scaleX(${progress})` }}
				/>
				<span
					className="ld-years__marker"
					style={{ insetInlineStart: `${progress * 100}%` }}
				>
					<span className="ld-years__dot" />
					<span className="ld-years__now">{t("hero.timelineNow")}</span>
				</span>
			</span>
			<span className="ld-years__tick">{TARGET_YEAR}</span>
		</div>
	);
}

/* ---------------- 动态区块（公开 API；失败降级为入口链接） ---------------- */

type OfferingsState =
	| { status: "loading" }
	| { status: "error" }
	| { status: "ready"; rows: PublicOfferingItem[] };

function OfferingSection({
	kind,
	title,
	description,
	href,
	state,
}: {
	kind: OfferingKind;
	title: string;
	description: string;
	href: string;
	state: OfferingsState;
}) {
	const t = useTranslations("landing");
	return (
		<section aria-labelledby={`landing-${kind}-heading`} className="ld-section">
			<div className="ld-container">
				<div className="ld-section__head">
					<div>
						<h2 id={`landing-${kind}-heading`} className="ld-section__title">
							{title}
						</h2>
						<p className="ld-section__desc">{description}</p>
					</div>
					<Link href={href} className="ld-section__more">
						{t("sections.viewAll")}
					</Link>
				</div>
				{state.status === "loading" ? (
					// 3 块与真实行高等高的 skeleton：加载完成不再发生布局位移（CLS）
					<div aria-hidden="true">
						<div className="ld-skeleton" />
						<div className="ld-skeleton" />
						<div className="ld-skeleton" />
					</div>
				) : state.status === "error" ? (
					<p className="ld-offer-fallback">
						{t("sections.errorHint")}{" "}
						<Link href={href}>{t("sections.errorAction")}</Link>
					</p>
				) : state.rows.length === 0 ? (
					<p className="ld-offer-fallback">
						{t("sections.emptyHint")}{" "}
						<Link href={href}>{t("sections.emptyAction")}</Link>
					</p>
				) : (
					<ul className="ld-offers">
						{state.rows.map((item) => (
							<OfferingRow key={item.id} item={item} kind={kind} />
						))}
					</ul>
				)}
			</div>
		</section>
	);
}

/* ---------------- 页面 ---------------- */

export default function LandingPage() {
	const t = useTranslations("landing");
	const stats = t.raw("stats.items") as Array<{ value: string; label: string }>;
	const steps = t.raw("path.steps") as Array<{
		title: string;
		description: string;
	}>;
	const milestones = t.raw("journey.entries") as Array<{
		year: string;
		text: string;
	}>;
	const mediaReports = t.raw("mediaReports") as Array<{
		outlet: string;
		title: string;
		url: string | null;
	}>;
	const partners = ["UNDP", "ThoughtWorks", "GitHub", "ByteDance", "FreeWheel"];
	const paperUrl =
		"https://www.computer.org/csdl/proceedings-article/chase/2021/140900a091/1tB7t8SZKcE";
	const [events, setEvents] = useState<OfferingsState>({ status: "loading" });
	const [courses, setCourses] = useState<OfferingsState>({ status: "loading" });

	useEffect(() => {
		let cancelled = false;
		fetchPublicOfferings("event")
			.then((rows) => {
				if (!cancelled) setEvents({ status: "ready", rows: rows.slice(0, 3) });
			})
			.catch(() => {
				if (!cancelled) setEvents({ status: "error" });
			});
		fetchPublicOfferings("course")
			.then((rows) => {
				if (!cancelled) setCourses({ status: "ready", rows: rows.slice(0, 3) });
			})
			.catch(() => {
				if (!cancelled) setCourses({ status: "error" });
			});
		return () => {
			cancelled = true;
		};
	}, []);

	return (
		<main className="ld-root">
			{/* 顶导：全站统一 SiteHeader（与公开目录页同源零跳变） */}
			<SiteHeader />

			{/* Hero：kicker + 纪念碑式大标题 + 单一主 CTA + 年份刻度条 */}
			<section aria-labelledby="landing-hero-heading" className="ld-hero">
				<div className="ld-container">
					<p className="ld-kicker ld-rise" style={rise(0)}>
						<span className="ld-kicker__dot" aria-hidden="true" />
						{t("hero.tagline")}
					</p>
					<h1 id="landing-hero-heading" className="ld-display ld-rise" style={rise(1)}>
						{t("hero.title")}
					</h1>
					<div className="ld-cta-row ld-rise" style={rise(2)}>
						<Link href="/register" className="join-button join-button--primary">
							{t("hero.join")}
						</Link>
						<Link href="/events" className="ld-cta-quiet">
							{t("hero.browseEvents")} →
						</Link>
					</div>
					<div className="ld-rise" style={rise(3)}>
						<YearStrip />
					</div>
				</div>
			</section>

			{/* ① 路径：加入之后会发生什么（三步） */}
			<section aria-labelledby="landing-path-heading" className="ld-section">
				<div className="ld-container">
					<div className="ld-section__head">
						<div>
							<h2 id="landing-path-heading" className="ld-section__title">
								{t("path.title")}
							</h2>
							<p className="ld-section__desc">{t("path.description")}</p>
						</div>
					</div>
					<ol className="ld-path">
						{steps.map((step, i) => (
							<li key={step.title} className="ld-step">
								<span className="ld-step__index">
									{String(i + 1).padStart(2, "0")}
								</span>
								<h3 className="ld-step__title">{step.title}</h3>
								<p className="ld-step__desc">{step.description}</p>
							</li>
						))}
					</ol>
				</div>
			</section>

			{/* ② 行动闭环：现在就能报名的活动与课程 */}
			<OfferingSection
				kind="event"
				title={t("sections.eventsTitle")}
				description={t("sections.eventsDesc")}
				href="/events"
				state={events}
			/>

			<OfferingSection
				kind="course"
				title={t("sections.coursesTitle")}
				description={t("sections.coursesDesc")}
				href="/courses"
				state={courses}
			/>

			{/* ③ 信任带：大数字 + 论文 + 媒体索引 + 合作伙伴 */}
			<section aria-labelledby="landing-trust-heading" className="ld-section">
				<div className="ld-container">
					<h2 id="landing-trust-heading" className="ld-section__title">
						{t("trust.title")}
					</h2>
					<ul className="ld-stats">
						{stats.map((s) => (
							<li key={s.label}>
								<div className="ld-stat__value">{s.value}</div>
								<div className="ld-stat__label">{s.label}</div>
							</li>
						))}
					</ul>

					<a
						href={paperUrl}
						target="_blank"
						rel="noopener noreferrer"
						className="ld-paper ld-paper--spaced"
					>
						<span className="ld-paper__title">{t("paperTitle")}</span>
						<span className="ld-paper__venue">{t("paper.venue")}</span>
					</a>

					<ul className="ld-press">
						{mediaReports.map((report) => (
							<li key={`${report.outlet}-${report.title}`}>
								{report.url ? (
									<a
										href={report.url}
										target="_blank"
										rel="noopener noreferrer"
										className="ld-press__row"
									>
										<span className="ld-press__outlet">{report.outlet}</span>
										<span className="ld-press__title">{report.title}</span>
										<span className="ld-press__arrow" aria-hidden="true">
											↗
										</span>
									</a>
								) : (
									<div className="ld-press__row">
										<span className="ld-press__outlet">{report.outlet}</span>
										<span className="ld-press__title">{report.title}</span>
										<span />
									</div>
								)}
							</li>
						))}
					</ul>

					<div className="ld-trust__partners">
						<p className="ld-trust__partners-caption">
							{t("partners.description")}
						</p>
						<ul className="ld-partners">
							{partners.map((partner) => (
								<li key={partner}>{partner}</li>
							))}
						</ul>
					</div>
				</div>
			</section>

			{/* ④ 关于我们：组织简介 + 创始人引语 + 里程碑时间线（历史叙事只讲一次） */}
			<section aria-labelledby="landing-about-heading" className="ld-section ld-about">
				<div className="ld-container">
					<h2 id="landing-about-heading" className="ld-section__title">
						{t("about.title")}
					</h2>
					<div className="ld-manifesto ld-manifesto--spaced">
						<p className="ld-manifesto__desc">{t("hero.description")}</p>
						<blockquote className="ld-quote">
							<p>{t("hero.quote")}</p>
							<footer>{t("hero.quoteAuthor")}</footer>
						</blockquote>
					</div>
					<ol className="ld-journey">
						{milestones.map((m) => (
							<li key={m.year} className="ld-journey__entry">
								<span className="ld-journey__year">{m.year}</span>
								<span className="ld-journey__text">{m.text}</span>
							</li>
						))}
					</ol>
					<p className="ld-journey__note">{t("journey.note")}</p>
				</div>
			</section>

			{/* 底部 CTA */}
			<section aria-labelledby="landing-cta-heading" className="ld-final">
				<div className="ld-container">
					<h2 id="landing-cta-heading">{t("cta.title")}</h2>
					<div className="ld-cta-row">
						<Link href="/register" className="join-button join-button--primary">
							{t("cta.register")}
						</Link>
						<Link href="/login" className="ld-cta-quiet">
							{t("cta.login")}
						</Link>
					</div>
				</div>
			</section>

			<footer className="ld-footer">
				<div className="ld-container ld-footer__inner">
					<BrandLockup className="ld-footer__brand" />
					<p>{t("footer.tagline")}</p>
					{/* 语言切换在顶导常驻；窄屏顶导收起后由页尾接管（仅 ≤640px 显示） */}
					<span className="ld-footer__lang">
						<LanguageSwitcher />
					</span>
					<p>
						© CodingGirlsClub ｜{" "}
						<a
							href="https://beian.miit.gov.cn"
							target="_blank"
							rel="noopener noreferrer"
						>
							{t("footer.icp")}
						</a>
					</p>
				</div>
			</footer>
		</main>
	);
}
