"use client";

/**
 * 公开首页 Landing 页（M2）：未登录访客看到的第一屏。
 *
 * - 叙事主线：Coding Girls Club（程序媛汇）2016 年创立，立志做到 2046 年（30 年），
 *   推动女性进入并留在科技领域；语气真诚朴素，不浮夸。
 * - 「最新活动 / 精选课程」复用公开 API（fetchPublicOfferings，匿名白名单查询），
 *   各取前 3 条；加载失败时降级为入口链接，不阻塞整页。
 * - 「报道与认可 / 合作伙伴」为静态文案，素材取自 2021 年版机构介绍 deck
 *   （docs/宣传素材/，M1 调研权威清单 + tower 拍板口径）：
 *   媒体报道前 4 条附原文链接、果壳网只列媒体+标题；
 *   合作伙伴为精选科技类 8 家的历史同行者口径，不暗示当前仍在合作。
 */

import LanguageSwitcher from "@/components/language-switcher";
import { Link } from "@/i18n/navigation";
import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { fetchPublicOfferings } from "@/lib/public-offerings";
import type { OfferingKind, PublicOfferingItem } from "@/lib/graphql/events";
import { ENROLLMENT_POLICY_LABEL } from "@/lib/graphql/events";
import EventStatusTag from "@/components/event-status-tag";
import { formatDeadline } from "@/lib/events";

/* ---------------- 活动/课程卡片（与 /events、/courses 发现页同款） ---------------- */

function OfferingCard({
	item,
	kind,
}: {
	item: PublicOfferingItem;
	kind: OfferingKind;
}) {
	const t = useTranslations("landing");
	const tCommon = useTranslations("common");
	const labelsT = useTranslations();
	const base = kind === "event" ? "/events" : "/courses";
	return (
		<Link
			href={`${base}/${item.slug}`}
			className="join-card flex items-center gap-4 !p-6 !w-full"
		>
			<span className="min-w-0 flex-1">
				<span className="flex items-center gap-2">
					<span className="block truncate text-sm font-medium">{item.title}</span>
					<EventStatusTag status={item.status} />
				</span>
				<span className="mt-1 block text-[13px] leading-5 text-ink-3">
					{labelsT(ENROLLMENT_POLICY_LABEL[item.enrollmentPolicy])} ·{" "}
					{t("sections.deadline", { deadline: formatDeadline(item.registrationDeadline, tCommon("noDeadline")) })}
				</span>
			</span>
			<span className="flex-none text-ink-3">›</span>
		</Link>
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
		<section aria-labelledby={`landing-${kind}-heading`} className="mt-16">
			<div className="flex items-end justify-between gap-4">
				<div>
					<h2 id={`landing-${kind}-heading`} className="l-h2">
						{title}
					</h2>
					<p className="mt-2 text-sm text-ink-3">{description}</p>
				</div>
				<Link
					href={href}
					className="flex-none text-sm text-accent hover:text-accent-mention"
				>
					{t("sections.viewAll")}
				</Link>
			</div>
			{state.status === "loading" ? (
				<div className="mt-6 h-28 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
			) : state.status === "error" ? (
				<p className="mt-6 text-sm text-ink-3">
					{t("sections.errorHint")}{" "}
					<Link href={href} className="text-accent">
						{t("sections.errorAction")}
					</Link>
				</p>
			) : state.rows.length === 0 ? (
				<p className="mt-6 text-sm text-ink-3">
					{t("sections.emptyHint")}{" "}
					<Link href={href} className="text-accent">
						{t("sections.emptyAction")}
					</Link>
				</p>
			) : (
				<div className="mt-6 grid gap-3">
					{state.rows.map((item) => (
						<OfferingCard key={item.id} item={item} kind={kind} />
					))}
				</div>
			)}
		</section>
	);
}

/* ---------------- 页面 ---------------- */

export default function LandingPage() {
	const t = useTranslations("landing");
	const mediaReports = t.raw("mediaReports") as Array<{
		outlet: string;
		title: string;
		url: string | null;
	}>;
	const honors = t.raw("honors") as string[];
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
		<main className="mx-auto w-full max-w-4xl px-4 pb-20">
			{/* 顶部导航：品牌 + 公开入口 + 登录/注册 */}
			<header className="flex items-center gap-6 py-6">
				<span className="text-[15px] font-semibold tracking-tight">
					CGC 2046
				</span>
				<nav className="flex items-center gap-4 text-sm text-ink-3">
					<Link href="/events" className="hover:text-ink">
						{t("nav.events")}
					</Link>
					<Link href="/courses" className="hover:text-ink">
						{t("nav.courses")}
					</Link>
				</nav>
				<div className="ml-auto flex items-center gap-3">
					<Link
						href="/login"
						className="text-sm text-ink-2 hover:text-ink"
					>
						{t("nav.login")}
					</Link>
					<Link
						href="/register"
						className="join-button join-button--primary !min-h-9"
					>
						{t("nav.join")}
					</Link>
				</div>
			</header>

			{/* Hero：组织历史 slogan（桥）+ 30 年叙事主线 */}
			<section aria-labelledby="landing-hero-heading" className="mt-16">
				<p className="text-sm text-accent">
					{t("hero.tagline")}
				</p>
				<h1
					id="landing-hero-heading"
					className="l-h1 mt-4 max-w-2xl"
				>
					{t("hero.title")}
				</h1>
				<p className="l-h3 mt-6 max-w-2xl">
					{t("hero.subtitle")}
				</p>
				<p className="l-p mt-6 max-w-2xl text-ink-2">
					{t("hero.description")}
				</p>
				<blockquote className="mt-6 max-w-2xl border-l-2 border-accent pl-4 text-sm text-ink-2">
					{t("hero.quote")}
					<span className="mt-1 block text-[13px] text-ink-3">
						{t("hero.quoteAuthor")}
					</span>
				</blockquote>
				<p className="mt-6 text-[13px] text-ink-3">
					{t("hero.stats")}
				</p>
				<div className="mt-8 flex items-center gap-3">
					<Link
						href="/register"
						className="join-button join-button--primary"
					>
						{t("hero.join")}
					</Link>
					<Link
						href="/events"
						className="join-button join-button--outline"
					>
						{t("hero.browseEvents")}
					</Link>
				</div>
			</section>

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

			{/* 报道与认可（静态文案，2021 deck 权威素材） */}
			<section aria-labelledby="landing-media-heading" className="mt-16">
				<h2 id="landing-media-heading" className="l-h2">
					{t("media.title")}
				</h2>
				<p className="mt-2 text-sm text-ink-3">
					{t("media.description")}
				</p>

				{/* 学术论文 */}
				<a
					href={paperUrl}
					target="_blank"
					rel="noopener noreferrer"
					className="join-card mt-6 block !w-full !gap-1 !p-6"
				>
					<span className="text-sm font-medium">{t("paperTitle")}</span>
					<span className="text-[13px] text-ink-3">{t("paper.venue")}</span>
				</a>

				{/* 媒体报道 */}
				<ul className="mt-3 grid gap-3">
					{mediaReports.map((report) => (
						<li key={`${report.outlet}-${report.title}`}>
							{report.url ? (
								<a
									href={report.url}
									target="_blank"
									rel="noopener noreferrer"
									className="join-card block !w-full !gap-1 !p-6"
								>
									<span className="text-sm font-medium">{report.title}</span>
									<span className="text-[13px] text-ink-3">{report.outlet}</span>
								</a>
							) : (
								<div className="join-card !w-full !gap-1 !p-6">
									<span className="text-sm font-medium">{report.title}</span>
									<span className="text-[13px] text-ink-3">{report.outlet}</span>
								</div>
							)}
						</li>
					))}
				</ul>

				{/* 机构荣誉 */}
				<ul className="mt-6 grid gap-2">
					{honors.map((honor) => (
						<li
							key={honor}
							className="flex items-center gap-2 text-[13px] text-ink-2"
						>
							<span className="text-accent" aria-hidden="true">
								★
							</span>
							{honor}
						</li>
					))}
				</ul>
			</section>

			{/* 合作伙伴（静态文案，历史同行者口径） */}
			<section aria-labelledby="landing-partners-heading" className="mt-16">
				<h2 id="landing-partners-heading" className="l-h2">
					{t("partners.title")}
				</h2>
				<p className="mt-2 text-sm text-ink-3">
					{t("partners.description")}
				</p>
				<ul className="mt-6 flex flex-wrap justify-center gap-3">
					{partners.map((partner) => (
						<li
							key={partner}
							className="inline-flex items-center rounded-medium border border-line px-4 py-2 text-sm text-ink-2"
						>
							{partner}
						</li>
					))}
				</ul>
			</section>

			{/* 底部 CTA */}
			<section
				aria-labelledby="landing-cta-heading"
				className="mt-20 rounded-large border border-line bg-card px-6 py-12 text-center"
			>
				<h2 id="landing-cta-heading" className="l-h2">
					{t("cta.title")}
				</h2>
				<div className="mt-8 flex items-center justify-center gap-3">
					<Link
						href="/register"
						className="join-button join-button--primary"
					>
						{t("cta.register")}
					</Link>
					<Link
						href="/login"
						className="join-button join-button--outline"
					>
						{t("cta.login")}
					</Link>
				</div>
			</section>

			<footer className="mt-16 border-t border-line pt-6 text-[13px] text-ink-3">
				<div className="flex items-center justify-between gap-4">
					<p>{t("footer.tagline")}</p>
					<LanguageSwitcher />
				</div>
			</footer>
		</main>
	);
}
