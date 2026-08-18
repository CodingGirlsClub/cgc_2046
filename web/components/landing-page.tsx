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

import Link from "next/link";
import { useEffect, useState } from "react";
import { fetchPublicOfferings } from "@/lib/public-offerings";
import type { OfferingKind, PublicOfferingItem } from "@/lib/graphql/events";
import { ENROLLMENT_POLICY_LABEL } from "@/lib/graphql/events";
import EventStatusTag from "@/components/event-status-tag";
import { formatDeadline } from "@/lib/events";

/* ---------------- 静态素材（2021 年版机构介绍 deck 权威清单，tower 拍板口径） ---------------- */

interface MediaReport {
	outlet: string;
	title: string;
	/** null = 仅列媒体+标题，不放链接（果壳网 PDF 内是公众号长链接） */
	url: string | null;
}

/** 媒体报道：权威版 6 条，除果壳网外均附原文链接 */
const MEDIA_REPORTS: MediaReport[] = [
	{
		outlet: "环球时报",
		title: "Ladies Who Code",
		url: "http://www.globaltimes.cn/content/954372.shtml",
	},
	{
		outlet: "中国日报",
		title: "Helping women to break social programming",
		url: "http://www.chinadaily.com.cn/china/2017-01/13/content_27943815.htm",
	},
	{
		outlet: "中国日报",
		title: "Looking to crack the unwritten code",
		url: "http://www.chinadaily.com.cn/china/2017-01/13/content_27943492.htm",
	},
	{
		outlet: "CCTV / CGTN",
		title: "Chinese women take on computer programming",
		url: "https://news.cgtn.com/news/3d49544e31516a4d/share_p.html",
	},
	{
		outlet: "36氪",
		title: "性别教育，反行业歧视，志愿者社群：那些正在为女性权益行动的人",
		url: "https://m.36kr.com/p/1129142659517446",
	},
	{
		outlet: "果壳网",
		title: "自学编程的故事与未来",
		url: null,
	},
];

/** 学术论文：与卡耐基梅隆大学学者合作，ICSE CHASE 2021 收录，IEEE 出版 */
const PAPER = {
	title:
		"Approaches to Diversifying the Programmer Community — The Case of the Girls Coding Day",
	venue: "与卡耐基梅隆大学学者合作 · ICSE CHASE 2021 · IEEE 出版",
	url: "https://www.computer.org/csdl/proceedings-article/chase/2021/140900a091/1tB7t8SZKcE",
};

/** 机构荣誉（报道与认可区块的荣誉行） */
const HONORS: string[] = [
	"2018 年入选联合国开发计划署「科技与慈善」项目案例集",
	"2019 年共青团中央「全国青年社会组织伙伴计划」获奖项目",
	"支持联合国开发计划署与联合国妇女署 #科技遇见她# 一小时编程挑战",
];

/** 合作伙伴：PDF logo 墙精选科技类 5 家（历史同行者口径，不暗示当前仍在合作） */
const PARTNERS: string[] = [
	"UNDP",
	"ThoughtWorks",
	"GitHub",
	"ByteDance",
	"FreeWheel",
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

			{/* Hero：组织历史 slogan（桥）+ 30 年叙事主线 */}
			<section aria-labelledby="landing-hero-heading" className="mt-16">
				<p className="text-sm text-accent">
					从 2016 到 2046，陪一代女性走进编程
				</p>
				<h1
					id="landing-hero-heading"
					className="l-h1 mt-4 max-w-2xl"
				>
					一桥飞架南北，天堑变通途
				</h1>
				<p className="l-h3 mt-6 max-w-2xl">
					Coding Girls Club · 程序媛汇，在女性与编程之间架一座桥。
				</p>
				<p className="l-p mt-6 max-w-2xl text-ink-2">
					程序媛汇创立于 2016 年，
					是一个帮助女性进入并留在科技领域的公益编程社群。2046 是我们给自己定的期限：
					把这件事认真做满三十年——一年一年地做，从一堂课、一次活动、
					一个可以互相求助的同伴开始。
				</p>
				<blockquote className="mt-6 max-w-2xl border-l-2 border-accent pl-4 text-sm text-ink-2">
					「以帮助女性数字赋能为使命，以平凡的姿态做不平凡的事情。」
					<span className="mt-1 block text-[13px] text-ink-3">
						—— 创始人 文洋
					</span>
				</blockquote>
				<p className="mt-6 text-[13px] text-ink-3">
					截至 2021 年，我们走过 10 个城市、办了 50+ 场线下工作坊、
					走进 17 所高校，陪伴 4000+ 名学员、与 1000+ 位教练同行。
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

			{/* 报道与认可（静态文案，2021 deck 权威素材） */}
			<section aria-labelledby="landing-media-heading" className="mt-16">
				<h2 id="landing-media-heading" className="l-h2">
					报道与认可
				</h2>
				<p className="mt-2 text-sm text-ink-3">
					一路上被记录、被研究、被认可的片段。
				</p>

				{/* 学术论文 */}
				<a
					href={PAPER.url}
					target="_blank"
					rel="noopener noreferrer"
					className="join-card mt-6 block !w-full !gap-1 !p-6"
				>
					<span className="text-sm font-medium">{PAPER.title}</span>
					<span className="text-[13px] text-ink-3">{PAPER.venue}</span>
				</a>

				{/* 媒体报道 */}
				<ul className="mt-3 grid gap-3">
					{MEDIA_REPORTS.map((report) => (
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
					{HONORS.map((honor) => (
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
					合作伙伴
				</h2>
				<p className="mt-2 text-sm text-ink-3">
					曾经的同行者——感谢他们与我们并肩走过一程。
				</p>
				<ul className="mt-6 flex flex-wrap justify-center gap-3">
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
					种一棵树最好的时机，是十年前；其次，是现在！
				</h2>
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
				<p>Coding Girls Club · 程序媛汇 — 2016 → 2046</p>
			</footer>
		</main>
	);
}
