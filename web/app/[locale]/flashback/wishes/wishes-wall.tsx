"use client";

import { useCallback, useEffect, useMemo, useState, useSyncExternalStore, type ReactNode } from "react";
import { useTranslations } from "next-intl";
import { useMutation } from "@apollo/client/react";
import FlashbackNav from "@/components/flashback/flashback-nav";
import { Link } from "@/i18n/navigation";
import { client } from "@/lib/apollo-client";
import { useAuthed } from "@/lib/auth-provider";
import { ensureVoterKey } from "@/lib/flashback-voter";
import { WishFormModal } from "@/components/flashback/wish-frames";
import {
	FLASHBACK_WISH_CITIES,
	FLASHBACK_EXPECT_WISH,
	FLASHBACK_MY_WISHES,
	FLASHBACK_PUBLIC_WISHES,
	FLASHBACK_REPORT_WISH,
	type FlashbackPublicWish,
} from "@/lib/graphql/flashback";
import MapScene, { type CitySpec } from "../voices/map-scene";
import styles from "./wishes.module.css";
import { WishEchoCard } from "@/components/flashback/wish-echo-card";

const WISHES_INTRO_SEEN_KEY = "flashback.wishesIntroSeen";
const VOICES_INTRO_SEEN_KEY = "flashback.voicesIntroSeen";
const REPORT_REASONS = ["spam", "irrelevant", "scam", "inappropriate", "other"] as const;
/** L7：公开树每页条数（对齐小程序 flashbackPublicWishes 每页 24） */
const PAGE_SIZE = 24;

/** 与 voices 同一几何语言（24 viewBox / stroke 1.5 / 圆角端点）的局部图标表 */
const ICONS: Record<string, ReactNode> = {
	share: <path d="M12 3v12M8 7l4-4 4 4M5 13v6a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-6" />,
	heart: <path d="M19.5 12.6 12 20l-7.5-7.4a5 5 0 1 1 7.5-6.6 5 5 0 1 1 7.5 6.6Z" />,
	pen: <path d="M12 20h9M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z" />,
	shuffle: <path d="M16 3h5v5M4 20 21 3M21 16v5h-5M15 15l6 6M4 4l5 5" />,
	arrow: <path d="M3 12h18m-6-6 6 6-6 6" />,
	bell: <path d="M18 8a6 6 0 1 0-12 0c0 7-3 9-3 9h18s-3-2-3-9M10.3 21a2 2 0 0 0 3.4 0" />,
	flag: <path d="M5 21V4M5 4h11l-2 4 2 4H5" />,
};

function Icon({ name, filled = false }: { name: string; filled?: boolean }) {
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
			{ICONS[name]}
		</svg>
	);
}

/**
 * 许愿树墙（wish2 U7/KTD10）：公开树 = listed 四条件 + 加权随机排序。
 *
 * - 城市钉条：数据驱动（当前树上有愿望的城市），坐标取 flashbackCities
 *   真源（KTD11：任意名单内城市都能钉上，不受手写 45 城限制）；
 * - 换一批：随机 seed 立即重洗（KTD10）；分页 offset 同 seed 稳定；
 * - 期待 ❤️：乐观 ±1 → 服务端校正 → 失败按 wishId 函数式回滚（#806 F2）；
 * - 举报：弹层（预设理由 + 补充 ≤200）——治理信号，非「踩」；
 * - 附议引导：Web 不开放附议（KTD7），浮层给小程序深链说明（携 wishId）；
 * - 写愿望：入口按登录态分流（U8 挂 WishFormModal；未登录走登录引导）。
 */
export default function WishesWall({
	initialItem,
	initialCity,
	showIntro,
}: {
	initialItem?: FlashbackPublicWish;
	initialCity?: string;
	showIntro: boolean;
}) {
	const t = useTranslations("flashback.wishes");
	const [wishes, setWishes] = useState<FlashbackPublicWish[]>(initialItem ? [initialItem] : []);
	const [loadState, setLoadState] = useState<"loading" | "ready" | "failed">("loading");
	const [loadGeneration, setLoadGeneration] = useState(0);
	// L7：每页 24 条可翻页；不足一页 = 到底，隐藏「加载更多」
	const [hasMore, setHasMore] = useState(false);
	// L2：写愿望弹窗的年度剩余名额（登录才取；null = 未知，弹层保持既有兜底）
	const [myQuota, setMyQuota] = useState<number | null>(null);
	const [loadingMore, setLoadingMore] = useState(false);
	const [city, setCity] = useState<string>(initialItem?.city ?? initialCity ?? "");
	const [wishCities, setWishCities] = useState<CitySpec[]>([]);
	const [seed, setSeed] = useState<string | null>(null);
	const [pending, setPending] = useState<ReadonlySet<string>>(() => new Set());
	const [toast, setToast] = useState("");
	const [currentWishId, setCurrentWishId] = useState<string | null>(initialItem?.id ?? null);
	const [reportFor, setReportFor] = useState<FlashbackPublicWish | null>(null);
	const [reportReason, setReportReason] = useState<string>("spam");
	const [reportFree, setReportFree] = useState("");
	const [endorseGuideFor, setEndorseGuideFor] = useState<FlashbackPublicWish | null>(null);
	// wish2 U8：写愿望 modal（登录态挂 WishFormModal；未登录复用站内登录入口）
	const [writeOpen, setWriteOpen] = useState(false);
	// #836 回响卡展开态（按愿望 id 记）
	const [echoExpanded, setEchoExpanded] = useState<Record<string, boolean>>({});
	// 概念图右栏筛选 chips：「全部」/「已有回响」（附议数 > 0 = 有人出力过）
	const [filter, setFilter] = useState<"all" | "echo">("all");
	// 分享 = 复制链接（树 / 单条愿望 ?item=）+ toast
	const [shareToast, setShareToast] = useState("");
	const { authed } = useAuthed();

	const [runExpect] = useMutation(FLASHBACK_EXPECT_WISH);
	const [runReport] = useMutation(FLASHBACK_REPORT_WISH);

	// 去重键（R36 同手法）：SSR 首帧 null（不渲染动作按钮），客户端纠正
	const voter = useSyncExternalStore(
		() => () => {},
		() => ensureVoterKey(window.localStorage),
		() => null,
	);

	// wish2 U8：提交后重拉公开树（listed → 新纸签出现）；city 变化触发镜头定位
	const reloadWishes = useCallback(() => {
		setLoadState("loading");
		setLoadGeneration((n) => n + 1);
	}, []);

	// R21：城市入 URL（?city= 写回）——voices↔wishes 互跳与刷新保留当前城市
	const syncCityToUrl = useCallback((next: string) => {
		try {
			const url = new URL(window.location.href);
			if (next) url.searchParams.set("city", next);
			else url.searchParams.delete("city");
			window.history.replaceState(null, "", url.toString());
		} catch {
			// URL 不可用：不阻断选城
		}
	}, []);

	const markIntroSeen = useCallback(() => {
		try {
			// KTD8 跨页共享：两页标记都写（voices 读 voicesIntroSeen）
			window.localStorage.setItem(WISHES_INTRO_SEEN_KEY, "1");
			window.localStorage.setItem(VOICES_INTRO_SEEN_KEY, "1");
		} catch {
			// 存储不可用：不阻断
		}
	}, []);

	useEffect(() => {
		if (showIntro) markIntroSeen();
	}, [showIntro, markIntroSeen]);

	// PR #960 评审 3：城市钉真源 = flashbackWishCities（有愿望的城市全集，
	// 坐标服务端下发）——收成每页 24 条后城市栏不随已加载页变残
	useEffect(() => {
		client
			.query({ query: FLASHBACK_WISH_CITIES, fetchPolicy: "network-only" })
			.then(({ data }) => {
				setWishCities(
					(data?.flashbackWishCities ?? []).map((c) => ({ name: c.name, lng: c.lngLat[0], lat: c.lngLat[1] })),
				);
			})
			.catch(() => setWishCities([]));
	}, []);

	// 公开树加载（失败可重试）：city/seed/voterKey 变化或重试时重拉。
	// 不同步置 loading（react-hooks/set-state-in-effect）：初始态即 "loading"；
	// 变化重拉沿用旧数据平滑替换；显式重试在 handler 置 loading。
	// PR #960 评审 3：首屏与「加载更多」共用同一取数函数（首屏 = offset 0）
	const fetchWishPage = useCallback(
		async (offset: number) => {
			const { data } = await client.query({
				query: FLASHBACK_PUBLIC_WISHES,
				variables: {
					city: city || null,
					seed,
					offset,
					limit: PAGE_SIZE,
					// M8：「已有回响」由服务端筛选（withEchoes），不再前端按附议数近似
					withEchoes: filter === "echo" ? true : null,
					voterKey: voter,
				},
				fetchPolicy: "network-only",
			});
			return (data?.flashbackPublicWishes ?? []) as FlashbackPublicWish[];
		},
		[city, seed, filter, voter],
	);

	useEffect(() => {
		// 乱序守卫：city/seed 快速连点时，后发先至的新响应生效，晚到的旧响应丢弃
		let cancelled = false;
		fetchWishPage(0)
			.then((page) => {
				if (cancelled) return;
				setWishes(page);
				setHasMore(page.length >= PAGE_SIZE);
				setLoadState("ready");
			})
			.catch(() => {
				if (cancelled) return;
				setLoadState("failed");
			});
		return () => {
			cancelled = true;
		};
	}, [fetchWishPage, loadGeneration]);

	// toast 自动消失
	useEffect(() => {
		if (!toast) return;
		const timer = window.setTimeout(() => setToast(""), 3400);
		return () => window.clearTimeout(timer);
	}, [toast]);

	// L2：登录后取真实剩余名额（写完回填——弹窗打开即见，不必撞上限才知道）
	useEffect(() => {
		if (!authed) return;
		let cancelled = false;
		client
			.query({ query: FLASHBACK_MY_WISHES, fetchPolicy: "network-only" })
			.then(({ data }) => {
				if (!cancelled) setMyQuota(data?.flashbackMyWishes?.quotaRemaining ?? null);
			})
			.catch(() => {
				// 取不到保持 null：弹层走 quota_exceeded 拒绝兜底，不阻断写愿望
			});
		return () => {
			cancelled = true;
		};
	}, [authed, loadGeneration]);

	// 城市钉：服务端全集（PR #960 评审 3），不随已加载页变残
	const cities = wishCities;

	// M8：「已有回响」 chips 由服务端 withEchoes 筛选，前端不再按附议数近似；
	// 选中项失效回落首条
	const currentInFilter = wishes.find((w) => w.id === currentWishId) ?? wishes[0] ?? null;
	const others = useMemo(
		() => wishes.filter((w) => w.id !== currentInFilter?.id),
		[wishes, currentInFilter],
	);

	const copyShareLink = useCallback(
		(wishId?: string) => {
			const url = new URL("/flashback/wishes", window.location.origin);
			if (wishId) url.searchParams.set("item", wishId);
			if (city) url.searchParams.set("city", city);
			navigator.clipboard
				.writeText(url.toString())
				.then(() => setShareToast(t("shareCopied")))
				.catch(() => setShareToast(t("shareFailed")));
		},
		[city, t],
	);

	// 分享 toast 复用同一展示位（自动消失与上方 toast effect 分开）
	useEffect(() => {
		if (!shareToast) return;
		const timer = window.setTimeout(() => setShareToast(""), 3400);
		return () => window.clearTimeout(timer);
	}, [shareToast]);

	const shuffle = () => {
		// KTD10「换一批」：随机 seed 立即重洗
		setSeed(crypto.randomUUID());
		setCurrentWishId(null);
	};

	// L7「加载更多」：同 city/seed/filter 取下一页追加（offset = 已加载条数）
	const loadMore = async () => {
		if (loadingMore || !hasMore) return;
		setLoadingMore(true);
		try {
			const page = await fetchWishPage(wishes.length);
			setWishes((prev) => {
				const seen = new Set(prev.map((w) => w.id));
				return [...prev, ...page.filter((w) => !seen.has(w.id))];
			});
			setHasMore(page.length >= PAGE_SIZE);
		} catch {
			// 追加失败静默保留当前页——按钮还在，可再点（首屏失败另有 failed 态）
		} finally {
			setLoadingMore(false);
		}
	};

	// 期待 ❤️（KTD2/KTD9）：乐观 ±1 → 服务端校正 → 失败按 wishId 函数式回滚
	const toggleExpect = (wish: FlashbackPublicWish) => {
		if (!voter || pending.has(wish.id)) return;
		const expected = !wish.expectedByViewer;
		const prev = { expected: wish.expectedByViewer, count: wish.expectationCount };
		setWishes((ws) =>
			ws.map((item) =>
				item.id === wish.id
					? {
							...item,
							expectedByViewer: expected,
							expectationCount: Math.max(0, item.expectationCount + (expected ? 1 : -1)),
						}
					: item,
			),
		);
		setPending((p) => new Set([...p, wish.id]));

		runExpect({
			variables: {
				wishId: wish.id,
				expected,
				// 登录态由会话 cookie 承载（服务端强制 u: 键）；a: 设备键仅匿名用
				anonVoterKey: voter.startsWith("a:") ? voter : null,
			},
		})
			.then(({ data }) => {
				const count = data?.flashbackExpectWish?.expectationCount;
				const mine = data?.flashbackExpectWish?.expectedByMe;
				if (typeof count !== "number" || typeof mine !== "boolean") return;
				setWishes((ws) =>
					ws.map((item) =>
						item.id === wish.id
							? { ...item, expectationCount: count, expectedByViewer: mine }
							: item,
					),
				);
			})
			.catch(() =>
				// #806 F2：失败回滚只恢复该条
				setWishes((ws) =>
					ws.map((item) =>
						item.id === wish.id
							? { ...item, expectedByViewer: prev.expected, expectationCount: prev.count }
							: item,
					),
				),
			)
			.finally(() =>
				setPending((p) => {
					const next = new Set(p);
					next.delete(wish.id);
					return next;
				}),
			);
	};

	const submitReport = () => {
		if (!reportFor) return;
		runReport({
			variables: {
				wishId: reportFor.id,
				reasonType: reportReason,
				reasonFree: reportFree.trim() || null,
				anonVoterKey: voter?.startsWith("a:") ? voter : null,
			},
		})
			.then(() => {
				setToast(t("reportDone"));
				setReportFor(null);
				setReportFree("");
			})
			.catch(() => setToast(t("reportFailed")));
	};

	if (loadState === "failed") {
		return (
			<div className={`${styles.app} ${styles.statePage}`}>
				<p className={styles.stateLead}>{t("loadFailed")}</p>
				<button type="button" className={styles.ghostBtn} onClick={reloadWishes}>
					{t("retry")}
				</button>
			</div>
		);
	}

	return (
		<div className={styles.app}>
			<FlashbackNav active="wishes" city={city}>
					{authed ? (
						<button type="button" className={styles.primaryBtn} onClick={() => setWriteOpen(true)}>
							<Icon name="pen" />
							<span>{t("writeWish")}</span>
						</button>
					) : (
						<Link
							className={styles.primaryBtn}
							/* L1：回跳保留当前城市与单条直达，登录后不丢上下文 */
							href={`/login?next=${encodeURIComponent(`/flashback/wishes${city ? `?city=${encodeURIComponent(city)}` : ""}${currentWishId ? `${city ? "&" : "?"}item=${encodeURIComponent(currentWishId)}` : ""}`)}`}
						>
							<Icon name="pen" />
							<span>{t("writeWish")}</span>
						</Link>
					)}
					<button type="button" className={styles.secondaryBtn} onClick={() => copyShareLink()}>
						<Icon name="share" />
						<span>{t("shareTree")}</span>
					</button>
				</FlashbackNav>

			<main className={styles.workspace}>
				<section className={styles.mapSection} aria-label={t("kicker")}>
					<div className={styles.hero}>
						<h1>{t("title")}</h1>
						<p>{t("lead")}</p>
					</div>
					{cities.length > 0 && (
						<MapScene
							cities={cities}
							city={city}
							progress={1}
							onCity={(next) => {
								const picked = next === city ? "" : next;
								setCity(picked);
								syncCityToUrl(picked);
							}}
							pulse={0}
						/>
					)}
				</section>

				<aside className={styles.panel} aria-label={t("wallTitle")}>
					<div className={styles.chips} role="group" aria-label={t("wallTitle")}>
						<button type="button" aria-pressed={filter === "all"} onClick={() => setFilter("all")}>
							{t("filterAll")}
						</button>
						<button type="button" aria-pressed={filter === "echo"} onClick={() => setFilter("echo")}>
							{t("filterEcho")}
						</button>
					</div>

					{loadState === "loading" ? (
						<p role="status" className={styles.panelNote}>
							{t("loading")}
						</p>
					) : wishes.length === 0 ? (
						<p className={styles.panelNote}>
							{filter === "echo" ? t("echoEmpty") : city ? t("cityEmpty", { city }) : t("empty")}
						</p>
					) : (
						currentInFilter && (
							<>
								<article className={styles.selected} data-wish-id={currentInFilter.id}>
									<p className={styles.selectedContent}>{currentInFilter.content}</p>
									<p className={styles.selectedSignature}>
										{currentInFilter.signature}
										{currentInFilter.city ? ` · ${currentInFilter.city}` : ""}
										{currentInFilter.echoCount > 0 && (
											<span
												className={styles.echoMark}
												data-testid="fb-selected-echo-badge"
												aria-label={t("hasEchoLabel")}
											>
												{t("hasEchoBadge")}
											</span>
										)}
									</p>
									<p className={styles.expectCount}>
										{currentInFilter.expectationCount} {t("expectCount")}
									</p>
									{currentInFilter.latestEcho && currentInFilter.echoCount > 0 && (
										<WishEchoCard
											latest={currentInFilter.latestEcho}
											echoes={currentInFilter.echoes}
											expanded={!!echoExpanded[currentInFilter.id]}
											onToggleExpanded={() =>
												setEchoExpanded((prev) => ({
													...prev,
													[currentInFilter.id]: !prev[currentInFilter.id],
												}))
											}
										/>
									)}
									<div className={styles.selectedActions}>
										<button
											type="button"
											className={styles.primaryBtn}
											disabled={!voter || pending.has(currentInFilter.id)}
											aria-pressed={currentInFilter.expectedByViewer}
											onClick={() => toggleExpect(currentInFilter)}
										>
											<Icon name="heart" filled={currentInFilter.expectedByViewer} />
											{currentInFilter.expectedByViewer ? t("expectDone") : t("expectCta")}
										</button>
										{/* KTD7：Web 不开放附议表单，「附议 · 我能出力」引导去小程序深链；权重高于分享（KTD10 2×期待） */}
										<button type="button" className={styles.secondaryBtn} onClick={() => setEndorseGuideFor(currentInFilter)}>
											<span aria-label={t("endorseCountLabel")}>🙌 {currentInFilter.endorsementCount}</span>
											{t("endorseCta")}
										</button>
									</div>
									<footer className={styles.selectedFoot}>
										<div className={styles.selectedMeta}>
											<button type="button" onClick={() => copyShareLink(currentInFilter.id)}>
												<Icon name="share" />
												{t("shareWish")}
											</button>
											<button type="button" onClick={() => setReportFor(currentInFilter)}>
												<Icon name="flag" />
												{t("reportEntry")}
											</button>
										</div>
									</footer>
								</article>

								{others.length > 0 && (
									<>
										<h2 className={styles.othersTitle}>{t("moreWishes")}</h2>
										<ul className={styles.wishList}>
											{others.map((wish) => (
												<li key={wish.id} className={styles.wishRow} data-wish-id={wish.id}>
													<button type="button" className={styles.wishRowOpen} onClick={() => setCurrentWishId(wish.id)}>
														{wish.content}
													</button>
													<span className={styles.wishRowSignature}>
														{wish.signature}
														{wish.city ? ` · ${wish.city}` : ""}
													</span>
													<span className={styles.wishRowMeta}>
														<span>❤️ {wish.expectationCount}</span>
														<span aria-label={t("endorseCountLabel")}>🙌 {wish.endorsementCount}</span>
														{wish.echoCount > 0 && (
															<span
																className={styles.echoMark}
																data-testid="fb-wish-row-echo"
																aria-label={t("hasEchoLabel")}
															>
																{t("hasEchoBadge")}
															</span>
														)}
													</span>
													<button
														type="button"
														disabled={!voter || pending.has(wish.id)}
														aria-pressed={wish.expectedByViewer}
														aria-label={wish.expectedByViewer ? t("expectDone") : t("expectCta")}
														onClick={() => toggleExpect(wish)}
													>
														{wish.expectedByViewer ? "❤️" : "❤️+"}
													</button>
												</li>
											))}
										</ul>
									</>
								)}
							</>
						)
					)}

					<div className={styles.panelOps}>
						<button type="button" className={styles.ghostBtn} onClick={shuffle}>
							<Icon name="shuffle" />
							{t("shuffle")}
						</button>
						{loadState === "ready" && hasMore && (
							<button type="button" className={styles.ghostBtn} disabled={loadingMore} onClick={() => void loadMore()}>
								{loadingMore ? t("loading") : t("loadMore")}
							</button>
						)}
						{city && (
							<button
								type="button"
								className={styles.ghostBtn}
								onClick={() => {
									setCity("");
									syncCityToUrl("");
								}}
							>
								{t("allCities")}
							</button>
						)}
						{/* R21/wish2 U7：双页互跳带城市 */}
						<Link className={styles.ghostBtn} href={city ? `/flashback/voices?city=${encodeURIComponent(city)}` : "/flashback/voices"}>
							{t("voicesEntry")} <Icon name="arrow" />
						</Link>
					</div>

					<footer className={styles.quote}>
						<p>“ {t("wishQuote")} ”</p>
						<small>—— {t("brandPrefix")}</small>
					</footer>
				</aside>
			</main>

			{(toast || shareToast) && (
				<p role="status" className={styles.toast}>
					{toast || shareToast}
				</p>
			)}

			{endorseGuideFor && (
				<div role="dialog" aria-modal="true" aria-label={t("endorseGuideTitle")} className={styles.dialog}>
					<p>{t("endorseGuideLead")}</p>
					<p>{t("endorseGuideSteps")}</p>
					<button type="button" className={styles.ghostBtn} onClick={() => setEndorseGuideFor(null)}>
						{t("close")}
					</button>
				</div>
			)}

			{reportFor && (
				<div role="dialog" aria-modal="true" aria-label={t("reportTitle")} className={styles.dialog}>
					<p>{t("reportLead")}</p>
					<fieldset>
						<legend>{t("reportReason")}</legend>
						{REPORT_REASONS.map((reason) => (
							<label key={reason}>
								<input
									type="radio"
									name="report-reason"
									value={reason}
									checked={reportReason === reason}
									onChange={() => setReportReason(reason)}
								/>
								{t(`reason_${reason}`)}
							</label>
						))}
					</fieldset>
					<textarea
						maxLength={200}
						value={reportFree}
						placeholder={t("reportFreePlaceholder")}
						onChange={(e) => setReportFree(e.target.value)}
					/>
					<button type="button" className={styles.primaryBtn} onClick={submitReport}>
						{t("reportSubmit")}
					</button>
					<button
						type="button"
						className={styles.ghostBtn}
						onClick={() => {
							// 取消即清草稿（与提交成功路径对称——残留上次的补充说明是隐私噪声）
							setReportFor(null);
							setReportFree("");
						}}
					>
						{t("close")}
					</button>
				</div>
			)}

			{writeOpen && (
				<WishFormModal
					token={null}
					busy={false}
					myWishQuotaRemaining={authed ? myQuota : null}
					onClose={() => setWriteOpen(false)}
					onDone={(outcome) => {
						// R18 三态落墙：listed → 镜头定位所选城市 + 重拉出新纸签；
						// pending/private 不动墙（纸签未公开出现——不假装）
						if (outcome?.status === "listed") {
							if (outcome.city) setCity(outcome.city);
							reloadWishes();
						}
					}}
				/>
			)}
		</div>
	);
}
