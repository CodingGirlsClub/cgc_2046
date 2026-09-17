"use client";

import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import { client } from "@/lib/apollo-client";
import {
	FLASHBACK_PUBLIC_QUOTES,
	FLASHBACK_PUBLIC_STATS,
	type FlashbackPublicQuote,
	type FlashbackPublicStats,
} from "@/lib/graphql/flashback";
import RecoverForm from "./recover-form";
import { useStageTitleFocus } from "./use-reduced-motion";

/**
 * 闪念间公开首页（U6/R10/R32）：这件事是什么、我们是谁、统计层、匿名金句墙、
 * 自助找回入口。游客可读；无个人内容（路人看到故事与授权的名字，不是名单）。
 *
 * 空态设计（U6）：pilot 首日统计与金句必空——以「正在发生」进度叙事承接
 * （场次档案先于数字出现，回来的人从 0 开始计数本身就是叙事）。
 */
export default function PublicHome() {
	const t = useTranslations("flashback.home");
	const titleRef = useStageTitleFocus<HTMLHeadingElement>([]);

	const [stats, setStats] = useState<FlashbackPublicStats | null>(null);
	const [quotes, setQuotes] = useState<FlashbackPublicQuote[]>([]);

	useEffect(() => {
		client
			.query({ query: FLASHBACK_PUBLIC_STATS, fetchPolicy: "network-only" })
			.then(({ data }) => setStats(data?.flashbackPublicStats ?? null))
			.catch(() => setStats(null));
		client
			.query({ query: FLASHBACK_PUBLIC_QUOTES, fetchPolicy: "network-only" })
			.then(({ data }) => setQuotes(data?.flashbackPublicQuotes ?? []))
			.catch(() => setQuotes([]));
	}, []);

	const started = (stats?.returnedCount ?? 0) > 0 || (stats?.archives.length ?? 0) > 0;

	return (
		<div className="fb-root fb-public">
			<header className="fb-public-hero">
				<div className="fb-kicker">IN A FLASH · {t("kicker")}</div>
				<h1 className="fb-stage-title" ref={titleRef} tabIndex={-1}>
					{t("title")}
				</h1>
				<p className="fb-lead">{t("lead")}</p>
				<p className="fb-hint">{t("whoAreWe")}</p>
			</header>

			<section className="fb-public-stats" aria-labelledby="fb-stats-title">
				<h2 id="fb-stats-title" className="fb-action-title">
					{t("statsTitle")}
				</h2>
				{stats && stats.archives.length > 0 ? (
					<>
						<ul className="fb-public-archives">
							{stats.archives.map((archive) => (
								<li key={archive.key}>
									{archive.occurredOn?.replace(/-/g, ".") ?? archive.key} · {archive.name}
									{archive.city ? ` · ${archive.city}` : ""} ·{" "}
									{t("archiveCounts", {
										applied: archive.appliedCount ?? 0,
										attended: archive.attendedCount ?? 0,
									})}
								</li>
							))}
						</ul>
						<p className="fb-hint">{t("returned", { count: stats.returnedCount, sent: stats.sentCount })}</p>
					</>
				) : (
					/* 空态（U6 设计）：「正在发生」进度叙事，不渲染空数字 */
					<p className="fb-public-empty" data-testid="fb-stats-empty">
						{started ? t("statsStarted") : t("statsEmpty")}
					</p>
				)}
			</section>

			<section className="fb-public-quotes" aria-labelledby="fb-quotes-title">
				<h2 id="fb-quotes-title" className="fb-action-title">
					{t("quotesTitle")}
				</h2>
				{quotes.length > 0 ? (
					<ul className="fb-quote-wall">
						{quotes.map((quote, index) => (
							<li key={`${quote.attribution}:${index}`} className="fb-quote-item">
								<blockquote className="fb-quote-text">“{quote.text}”</blockquote>
								<cite className="fb-quote-cite">
									{quote.publicSlug ? (
										<Link href={`/flashback/${quote.publicSlug}`}>{quote.attribution}</Link>
									) : (
										quote.attribution
									)}
								</cite>
							</li>
						))}
					</ul>
				) : (
					<p className="fb-public-empty" data-testid="fb-quotes-empty">
						{t("quotesEmpty")}
					</p>
				)}
			</section>

			<RecoverForm />

			<footer className="fb-capsule-footer">
				<p className="fb-hint">{t("footer")}</p>
			</footer>
		</div>
	);
}
