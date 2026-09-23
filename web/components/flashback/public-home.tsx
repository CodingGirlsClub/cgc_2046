"use client";

import { useCallback, useEffect, useState, useSyncExternalStore } from "react";
import { useTranslations } from "next-intl";
import { useMutation } from "@apollo/client/react";
import { Link } from "@/i18n/navigation";
import { client } from "@/lib/apollo-client";
import { ensureVoterKey } from "@/lib/flashback-voter";
import {
	FLASHBACK_LIKE_QUOTE,
	FLASHBACK_PUBLIC_STATS,
	FLASHBACK_RANDOM_QUOTES,
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
 *
 * 点赞（R36）：路人与登录用户都可点，去重键 = localStorage 里的设备键
 * （`a:<uuid>`，见 lib/flashback-voter.ts）——公开页不做鉴权读取，服务端只校验
 * 格式，唯一约束兜底。点击即就地 ±1（乐观更新，失败回滚）；**不就地重排**：
 * 排序是服务端涌现口径（点赞数优先），点一下就跳位会让人找不到刚点的那句，
 * 下次加载自然归位。
 */
export default function PublicHome() {
	const t = useTranslations("flashback.home");
	const titleRef = useStageTitleFocus<HTMLHeadingElement>([]);

	const [stats, setStats] = useState<FlashbackPublicStats | null>(null);
	const [quotes, setQuotes] = useState<FlashbackPublicQuote[]>([]);
	// 去重键（R36）：客户端快照 = 读或生成一次后落盘（幂等，React 多次取快照同值）；
	// SSR/首帧用服务端快照 null（不渲染按钮），客户端随即纠正——同一手法见
	// usePrefersReducedMotion / 名册显影能力探测，避免在 effect 里 setState。
	const voter = useSyncExternalStore(
		() => () => {},
		() => ensureVoterKey(window.localStorage),
		() => null,
	);
	const [pending, setPending] = useState<ReadonlySet<string>>(() => new Set());
	const [runLike] = useMutation(FLASHBACK_LIKE_QUOTE);

	useEffect(() => {
		client
			.query({ query: FLASHBACK_PUBLIC_STATS, fetchPolicy: "network-only" })
			.then(({ data }) => setStats(data?.flashbackPublicStats ?? null))
			.catch(() => setStats(null));

		// R26：落地页金句段 = 随机几句（非精选、非全量）+「看全墙 →」导流
		client
			.query({
				query: FLASHBACK_RANDOM_QUOTES,
				variables: { limit: 3, voterKey: ensureVoterKey(window.localStorage) },
				fetchPolicy: "network-only",
			})
			.then(({ data }) => setQuotes(data?.flashbackRandomQuotes ?? []))
			.catch(() => setQuotes([]));
	}, []);

	/** 点赞开关（R36/R37）：乐观 ±1 → 服务端计数校正 → 失败按 quoteId 函数式回滚（#806 F2） */
	const toggleLike = useCallback(
		(quote: FlashbackPublicQuote) => {
			if (!voter || pending.has(quote.quoteId)) return;
			const liked = !quote.likedByViewer;
			const prevLike = { liked: quote.likedByViewer, count: quote.likeCount };
			setQuotes(
				quotes.map((item) =>
					item.quoteId === quote.quoteId
						? { ...item, likedByViewer: liked, likeCount: Math.max(0, item.likeCount + (liked ? 1 : -1)) }
						: item,
				),
			);
			setPending((prev) => new Set([...prev, quote.quoteId]));

			runLike({ variables: { quoteId: quote.quoteId, voterKey: voter, liked } })
				.then(({ data }) => {
					const count = data?.flashbackLikeQuote?.likeCount;
					if (typeof count !== "number") return;
					setQuotes((current) =>
						current.map((item) =>
							item.quoteId === quote.quoteId ? { ...item, likeCount: count } : item,
						),
					);
				})
				.catch(() =>
					// #806 F2：失败回滚只恢复该条（函数式——保留并发期间其他条的更新）
					setQuotes((current) =>
						current.map((item) =>
							item.quoteId === quote.quoteId
								? { ...item, likedByViewer: prevLike.liked, likeCount: prevLike.count }
								: item,
						),
					),
				)
				.finally(() =>
					setPending((prev) => {
						const next = new Set(prev);
						next.delete(quote.quoteId);
						return next;
					}),
				);
		},
		[pending, quotes, runLike, voter],
	);

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

			{/* 品牌词「闪念间」走 flashback.home.kicker（i18n 单源，不硬编码） */}
			<section className="fb-public-quotes" aria-labelledby="fb-quotes-title">
				<h2 id="fb-quotes-title" className="fb-action-title">
					{t("quotesTitle")}
				</h2>
				{/* U5/R26：随机几句（非精选、非全量）+ 看全墙导流 */}
				{quotes.length > 0 ? (
					<ul className="fb-quote-wall">
						{quotes.map((quote) => (
							<li key={quote.quoteId} className="fb-quote-item">
								<blockquote className="fb-quote-text">“{quote.text}”</blockquote>
								<cite className="fb-quote-cite">
									{quote.publicSlug ? (
										<Link href={`/flashback/${quote.publicSlug}`}>{quote.attribution}</Link>
									) : (
										quote.attribution
									)}
								</cite>
								{/* 点赞（R36）：♡/♥ + 实时计数；未拿到去重键（禁用存储）不渲染 */}
								{voter && (
									<button
										type="button"
										className={`fb-quote-like${quote.likedByViewer ? " fb-quote-like--on" : ""}`}
										data-testid="fb-quote-like"
										data-liked={quote.likedByViewer ? "true" : "false"}
										aria-pressed={quote.likedByViewer}
										aria-label={t("likeAria", { count: quote.likeCount })}
										disabled={pending.has(quote.quoteId)}
										onClick={() => toggleLike(quote)}
									>
										<span aria-hidden="true">{quote.likedByViewer ? "♥" : "♡"}</span>
										<span className="fb-quote-like-count">{quote.likeCount}</span>
									</button>
								)}
							</li>
						))}
					</ul>
				) : (
					<p className="fb-public-empty" data-testid="fb-quotes-empty">
						{t("quotesEmpty")}
					</p>
				)}
				<p className="fb-quotes-wall-cta">
					<Link href="/flashback/voices" data-testid="fb-quotes-wall-cta">
						{t("quotesWallCta")}
					</Link>
				</p>
			</section>

			<RecoverForm />

			<footer className="fb-capsule-footer">
				<p className="fb-hint">{t("footer")}</p>
			</footer>
		</div>
	);
}
