"use client";

import { useCallback, useEffect, useMemo, useState, useSyncExternalStore, type ReactNode } from "react";
import { useTranslations } from "next-intl";
import { useMutation } from "@apollo/client/react";
import { Link } from "@/i18n/navigation";
import { client } from "@/lib/apollo-client";
import { useAuthed } from "@/lib/auth-provider";
import { ensureVoterKey } from "@/lib/flashback-voter";
import { WishFormModal } from "@/components/flashback/wish-frames";
import {
	FLASHBACK_CITIES,
	FLASHBACK_EXPECT_WISH,
	FLASHBACK_PUBLIC_WISHES,
	FLASHBACK_REPORT_WISH,
	type FlashbackCity,
	type FlashbackPublicWish,
} from "@/lib/graphql/flashback";
import MapScene, { type CitySpec } from "../voices/map-scene";
import styles from "./wishes.module.css";

const WISHES_INTRO_SEEN_KEY = "flashback.wishesIntroSeen";
const VOICES_INTRO_SEEN_KEY = "flashback.voicesIntroSeen";
const REPORT_REASONS = ["spam", "irrelevant", "scam", "inappropriate", "other"] as const;

/** 与 voices 同一几何语言（24 viewBox / stroke 1.5 / 圆角端点）的局部图标表 */
const ICONS: Record<string, ReactNode> = {
	share: <path d="M12 3v12M8 7l4-4 4 4M5 13v6a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-6" />,
	heart: <path d="M19.5 12.6 12 20l-7.5-7.4a5 5 0 1 1 7.5-6.6 5 5 0 1 1 7.5 6.6Z" />,
	pen: <path d="M12 20h9M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z" />,
	shuffle: <path d="M16 3h5v5M4 20 21 3M21 16v5h-5M15 15l6 6M4 4l5 5" />,
	arrow: <path d="M3 12h18m-6-6 6 6-6 6" />,
	bell: <path d="M18 8a6 6 0 1 0-12 0c0 7-3 9-3 9h18s-3-2-3-9M10.3 21a2 2 0 0 0 3.4 0" />,
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
	const [city, setCity] = useState<string>(initialItem?.city ?? initialCity ?? "");
	const [cityCoords, setCityCoords] = useState<Record<string, { lng: number; lat: number }>>({});
	const [seed, setSeed] = useState<string | null>(null);
	const [pending, setPending] = useState<ReadonlySet<string>>(() => new Set());
	const [toast, setToast] = useState("");
	const [currentWishId, setCurrentWishId] = useState<string | null>(initialItem?.id ?? null);
	const [reportFor, setReportFor] = useState<FlashbackPublicWish | null>(null);
	const [reportReason, setReportReason] = useState<string>("spam");
	const [reportFree, setReportFree] = useState("");
	const [endorseGuideFor, setEndorseGuideFor] = useState<FlashbackPublicWish | null>(null);
	// wish2 U8：写愿望 modal（登录态挂 WishFormModal；未登录走 enter 引导）
	const [writeOpen, setWriteOpen] = useState(false);
	// 概念图右栏筛选 chips：「全部」/「我也在期待」（expectedByViewer 客户端过滤）
	const [filter, setFilter] = useState<"all" | "mine">("all");
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

	// 城市名单真源（KTD11 钉点坐标）：一次拉取缓存
	useEffect(() => {
		client
			.query({ query: FLASHBACK_CITIES, fetchPolicy: "cache-first" })
			.then(({ data }) => {
				const table: Record<string, { lng: number; lat: number }> = {};
				for (const c of (data?.flashbackCities ?? []) as FlashbackCity[]) {
					table[c.name] = { lng: c.lngLat[0], lat: c.lngLat[1] };
				}
				setCityCoords(table);
			})
			.catch(() => setCityCoords({}));
	}, []);

	// 公开树加载（失败可重试）：city/seed/voterKey 变化或重试时重拉。
	// 不同步置 loading（react-hooks/set-state-in-effect）：初始态即 "loading"；
	// 变化重拉沿用旧数据平滑替换；显式重试在 handler 置 loading。
	useEffect(() => {
		client
			.query({
				query: FLASHBACK_PUBLIC_WISHES,
				variables: {
					city: city || null,
					seed,
					limit: 60,
					voterKey: voter,
				},
				fetchPolicy: "network-only",
			})
			.then(({ data }) => {
				setWishes((data?.flashbackPublicWishes ?? []) as FlashbackPublicWish[]);
				setLoadState("ready");
			})
			.catch(() => setLoadState("failed"));
	}, [city, seed, voter, loadGeneration]);

	// toast 自动消失
	useEffect(() => {
		if (!toast) return;
		const timer = window.setTimeout(() => setToast(""), 3400);
		return () => window.clearTimeout(timer);
	}, [toast]);

	// 城市钉条：当前树上有愿望的城市（数据驱动），坐标真源查表；无坐标排尾
	const cities: CitySpec[] = useMemo(() => {
		const seen = new Map<string, CitySpec>();
		for (const w of wishes) {
			if (!w.city || seen.has(w.city)) continue;
			const coords = cityCoords[w.city];
			if (coords) seen.set(w.city, { name: w.city, lng: coords.lng, lat: coords.lat });
		}
		return [...seen.values()];
	}, [wishes, cityCoords]);

	const current = wishes.find((w) => w.id === currentWishId) ?? wishes[0] ?? null;

	// 概念图 chips 过滤；选中项从过滤集取，失效回落首条
	const filtered = useMemo(
		() => (filter === "mine" ? wishes.filter((w) => w.expectedByViewer) : wishes),
		[filter, wishes],
	);
	const currentInFilter = filtered.find((w) => w.id === currentWishId) ?? filtered[0] ?? null;
	const others = useMemo(
		() => filtered.filter((w) => w.id !== currentInFilter?.id),
		[filtered, currentInFilter],
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
			<header className={styles.header}>
				<Link className={styles.brand} href="/flashback" aria-label={t("metaTitle")}>
					<strong>
						{t("brandPrefix")}
						<span className={styles.brandSeal}>{t("brandSealChar")}</span>
					</strong>
					<small>{t("brandSub")}</small>
				</Link>
				<nav className={styles.nav} aria-label={t("navLabel")}>
					{/* R21/wish2 U7：双页互跳带城市——切换保留当前城市 */}
					<Link href={city ? `/flashback/voices?city=${encodeURIComponent(city)}` : "/flashback/voices"}>
						{t("voicesNav")} <span>{t("voicesNavEn")}</span>
					</Link>
					<Link href="/flashback/wishes" className={styles.activeNav} aria-current="page">
						{t("wishesNav")} <span>{t("wishesNavEn")}</span>
					</Link>
				</nav>
				<div className={styles.headerActions}>
					{authed ? (
						<button type="button" className={styles.primaryBtn} onClick={() => setWriteOpen(true)}>
							<Icon name="pen" />
							<span>{t("writeWish")}</span>
						</button>
					) : (
						<Link className={styles.primaryBtn} href="/flashback/enter">
							<Icon name="pen" />
							<span>{t("writeWish")}</span>
						</Link>
					)}
					<button type="button" className={styles.secondaryBtn} onClick={() => copyShareLink()}>
						<Icon name="share" />
						<span>{t("shareTree")}</span>
					</button>
				</div>
			</header>

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
						<button type="button" aria-pressed={filter === "mine"} onClick={() => setFilter("mine")}>
							{t("filterMine")}
						</button>
					</div>

					{loadState === "loading" ? (
						<p role="status" className={styles.panelNote}>
							{t("loading")}
						</p>
					) : filtered.length === 0 ? (
						<p className={styles.panelNote}>{filter === "mine" ? t("mineEmpty") : t("empty")}</p>
					) : (
						currentInFilter && (
							<>
								<article className={styles.selected} data-wish-id={currentInFilter.id}>
									<p className={styles.selectedContent}>{currentInFilter.content}</p>
									<p className={styles.selectedSignature}>
										{currentInFilter.signature}
										{currentInFilter.city ? ` · ${currentInFilter.city}` : ""}
									</p>
									<p className={styles.expectCount}>
										{currentInFilter.expectationCount} {t("expectCount")}
									</p>
									<div className={styles.selectedActions}>
										<button
											type="button"
											className={styles.primaryBtn}
											disabled={!voter || pending.has(currentInFilter.id)}
											aria-pressed={currentInFilter.expectedByViewer}
											onClick={() => toggleExpect(currentInFilter)}
										>
											<Icon name="heart" filled={currentInFilter.expectedByViewer} />
											{t("expectCta")}
										</button>
										<button type="button" className={styles.secondaryBtn} onClick={() => copyShareLink(currentInFilter.id)}>
											<Icon name="share" />
											{t("shareWish")}
										</button>
									</div>
									<p className={styles.remindHint}>
										<Icon name="bell" />
										{t("remindHint")}
									</p>
									<div className={styles.selectedMeta}>
										<button type="button" onClick={() => setEndorseGuideFor(currentInFilter)}>
											{t("endorseEntry")}
										</button>
										<span aria-label={t("endorseCountLabel")}>🙌 {currentInFilter.endorsementCount}</span>
										<button type="button" onClick={() => setReportFor(currentInFilter)}>
											{t("reportEntry")}
										</button>
									</div>
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
													</span>
													<button
														type="button"
														disabled={!voter || pending.has(wish.id)}
														aria-pressed={wish.expectedByViewer}
														onClick={() => toggleExpect(wish)}
													>
														❤️+
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
					<button
						type="button"
						className={styles.primaryBtn}
						disabled={reportFree.trim().length > 200}
						onClick={submitReport}
					>
						{t("reportSubmit")}
					</button>
					<button type="button" className={styles.ghostBtn} onClick={() => setReportFor(null)}>
						{t("close")}
					</button>
				</div>
			)}

			{writeOpen && (
				<WishFormModal
					token={null}
					busy={false}
					myWishQuotaRemaining={null}
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
