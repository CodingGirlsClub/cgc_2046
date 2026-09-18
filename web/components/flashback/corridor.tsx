"use client";

import { useSyncExternalStore } from "react";
import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import type { FlashbackCapsule, FlashbackCapsuleArchive } from "@/lib/graphql/flashback";
import { tiltClass } from "./tilt";
import TodaySlot from "./today-slot";
import { usePrefersReducedMotion } from "./use-reduced-motion";
import { developClass, useDevelopEnabled, useDevelopOnView } from "./use-develop-on-view";

const WIDE_QUERY = "(min-width: 768px)";

/** 每帧最多几堆（原型 D：piles.slice(0,4)）——城市再多也只挂计数最高的前 4 城 */
const MAX_PILES = 4;

export type CityPile = { city: string; count: number };

/**
 * 城市照片堆（用户定稿 D）：从名册聚合 {city, count}——city 空值/空白不计，
 * 确定性排序：count 降序 → 城市字典序（码位序，不依赖运行时 ICU 排序规则）。
 */
export function cityPiles(archive: FlashbackCapsuleArchive): CityPile[] {
	const counts = new Map<string, number>();
	for (const entry of archive.roster) {
		const city = entry.city?.trim();
		if (!city) continue;
		counts.set(city, (counts.get(city) ?? 0) + 1);
	}
	return [...counts]
		.map(([city, count]) => ({ city, count }))
		// count 降序 → 城市字典序（码位序：不依赖运行时 ICU 排序规则，测试可精确断言）
		.sort((a, b) => b.count - a.count || (a.city < b.city ? -1 : a.city > b.city ? 1 : 0))
		.slice(0, MAX_PILES);
}

/**
 * 时间走廊（U5/R12）：宽屏横向滚动、窄屏纵向（原型 variant-d/mobile-journey
 * 双形态；布局类名切换由 useWideCorridor 驱动，动效/布局在 flashback.css）。
 * 时间从上（最早场次）往下（今天 + 未来），下滑 = 时间前进。
 *
 * 定稿 D：一帧只留城市照片堆（小拍立得 + 城市名 + 下方计数）与
 * 「进入这一场 →」入口；逐个名册照片归场次页 3 列网格。
 */
export default function Corridor({
	capsule,
	cityFiltered = false,
}: {
	capsule: FlashbackCapsule;
	/** 城市钉筛选中（R34）：名册为空时给「该城无名册」而非裸空走廊 */
	cityFiltered?: boolean;
}) {
	const t = useTranslations("flashback.corridor");
	const wide = useWideCorridor();

	return (
		<section className={`fb-corridor${wide ? " fb-corridor--wide" : ""}`} aria-label={t("ariaLabel")}>
			{capsule.archives.length === 0 && cityFiltered && (
				<p className="fb-hint fb-corridor-empty">{t("emptyCity")}</p>
			)}
			{capsule.archives.map((archive) => (
				<article key={archive.key} className="fb-corridor-frame">
					<h3 className="fb-corridor-when">
						{archive.occurredOn?.replace(/-/g, ".") ?? archive.key}
						<span className="fb-corridor-flabel">{archive.name}</span>
						{/* 点格进场次页（E 的 event 步）：统计 + 3 列名册 + 找回出口 */}
						<Link href={`/flashback/event/${archive.key}`} className="fb-corridor-open">
							{t("openEvent")}
						</Link>
					</h3>
					<CityPiles archive={archive} />
				</article>
			))}
			<TodaySlot me={capsule.me} />
		</section>
	);
}

/**
 * 一帧的城市堆（用户定稿 D / 原型 mobile-journey corridor 步）：每城一张小拍立得
 * （纸白 + grain + 城市名，84px 宽）+ 下方「城市 · n 位」小字；转角由城市名确定性
 * 派生（tilt 类，禁止随机）；显影照名册（进视口才播，只播一次）。
 */
function CityPiles({ archive }: { archive: FlashbackCapsuleArchive }) {
	const t = useTranslations("flashback.corridor");
	const reduced = usePrefersReducedMotion();
	const developActive = useDevelopEnabled(reduced);
	const { developed, registerDevelop } = useDevelopOnView(developActive);
	const piles = cityPiles(archive);

	if (piles.length === 0) return null;

	return (
		<ul
			className="fb-corridor-piles"
			aria-label={t("pilesAria", { name: archive.name ?? archive.key })}
		>
			{piles.map((pile) => (
				<li
					key={pile.city}
					className="fb-corridor-pile"
					data-testid="fb-corridor-pile"
					data-city={pile.city}
					data-count={pile.count}
				>
					<div
						ref={registerDevelop}
						data-develop-id={pile.city}
						className={`fb-polaroid fb-grain fb-corridor-polaroid ${tiltClass(pile.city)}${developClass(
							"fb-corridor-polaroid",
							developActive,
							developed.has(pile.city),
						)}`}
					>
						<span className="fb-photo fb-corridor-photo">{pile.city}</span>
					</div>
					<p className="fb-corridor-count">{t("pileCount", { city: pile.city, count: pile.count })}</p>
				</li>
			))}
		</ul>
	);
}

/** 宽屏判定（两形态单源；SSR 快照按窄屏，客户端首帧纠正） */
function useWideCorridor(): boolean {
	return useSyncExternalStore(
		(callback) => {
			const query = window.matchMedia(WIDE_QUERY);
			query.addEventListener("change", callback);
			return () => query.removeEventListener("change", callback);
		},
		() => window.matchMedia(WIDE_QUERY).matches,
		() => false,
	);
}
