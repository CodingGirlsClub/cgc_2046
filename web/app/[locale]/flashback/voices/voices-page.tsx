"use client";

import { useEffect, useState, useSyncExternalStore, type CSSProperties } from "react";
import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import { client } from "@/lib/apollo-client";
import { ensureVoterKey } from "@/lib/flashback-voter";
import { FLASHBACK_PUBLIC_QUOTE, type FlashbackPublicQuote } from "@/lib/graphql/flashback";
import { usePrefersReducedMotion } from "@/components/flashback/use-reduced-motion";
import VoicesWall from "./voices-wall";
import styles from "./voices.module.css";

const INTRO_SEEN_KEY = "flashback.voicesIntroSeen";

type Direct = FlashbackPublicQuote | "gone" | null;

/**
 * 入口编排（R7/R8/KTD4）：
 *
 * - `?item=<quote_id>`：客户端校验该句当前有效（`flashbackPublicQuote`，
 *   与墙同过滤口径）——有效 → 直达句 + 抑制开场；失效 → 失效视图（U4，
 *   HTTP 200 软 404，不泄露「存在但未授权」与「不存在」的区别）；
 * - 无 item：回访（localStorage 已看开场）或 reduced-motion → 直接白昼；
 *   否则播四幕开场。
 */
export default function VoicesPage({ item }: { item?: string }) {
	const t = useTranslations("flashback.voices");
	const reducedMotion = usePrefersReducedMotion();
	// undefined = 校验中；null = 无直达；quote = 有效直达句；"gone" = 已撤回/不存在
	// item 变化（失效页「看全墙」软导航回同路由）时同步重置——useState 初值只在
	// mount 生效，软导航复用组件实例会把 "gone" 带回无 item 的新 URL（e2e 实证）。
	const [prevItem, setPrevItem] = useState(item);
	const [direct, setDirect] = useState<Direct | undefined>(item ? undefined : null);
	if (prevItem !== item) {
		setPrevItem(item);
		setDirect(item ? undefined : null);
	}

	// 回访记忆（R8）：localStorage 快照——SSR 首帧 null（等同 false 的
	// 「播开场」语义可由客户端随即纠正；storage 不可用按首次处理）。
	const introSeen = useSyncExternalStore(
		() => () => {},
		() => {
			try {
				return window.localStorage.getItem(INTRO_SEEN_KEY) === "1";
			} catch {
				return false;
			}
		},
		() => null,
	);

	useEffect(() => {
		if (!item) return;
		let cancelled = false;
		client
			.query({
				query: FLASHBACK_PUBLIC_QUOTE,
				variables: { quoteId: item, voterKey: ensureVoterKey(window.localStorage) },
				fetchPolicy: "network-only",
			})
			.then(({ data }) => {
				if (!cancelled) setDirect(data?.flashbackPublicQuote ?? "gone");
			})
			.catch(() => {
				// 查询失败不留中间态：回落整墙（item 语义让位于可读）
				if (!cancelled) setDirect(null);
			});
		return () => {
			cancelled = true;
		};
	}, [item]);

	const daylight = { "--daylight": 1 } as CSSProperties;

	// 直达校验中：加载壳（不播开场——开场会被校验完成后的状态闪断）
	if (item && direct === undefined) {
		return (
			<div className={styles.prototype}>
				<div className={styles.viewport}>
					<div className={styles.app} style={daylight}>
						<main className={styles.statePage}>
							<p data-testid="voices-loading">{t("loading")}</p>
						</main>
					</div>
				</div>
			</div>
		);
	}

	// U4 失效视图：这句话已被作者收回 + 看全墙入口（HTTP 200，软 404 语义）
	if (direct === "gone") {
		return (
			<div className={styles.prototype}>
				<div className={styles.viewport}>
					<div className={styles.app} style={daylight}>
						<main className={styles.statePage} data-testid="voices-gone">
							<p className={styles.eyebrow}>{t("mapEyebrow")}</p>
							<h1>{t("goneTitle")}</h1>
							<p>{t("goneBody")}</p>
							<Link href="/flashback/voices" className={styles.primaryLink}>
								{t("goneCta")}
							</Link>
						</main>
					</div>
				</div>
			</div>
		);
	}

	if (introSeen === null) return null;

	// 开场：仅「无直达 + 未看过 + 非 reduced-motion」播（R5/R7/R8/R24）
	const showIntro = !direct && !introSeen && !reducedMotion;
	return <VoicesWall initialItem={direct ?? undefined} showIntro={showIntro} />;
}
