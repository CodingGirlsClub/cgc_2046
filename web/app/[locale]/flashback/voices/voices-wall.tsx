"use client";

import { useCallback, useEffect, useRef, useState, useSyncExternalStore, type CSSProperties, type ReactNode } from "react";
import { useTranslations } from "next-intl";
import { useMutation } from "@apollo/client/react";
import FlashbackNav from "@/components/flashback/flashback-nav";
import { Link } from "@/i18n/navigation";
import { client } from "@/lib/apollo-client";
import { ensureVoterKey } from "@/lib/flashback-voter";
import {
	FLASHBACK_LIKE_QUOTE,
	FLASHBACK_PUBLIC_QUOTES,
	FLASHBACK_VOICE_CITIES,
	FLASHBACK_RANDOM_QUOTES,
	type FlashbackPublicQuote,
} from "@/lib/graphql/flashback";
import { usePrefersReducedMotion } from "@/components/flashback/use-reduced-motion";
import MapScene from "./map-scene";
import styles from "./voices.module.css";

/**
 * 金句墙生产页（R5–R14、R22–R24、R26–R29、R35、R37）：
 *
 * - 四幕开场（源起 → 流向远方 → 山河渐醒 → 天光满树），可跳过/点城市中断/
 *   重播；`prefers-reduced-motion` 直接白昼（R24）；`?item=` 分享直达抑制
 *   开场（R7/KTD4）；回访记忆 = localStorage `flashback.voicesIntroSeen`
 *   （执行时定值，见计划 Open Questions）；
 * - 数据接 GraphQL 真实面：涌现序 top 60（FLASHBACK_PUBLIC_QUOTES）+
 *   「随便听听」随机入口（FLASHBACK_RANDOM_QUOTES，会话内不重复）；
 * - 点赞按句（quoteId），乐观 ±1 → 服务端校正 → 失败回滚（R11/R29）；
 * - 首赞后一次性转化轻提示（R27，sessionStorage 每会话一次）；
 * - 加载/失败/空态三分支；失效 item 由 page.tsx 服务端判定后走失效视图（U4）。
 */

const INTRO_SEEN_KEY = "flashback.voicesIntroSeen";
const LIKE_HINT_KEY = "flashback.voicesLikeHintShown";
const INTRO_DURATION_MS = 6400;

const STAGE_KEYS = [
	{ name: "stage1Name", text: "stage1Text", at: 0.05 },
	{ name: "stage2Name", text: "stage2Text", at: 0.34 },
	{ name: "stage3Name", text: "stage3Text", at: 0.64 },
	{ name: "stage4Name", text: "stage4Text", at: 1 },
] as const;

function Icon({ name, filled = false }: { name: string; filled?: boolean }) {
	const paths: Record<string, ReactNode> = {
		heart: (
			<path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1.1-1.1a5.5 5.5 0 0 0-7.8 7.8L12 21l8.8-8.6a5.5 5.5 0 0 0 0-7.8Z" />
		),
		share: (
			<>
				<path d="M12 16V2m-4 4 4-4 4 4M5 10H3v11h18V10h-2" />
			</>
		),
		arrow: <path d="M3 12h18m-6-6 6 6-6 6" />,
		back: <path d="M21 12H3m6-6-6 6 6 6" />,
		replay: (
			<>
				<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8" />
				<path d="M3 3v5h5" />
			</>
		),
		close: <path d="m5 5 14 14M19 5 5 19" />,
		check: <path d="m4 12 5 5L20 6" />,
		shuffle: (
			<>
				<path d="M16 3h5v5M4 20 21 3M21 16v5h-5M15 15l6 6M4 4l5 5" />
			</>
		),
	};
	return (
		<svg
			width="20"
			height="20"
			viewBox="0 0 24 24"
			fill={filled ? "currentColor" : "none"}
			stroke="currentColor"
			strokeWidth="1.5"
			strokeLinecap="round"
			strokeLinejoin="round"
			aria-hidden="true"
		>
			{paths[name] || paths.arrow}
		</svg>
	);
}

function ShareDialog({
	quote,
	wall,
	onClose,
}: {
	quote: FlashbackPublicQuote | null;
	wall: boolean;
	onClose: () => void;
}) {
	const t = useTranslations("flashback.voices");
	const ref = useRef<HTMLDialogElement>(null);
	const [copied, setCopied] = useState(false);
	const [failed, setFailed] = useState(false);

	useEffect(() => {
		ref.current?.showModal();
	}, []);

	// KTD4：单句链接 = /flashback/voices?item=<quote_id>；整墙不带 item。
	const shareUrl = (() => {
		if (typeof window === "undefined") return "";
		const url = new URL(window.location.href);
		url.search = "";
		if (!wall && quote) url.searchParams.set("item", quote.quoteId);
		return url.toString();
	})();

	return (
		<dialog
			ref={ref}
			className={styles.dialog}
			onCancel={onClose}
			onClose={onClose}
			onClick={(event) => {
				if (event.target === event.currentTarget) onClose();
			}}
			aria-label={t("shareDialogTitle")}
		>
			<div className={styles.dialogInner}>
				<div className={styles.dialogHeader}>
					<span>{t("shareDialogTitle")}</span>
					<button type="button" onClick={onClose} aria-label={t("close")}>
						<Icon name="close" />
					</button>
				</div>
				{wall ? (
					<h2>{t("shareWallHeading")}</h2>
				) : (
					<>
						<p className={styles.eyebrow}>{quote?.attribution}</p>
						<h2>{quote?.text}</h2>
						<p>{t("shareQuoteHeading")}</p>
					</>
				)}
				<label className={styles.field}>
					{t("shareLinkLabel")}
					<input readOnly value={shareUrl} onFocus={(e) => e.target.select()} />
				</label>
				<button
					type="button"
					className={styles.primary}
					onClick={async () => {
						try {
							await navigator.clipboard.writeText(shareUrl);
							setCopied(true);
						} catch {
							setFailed(true);
						}
					}}
				>
					<Icon name={copied ? "check" : "share"} />
					{copied ? t("copied") : t("copyLink")}
				</button>
				{failed && <small className={styles.dialogNote}>{t("copyFallback")}</small>}
			</div>
		</dialog>
	);
}

export default function VoicesWall({
	initialItem,
	showIntro,
	initialCity,
}: {
	/** 分享直达的目标句（已在服务端确认有效）；undefined = 非直达 */
	initialItem?: FlashbackPublicQuote;
	/** 是否播开场（page.tsx 已按 item/回访记忆/reduced-motion 排除） */
	showIntro: boolean;
	/** wish2 U7/G10：?city= 入 URL 的初始城市（item 直达的城市优先） */
	initialCity?: string;
}) {
	const t = useTranslations("flashback.voices");
	const reducedMotion = usePrefersReducedMotion();

	const [quotes, setQuotes] = useState<FlashbackPublicQuote[]>(initialItem ? [initialItem] : []);
	const [loadState, setLoadState] = useState<"loading" | "ready" | "failed">("loading");
	const [currentId, setCurrentId] = useState<string | null>(initialItem?.quoteId ?? null);
	const [city, setCity] = useState<string>(initialItem?.city ?? initialCity ?? "");
	const [progress, setProgress] = useState(showIntro ? 0 : 1);
	const [playing, setPlaying] = useState(showIntro);
	const [playback, setPlayback] = useState(0);
	const [pulse, setPulse] = useState(0);
	const [toast, setToast] = useState("");
	const [shareDialog, setShareDialog] = useState<"quote" | "wall" | null>(null);
	const [likeHint, setLikeHint] = useState(false);
	const [pending, setPending] = useState<ReadonlySet<string>>(() => new Set());
	// 「随便听听」会话内不重复（R35）：已**由随机入口**出过的 quoteId 集合。
	// 不预置墙上列表——后端 randomQuotes 与 publicQuotes 同池（public.ex 仅排序不同），
	// 公开句总量 ≤ 60 时墙即全量，预置会让随机池恒空、首次点击即报 randomEmpty（#822）。
	const [randomSeen, setRandomSeen] = useState<ReadonlySet<string>>(
		() => new Set(initialItem ? [initialItem.quoteId] : []),
	);
	const [randomQueue, setRandomQueue] = useState<FlashbackPublicQuote[]>([]);
	// M10：城市真源 = flashbackVoiceCities（有金句的城市全集，坐标服务端下发），
	// 不再依赖前端 45 城静态表——冷门城市也能选、地图也有点
	const [voiceCities, setVoiceCities] = useState<Array<{ name: string; lng: number; lat: number }>>([]);

	const progressRef = useRef(progress);
	const quoteAreaRef = useRef<HTMLDivElement>(null);
	// intro 塌缩页面（workspace 变 block、reader 隐藏）会把 scrollY/quoteArea.scrollTop 钳到 0：
	// replay 前保存，finishIntro 恢复（首次进入 intro 无保存值，跳过）
	const scrollRestoreRef = useRef<{ y: number; quote: number } | null>(null);
	const [runLike] = useMutation(FLASHBACK_LIKE_QUOTE);

	// 去重键（R36）：SSR/首帧 null（不渲染按钮），客户端纠正（同 public-home 手法）
	const voter = useSyncExternalStore(
		() => () => {},
		() => ensureVoterKey(window.localStorage),
		() => null,
	);

	const current = quotes.find((q) => q.quoteId === currentId) ?? quotes[0] ?? null;
	const currentIndex = current ? quotes.findIndex((q) => q.quoteId === current.quoteId) : -1;

	// 城市清单：服务端真源（M10），不再按已加载样本 ∩ 静态坐标表近似
	const cities = voiceCities;
	const cityNames = cities.map((c) => c.name);

	const markIntroSeen = useCallback(() => {
		try {
			window.localStorage.setItem(INTRO_SEEN_KEY, "1");
		} catch {
			// 存储不可用：每次进都播开场（可跳过），不阻断
		}
	}, []);

	const finishIntro = useCallback(() => {
		setPlaying(false);
		setProgress(1);
		progressRef.current = 1;
		markIntroSeen();
		const restore = scrollRestoreRef.current;
		scrollRestoreRef.current = null;
		if (restore) {
			// setProgress(1) 的白天布局尚未 commit：此刻滚动会被塌缩态高度钳回 0，
			// 双 rAF 等布局还原后再恢复
			requestAnimationFrame(() =>
				requestAnimationFrame(() => {
					window.scrollTo(0, restore.y);
					quoteAreaRef.current?.scrollTo({ top: restore.quote });
				}),
			);
		}
	}, [markIntroSeen]);

	// 减少动态效果（R24）：displayProgress 派生恒 1（白昼），无 setState——
	// progress 状态保留给「重看山河亮起」（非 reduced 用户可重播）。
	const displayProgress = reducedMotion ? 1 : progress;
	const isIntro = displayProgress < 1;

	// 开场播放：progress 按墙钟推进（弱机掉帧不拖长）
	useEffect(() => {
		if (!playing) return;
		let frame = 0;
		let cancelled = false;
		const start = performance.now() - progressRef.current * INTRO_DURATION_MS;
		const tick = (now: number) => {
			if (cancelled) return;
			const p = Math.min(1, (now - start) / INTRO_DURATION_MS);
			progressRef.current = p;
			setProgress(p);
			if (p < 1) frame = requestAnimationFrame(tick);
			else finishIntro();
		};
		frame = requestAnimationFrame(tick);
		return () => {
			cancelled = true;
			cancelAnimationFrame(frame);
		};
	}, [playing, playback, finishIntro]);

	// 数据加载（失败可重试）：loadGeneration 驱动（重试 = 递增），
	// setState 全部在 query promise 回调内（不在 effect 体内同步调用）。
	const [loadGeneration, setLoadGeneration] = useState(0);

	useEffect(() => {
		let cancelled = false;
		client
			.query({
				query: FLASHBACK_PUBLIC_QUOTES,
				// M10：城市筛选先于热门限量（服务端），选城即重拉
				variables: { voterKey: ensureVoterKey(window.localStorage), city: city || null },
				fetchPolicy: "network-only",
			})
			.then(({ data }) => {
				if (cancelled) return;
				const list = data?.flashbackPublicQuotes ?? [];
				// 分享直达句若不在 top 60（低热度），保留在列表头（直达语义优先）
				setQuotes(initialItem && !list.some((q) => q.quoteId === initialItem.quoteId)
					? [initialItem, ...list]
					: list);
				setLoadState("ready");
				setCurrentId((id) => (id && list.some((q) => q.quoteId === id) ? id : initialItem?.quoteId ?? list[0]?.quoteId ?? null));
			})
			.catch(() => {
				if (!cancelled) setLoadState("failed");
			});
		return () => {
			cancelled = true;
		};
	}, [loadGeneration, initialItem, city]);

	const retryLoad = () => {
		setLoadState("loading");
		setLoadGeneration((n) => n + 1);
	};

	// M10：城市栏 + 地图点位 = 服务端城市全集（挂载取一次；授权变化由刷新入口兜底）
	useEffect(() => {
		let cancelled = false;
		client
			.query({ query: FLASHBACK_VOICE_CITIES, fetchPolicy: "network-only" })
			.then(({ data }) => {
				if (cancelled) return;
				setVoiceCities(
					(data?.flashbackVoiceCities ?? []).map((c) => ({ name: c.name, lng: c.lngLat[0], lat: c.lngLat[1] })),
				);
			})
			.catch(() => {
				// 城市栏取不到不阻断阅读——地图/城市栏隐藏，列表仍可用
			});
		return () => {
			cancelled = true;
		};
	}, []);

	// toast 自动消失
	useEffect(() => {
		if (!toast) return;
		const timer = window.setTimeout(() => setToast(""), 3400);
		return () => window.clearTimeout(timer);
	}, [toast]);

	const select = useCallback(
		(quote: FlashbackPublicQuote) => {
			finishIntro();
			setCurrentId(quote.quoteId);
			// M10：city 是服务端筛选（改动即重拉），阅读位置移动不再连带改筛选——
			// 否则导航到邻城的句子会把列表收缩成单城，上一句/下一句卡死
			setPulse(0);
		},
		[finishIntro],
	);

	// R21：城市入 URL（?city= 写回）——voices↔wishes 互跳与刷新保留当前城市；
	// replaceState 不触发导航（软更新，与既有 useState 单源不冲突）
	const syncCityToUrl = useCallback((next: string) => {
		try {
			const url = new URL(window.location.href);
			if (next) url.searchParams.set("city", next);
			else url.searchParams.delete("city");
			window.history.replaceState(null, "", url.toString());
		} catch {
			// storage/URL 不可用：不阻断选城
		}
	}, []);

	// M10：选城 = 改服务端筛选（重拉），不再在已加载样本里就近挑句
	const selectCity = (next: string) => {
		syncCityToUrl(next);
		setCurrentId(null);
		setCity((prev) => (prev === next ? prev : next));
	};

	const navigate = (step: number) => {
		if (quotes.length === 0) return;
		const next = quotes[(Math.max(0, currentIndex) + step + quotes.length) % quotes.length];
		select(next);
	};

	// 点赞（R11/R29）：乐观 ±1 → 服务端校正 → 失败按 quoteId 函数式回滚（#806 F2：
	// 不用整组快照——并发期间其他句的成功更新不被覆盖）；不就地重排
	const toggleLike = (quote: FlashbackPublicQuote) => {
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

		// R27：首赞后一次性转化轻提示（每会话一次，可忽略、自动消失）
		if (liked) {
			try {
				if (!window.sessionStorage.getItem(LIKE_HINT_KEY)) {
					window.sessionStorage.setItem(LIKE_HINT_KEY, "1");
					setLikeHint(true);
				}
			} catch {
				// 存储不可用：不出提示（不阻断点赞）
			}
			if (!reducedMotion) setPulse((n) => n + 1);
			setToast(t("likeThanks"));
		}

		runLike({ variables: { quoteId: quote.quoteId, voterKey: voter, liked } })
			.then(({ data }) => {
				const count = data?.flashbackLikeQuote?.likeCount;
				if (typeof count !== "number") return;
				setQuotes((current) =>
					current.map((item) => (item.quoteId === quote.quoteId ? { ...item, likeCount: count } : item)),
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
	};

	// 随便听听（R35）：随机取 3 句（会话内不重复），逐句进入浏览
	const randomListen = () => {
		const queued = randomQueue.find((q) => !randomSeen.has(q.quoteId));
		if (queued) {
			setRandomQueue((q) => q.filter((item) => item.quoteId !== queued.quoteId));
			setRandomSeen((seen) => new Set([...seen, queued.quoteId]));
			setQuotes((prev) => (prev.some((q) => q.quoteId === queued.quoteId) ? prev : [...prev, queued]));
			select(queued);
			return;
		}
		client
			.query({
				query: FLASHBACK_RANDOM_QUOTES,
				variables: { limit: 3, voterKey: voter },
				fetchPolicy: "network-only",
			})
			.then(({ data }) => {
				const fresh = (data?.flashbackRandomQuotes ?? []).filter((q) => !randomSeen.has(q.quoteId));
				if (fresh.length === 0) {
					setToast(t("randomEmpty"));
					return;
				}
				const [first, ...rest] = fresh;
				setRandomQueue(rest);
				setRandomSeen((seen) => new Set([...seen, ...fresh.map((q) => q.quoteId)]));
				setQuotes((prev) => {
					const known = new Set(prev.map((q) => q.quoteId));
					return [...prev, ...fresh.filter((q) => !known.has(q.quoteId))];
				});
				select(first);
			})
			.catch(() => setToast(t("loadFailed")));
	};

	const replay = () => {
		if (reducedMotion) {
			setToast(t("replayReduced"));
			return;
		}
		scrollRestoreRef.current = { y: window.scrollY, quote: quoteAreaRef.current?.scrollTop ?? 0 };
		progressRef.current = 0;
		setProgress(0);
		setPlaying(true);
		setPlayback((n) => n + 1);
	};

	const stage = displayProgress < 0.18 ? 0 : displayProgress < 0.46 ? 1 : displayProgress < 0.86 ? 2 : 3;
	const daylight = Math.min(1, Math.max(0, (displayProgress - 0.87) / 0.13));

	// ── 失败态（可重试） ────────────────────────────────────────────────
	if (loadState === "failed") {
		return (
			<div className={styles.prototype}>
				<div className={styles.viewport}>
					<div className={styles.app} style={{ "--daylight": 1 } as CSSProperties}>
						<main className={styles.statePage}>
							<p className={styles.eyebrow}>{t("mapEyebrow")}</p>
							<h1>{t("loadFailed")}</h1>
							<button type="button" className={styles.primary} onClick={retryLoad}>
								<Icon name="replay" />
								{t("retry")}
							</button>
						</main>
					</div>
				</div>
			</div>
		);
	}

	// ── 空态（无授权句的空墙文案，不报错） ──────────────────────────────
	if (loadState === "ready" && quotes.length === 0) {
		return (
			<div className={styles.prototype}>
				<div className={styles.viewport}>
					<div className={styles.app} style={{ "--daylight": 1 } as CSSProperties}>
						<main className={styles.statePage}>
							<p className={styles.eyebrow}>{t("mapEyebrow")}</p>
							<h1>{t("mapTitle")}</h1>
							<p data-testid="voices-empty">{t("emptyWall")}</p>
							<Link href="/flashback#recover" className={styles.primaryLink}>
								{t("emptyWallCta")}
							</Link>
						</main>
					</div>
				</div>
			</div>
		);
	}

	return (
		<div className={styles.prototype}>
			<div className={styles.viewport}>
				<div
					className={`${styles.app} ${isIntro ? styles.inIntro : ""} ${isIntro && displayProgress > 0.94 ? styles.dayText : ""}`}
					style={{ "--daylight": daylight } as CSSProperties}
				>
					<div className={styles.atmosphere} />
					<a className={styles.skipLink} href="#voices-reading">
						{t("skipToReading")}
					</a>
					<FlashbackNav active="voices" city={city}>
							{isIntro ? (
								<button type="button" onClick={finishIntro}>
									{t("skipIntro")} <Icon name="arrow" />
								</button>
							) : (
								<button type="button" onClick={() => setShareDialog("wall")} aria-label={t("shareWall")}>
									<Icon name="share" />
									<span>{t("shareWall")}</span>
								</button>
							)}
						</FlashbackNav>

					<main className={styles.workspace}>
						<section className={styles.mapSection} aria-label={t("mapAria")}>
							<div className={styles.mapHeading}>
								<div>
									<p className={styles.eyebrow}>{t("mapEyebrow")}</p>
									<h1>{t("mapTitle")}</h1>
								</div>
								<span className={styles.mapTag}>{t("voicesCount", { count: quotes.length })}</span>
							</div>
							<MapScene cities={cities} city={city} progress={displayProgress} onCity={selectCity} pulse={pulse} />
							{isIntro && (
								<div className={styles.introCaption}>
									<p className={styles.eyebrow}>{t("introEyebrow")}</p>
									<h1>
										<span>0{stage + 1}</span> {t(STAGE_KEYS[stage].name)}
									</h1>
									<p>{t(STAGE_KEYS[stage].text)}</p>
									<small>{t("introHint")}</small>
								</div>
							)}
							<div className={styles.mapFoot}>
								<span>
									<i />
									{t("legendTerrain")}
								</span>
								<span>
									<i />
									{t("legendConnection")}
								</span>

							</div>
							{cityNames.length > 0 && (
								<div className={styles.mapToolbar}>
								<div className={styles.cityBar} aria-label={t("cityBarLabel")}>
									<span>{t("cityBarLabel")}</span>
									{cityNames.map((name) => (
										<button
											key={name}
											type="button"
											onClick={() => selectCity(name)}
											aria-pressed={city === name}
										>
											{name}
										</button>
									))}
								</div>
								<button type="button" className={styles.replayButton} onClick={replay}>
									<Icon name="replay" /><span>{t("replay")}</span>
								</button>
								</div>
							)}
						</section>

						<section className={styles.reader} id="voices-reading" tabIndex={-1} aria-label={t("readerEyebrow")}>
							{loadState === "loading" || !current ? (
								<p className={styles.loading} data-testid="voices-loading">
									{t("loading")}
								</p>
							) : (
								<>
									<div className={styles.readerTop}>
										<p className={styles.eyebrow}>
											{t("readerEyebrow")}
											<span />
										</p>
										<span className={styles.location}>{current.city ?? city}</span>
									</div>
									<div className={styles.quoteArea} ref={quoteAreaRef}>
										<blockquote className={styles.quote} data-testid="selected-text">
											<span className={styles.quoteMark} aria-hidden="true">
												“
											</span>
											{current.text}
										</blockquote>
									</div>
									<p className={styles.attribution}>
										{current.publicSlug ? (
											<Link href={`/flashback/${current.publicSlug}`} data-testid="quote-attribution-link">
												{current.attribution}
											</Link>
										) : (
											current.attribution
										)}
									</p>
									<div className={styles.reactions}>
										{voter && (
											<button
												type="button"
												className={styles.likeButton}
												onClick={() => toggleLike(current)}
												aria-pressed={current.likedByViewer}
												aria-label={t("like")}
												disabled={pending.has(current.quoteId)}
												data-testid="quote-like"
											>
												<Icon name="heart" filled={current.likedByViewer} />
												{current.likeCount}
											</button>
										)}
										<button
											type="button"
											className={styles.primary}
											onClick={() => setShareDialog("quote")}
											data-testid="share-quote"
										>
											<Icon name="share" />
											{t("shareQuote")}
										</button>
									</div>
									<div className={styles.pagination}>
										<button type="button" onClick={() => navigate(-1)} aria-label={t("prev")}>
											<Icon name="back" />
											<span>{t("prev")}</span>
										</button>
										<div className={styles.randomWrap}>
											<button type="button" className={styles.randomLink} onClick={randomListen} data-testid="random-listen">
												<Icon name="shuffle" />
												{t("random")}
											</button>
											<span className={styles.randomCount}>
												{String(Math.max(0, currentIndex) + 1).padStart(2, "0")}
												<i>/</i>
												{String(quotes.length).padStart(2, "0")}
											</span>
										</div>
										<button type="button" onClick={() => navigate(1)} aria-label={t("next")}>
											<span>{t("next")}</span>
											<Icon name="arrow" />
										</button>
									</div>
									<p className={styles.disclosure}>{t("disclosureOrigin")}<br />{t("disclosureEcho")}</p>
									<footer className={styles.readerFooter}>
										<Link href="/flashback#recover">{t("recover")}<Icon name="arrow" /></Link>
										<Link href={city ? `/flashback/wishes?city=${encodeURIComponent(city)}` : "/flashback/wishes"}>{t("wishesFooter")}<Icon name="arrow" /></Link>
									</footer>
								</>
							)}
						</section>
					</main>
					{isIntro && (
						<div className={styles.introTrack}>
							{STAGE_KEYS.map((s, i) => (
								<button
									key={s.name}
									type="button"
									aria-pressed={stage === i}
									onClick={() => {
										setPlaying(false);
										progressRef.current = s.at;
										setProgress(s.at);
									}}
								>
									<span>0{i + 1}</span>
									{t(s.name)}
								</button>
							))}
							<div className={styles.trackFill} style={{ transform: `scaleX(${displayProgress})` }} />
						</div>
					)}
				</div>
			</div>

			<div className={styles.toast} role="status" aria-live="polite" data-visible={!!toast}>
				{toast}
			</div>

			{/* R27 赞后转化轻提示：不打断、可忽略、自动消失（每会话一次） */}
			{likeHint && (
				<div className={styles.likeHint} role="status" data-testid="like-hint">
					<p>{t("recoverHint")}</p>
					<Link href="/flashback#recover" onClick={() => setLikeHint(false)}>
						{t("recoverCta")}
					</Link>
					<button type="button" onClick={() => setLikeHint(false)} aria-label={t("dismiss")}>
						<Icon name="close" />
					</button>
				</div>
			)}

			{shareDialog && (
				<ShareDialog
					quote={shareDialog === "quote" ? current : null}
					wall={shareDialog === "wall"}
					onClose={() => setShareDialog(null)}
				/>
			)}
		</div>
	);
}
