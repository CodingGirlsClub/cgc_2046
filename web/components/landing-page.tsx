"use client";

/**
 * 公开首页 Landing 页（M2）：未登录访客看到的第一屏。
 *
 * - 叙事主线：Coding Girls Club（程序媛汇）2016 年创立，立志做到 2046 年（30 年），
 *   推动女性进入并留在科技领域；语气真诚朴素，不浮夸。
 * - 「最新活动 / 精选课程」复用公开 API（fetchPublicOfferings，匿名白名单查询），
 *   各取前 3 条；加载失败时降级为入口链接，不阻塞整页。
 * - 「媒体报道 / 合作企业」为静态文案（M1 调研大纲 + tower 拍板口径）：
 *   均为 2017-2018 历史素材，媒体报道无原文链接故纯文本列表；
 *   合作企业为历史同行者口径，不暗示当前仍在合作。
 * - 论文/学术引用区块：当前零素材，按 tower 拍板砍掉不留空壳。
 */

import Link from "next/link";
import { useEffect, useState } from "react";
import { fetchPublicOfferings } from "@/lib/public-offerings";
import type { OfferingKind, PublicOfferingItem } from "@/lib/graphql/events";
import { ENROLLMENT_POLICY_LABEL } from "@/lib/graphql/events";
import EventStatusTag from "@/components/event-status-tag";
import { formatDeadline } from "@/lib/events";

/* ---------------- 静态素材（M1 调研大纲，tower 拍板口径） ---------------- */

interface MediaReport {
	outlet: string;
	title: string;
	date: string;
}

/** 媒体报道：2017-2018 历史素材，无原文链接，纯文本列表（不放假链接） */
const MEDIA_REPORTS: MediaReport[] = [
	{
		outlet: "果壳网",
		title: "《自学编程的故事与未来》",
		date: "2017-01-14",
	},
	{
		outlet: "CCTV 英文频道",
		title: "报道 Girls Coding Day",
		date: "2017-02-16",
	},
	{
		outlet: "联合国开发计划署驻华代表处",
		title: "入选「科技与慈善」项目",
		date: "2018-06-27",
	},
];

/** 合作企业：历史同行者清单（2017-2018 口径，只列名称，不暗示当前仍在合作） */
const PARTNERS: string[] = [
	"ThoughtWorks",
	"GitHub",
	"Yunbi",
	"NEO",
	"个推",
	"掘金",
	"WorldQuant",
];

/* ---------------- 活动/课程卡片（与 /events、/courses 发现页同款） ---------------- */

function OfferingCard({
	item,
	kind,
}: {
	item: PublicOfferingItem;
	kind: OfferingKind;
}) {
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
					{ENROLLMENT_POLICY_LABEL[item.enrollmentPolicy]} · 截止{" "}
					{formatDeadline(item.registrationDeadline)}
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
					查看全部 ›
				</Link>
			</div>
			{state.status === "loading" ? (
				<div className="mt-6 h-28 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
			) : state.status === "error" ? (
				<p className="mt-6 text-sm text-ink-3">
					暂时无法加载，<Link href={href} className="text-accent">直接前往列表页查看 ›</Link>
				</p>
			) : state.rows.length === 0 ? (
				<p className="mt-6 text-sm text-ink-3">
					暂无开放报名的条目，<Link href={href} className="text-accent">去列表页看看 ›</Link>
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
						活动
					</Link>
					<Link href="/courses" className="hover:text-ink">
						课程
					</Link>
				</nav>
				<div className="ml-auto flex items-center gap-3">
					<Link
						href="/login"
						className="text-sm text-ink-2 hover:text-ink"
					>
						登录
					</Link>
					<Link
						href="/register"
						className="join-button join-button--primary !min-h-9"
					>
						加入我们
					</Link>
				</div>
			</header>

			{/* Hero：30 年叙事主线 */}
			<section aria-labelledby="landing-hero-heading" className="mt-16">
				<p className="text-sm text-accent">
					Coding Girls Club · 程序媛汇
				</p>
				<h1
					id="landing-hero-heading"
					className="l-h1 mt-4 max-w-2xl"
				>
					从 2016 到 2046，陪一代女性走进编程
				</h1>
				<p className="l-p mt-6 max-w-2xl text-ink-2">
					程序媛汇（Coding Girls Club）创立于 2016 年，是一个帮助女性进入
					并留在科技领域的公益编程社群。2046 是我们给自己定的期限：
					把这件事认真做满三十年——一年一年地做，从一堂课、一次活动、
					一个可以互相求助的同伴开始。
				</p>
				<p className="mt-4 text-[13px] text-ink-3">
					截至 2018 年，我们走过 10 个城市、办了 50 场活动、
					陪伴 2500 名学员、与 500 位教练同行。
				</p>
				<div className="mt-8 flex items-center gap-3">
					<Link
						href="/register"
						className="join-button join-button--primary"
					>
						加入我们
					</Link>
					<Link
						href="/events"
						className="join-button join-button--outline"
					>
						看看正在进行的活动
					</Link>
				</div>
			</section>

			<OfferingSection
				kind="event"
				title="最新活动"
				description="面向所有人开放报名的社区活动。"
				href="/events"
				state={events}
			/>

			<OfferingSection
				kind="course"
				title="精选课程"
				description="零基础友好、长期陪伴的课程与成长营。"
				href="/courses"
				state={courses}
			/>

			{/* 媒体报道（静态文案，2017-2018 历史素材） */}
			<section aria-labelledby="landing-media-heading" className="mt-16">
				<h2 id="landing-media-heading" className="l-h2">
					媒体报道
				</h2>
				<p className="mt-2 text-sm text-ink-3">
					一路上被记录下来的片段（2017–2018）。
				</p>
				<ul className="mt-6 grid gap-3">
					{MEDIA_REPORTS.map((report) => (
						<li
							key={`${report.outlet}-${report.title}`}
							className="join-card !w-full !gap-1 !p-6"
						>
							<span className="text-sm font-medium">{report.title}</span>
							<span className="text-[13px] text-ink-3">
								{report.outlet} · {report.date}
							</span>
						</li>
					))}
				</ul>
			</section>

			{/* 合作企业（静态文案，历史同行者口径） */}
			<section aria-labelledby="landing-partners-heading" className="mt-16">
				<h2 id="landing-partners-heading" className="l-h2">
					合作企业
				</h2>
				<p className="mt-2 text-sm text-ink-3">
					曾经的同行者——感谢他们与我们并肩走过一程（2017–2018）。
				</p>
				<ul className="mt-6 flex flex-wrap gap-3">
					{PARTNERS.map((partner) => (
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
					下一个十年，从这里开始
				</h2>
				<p className="l-p mx-auto mt-3 max-w-xl text-ink-3">
					无论你刚开始写第一行代码，还是已经在行业里走了很远——
					这里都有一群同路的人。
				</p>
				<div className="mt-8 flex items-center justify-center gap-3">
					<Link
						href="/register"
						className="join-button join-button--primary"
					>
						注册账号
					</Link>
					<Link
						href="/login"
						className="join-button join-button--outline"
					>
						已有账号，去登录
					</Link>
				</div>
			</section>

			<footer className="mt-16 border-t border-line pt-6 text-[13px] text-ink-3">
				Coding Girls Club · 程序媛汇 — 2016 → 2046
			</footer>
		</main>
	);
}
