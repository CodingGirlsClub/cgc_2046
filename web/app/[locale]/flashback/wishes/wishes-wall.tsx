"use client";

import { useCallback, useEffect, useMemo, useState, useSyncExternalStore } from "react";
import { useTranslations } from "next-intl";
import { useMutation } from "@apollo/client/react";
import { client } from "@/lib/apollo-client";
import { ensureVoterKey } from "@/lib/flashback-voter";
import {
	FLASHBACK_CITIES,
	FLASHBACK_EXPECT_WISH,
	FLASHBACK_PUBLIC_WISHES,
	FLASHBACK_REPORT_WISH,
	type FlashbackCity,
	type FlashbackPublicWish,
} from "@/lib/graphql/flashback";
import MapScene, { type CitySpec } from "../voices/map-scene";

const WISHES_INTRO_SEEN_KEY = "flashback.wishesIntroSeen";
const VOICES_INTRO_SEEN_KEY = "flashback.voicesIntroSeen";
const REPORT_REASONS = ["spam", "irrelevant", "scam", "inappropriate", "other"] as const;

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

	const [runExpect] = useMutation(FLASHBACK_EXPECT_WISH);
	const [runReport] = useMutation(FLASHBACK_REPORT_WISH);

	// 去重键（R36 同手法）：SSR 首帧 null（不渲染动作按钮），客户端纠正
	const voter = useSyncExternalStore(
		() => () => {},
		() => ensureVoterKey(window.localStorage),
		() => null,
	);

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

	// 公开树加载（失败可重试）：city/seed/voterKey 变化或重试时重拉
	useEffect(() => {
		setLoadState("loading");
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
			<div className="fb-root fb-public">
				<p className="fb-lead">{t("loadFailed")}</p>
				<button type="button" className="fb-action" onClick={() => setLoadGeneration((n) => n + 1)}>
					{t("retry")}
				</button>
			</div>
		);
	}

	return (
		<div className="fb-root fb-public">
			<header className="fb-public-hero">
				<div className="fb-kicker">IN A FLASH · {t("kicker")}</div>
				<h1 className="fb-stage-title">{t("title")}</h1>
				<p className="fb-lead">{t("lead")}</p>
			</header>

			{cities.length > 0 && (
				<MapScene
					cities={cities}
					city={city}
					progress={1}
					onCity={(next) => setCity(next === city ? "" : next)}
					pulse={0}
				/>
			)}

			<section aria-labelledby="fb-wishes-title">
				<h2 id="fb-wishes-title" className="fb-action-title">
					{t("wallTitle")}
				</h2>
				<div className="fb-actions-row">
					<button type="button" className="fb-action" onClick={shuffle}>
						{t("shuffle")}
					</button>
					{city && (
						<button type="button" className="fb-action" onClick={() => setCity("")}>
							{t("allCities")}
						</button>
					)}
					<a className="fb-action" href="/flashback/enter">
						{t("writeWish")}
					</a>
				</div>

				{loadState === "loading" ? (
					<p role="status">{t("loading")}</p>
				) : wishes.length === 0 ? (
					<p className="fb-hint">{t("empty")}</p>
				) : (
					<ul className="fb-wish-list">
						{wishes.map((wish) => (
							<li
								key={wish.id}
								className="fb-wish-card"
								data-wish-id={wish.id}
								data-current={wish.id === current?.id || undefined}
							>
								<p className="fb-wish-content">{wish.content}</p>
								<p className="fb-wish-signature">
									{wish.signature}
									{wish.city ? ` · ${wish.city}` : ""}
								</p>
								<div className="fb-wish-meta">
									<button
										type="button"
										disabled={!voter || pending.has(wish.id)}
										aria-pressed={wish.expectedByViewer}
										onClick={() => toggleExpect(wish)}
									>
										❤️ {wish.expectationCount}
									</button>
									<span aria-label={t("endorseCountLabel")}>🙌 {wish.endorsementCount}</span>
									<button type="button" onClick={() => setEndorseGuideFor(wish)}>
										{t("endorseEntry")}
									</button>
									<button type="button" onClick={() => setReportFor(wish)}>
										{t("reportEntry")}
									</button>
								</div>
							</li>
						))}
					</ul>
				)}
			</section>

			{toast && (
				<p role="status" className="fb-toast">
					{toast}
				</p>
			)}

			{endorseGuideFor && (
				<div role="dialog" aria-modal="true" aria-label={t("endorseGuideTitle")}>
					<p>{t("endorseGuideLead")}</p>
					<p>{t("endorseGuideSteps")}</p>
					<button type="button" onClick={() => setEndorseGuideFor(null)}>
						{t("close")}
					</button>
				</div>
			)}

			{reportFor && (
				<div role="dialog" aria-modal="true" aria-label={t("reportTitle")}>
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
						disabled={reportFree.trim().length > 200}
						onClick={submitReport}
					>
						{t("reportSubmit")}
					</button>
					<button type="button" onClick={() => setReportFor(null)}>
						{t("close")}
					</button>
				</div>
			)}
		</div>
	);
}
