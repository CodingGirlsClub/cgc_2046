"use client";

import { useSyncExternalStore, type CSSProperties } from "react";
import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import type { FlashbackCapsule, FlashbackCapsuleArchive } from "@/lib/graphql/flashback";
import TodaySlot from "./today-slot";

const WIDE_QUERY = "(min-width: 768px)";

/** 每帧最多几堆——城市再多也只挂计数最高的前 8 城（2016 帧八城排版定稿实验） */
const MAX_PILES = 8;

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
	city = null,
}: {
	capsule: FlashbackCapsule;
	/** 城市钉筛选中（R34）：名册为空时给「该城无名册」而非裸空走廊 */
	cityFiltered?: boolean;
}) {
	const tCorridor = useTranslations("flashback.corridor");
	const wide = useWideCorridor();

	return (
		<section className={`fb-corridor${wide ? " fb-corridor--wide" : ""}`} aria-label={tCorridor("ariaLabel")}>
			{capsule.archives.length === 0 && cityFiltered && (
				<p className="fb-hint fb-corridor-empty">{tCorridor("emptyCity")}</p>
			)}
			{capsule.archives.map((archive) => (
				<article key={archive.key} className="fb-corridor-frame">
					<h3 className="fb-corridor-when" data-testid="fb-corridor-when">
						{archive.occurredOn?.replace(/-/g, ".") ?? archive.key}
						{/* 叙事短标签（原型 D ia-frame-label）：「六城同日」写故事不写地名；
						    导入未带的场次回落场次名 */}
						<span className="fb-corridor-flabel">{archive.label ?? archive.name}</span>
					</h3>
					<CityPiles archive={archive} />
				</article>
			))}
			<TodaySlot me={capsule.me} />
		</section>
	);
}

/**
 * 一帧的城市堆（用户定稿 D / 原型 variant-d 错落感）：一城一摞——同卡重复 4 张
 * 层叠（阶梯偏移/转角序列在 CSS），堆底「城市 · n 位」小字。
 */
function CityPiles({ archive }: { archive: FlashbackCapsuleArchive }) {
	const tCorridor = useTranslations("flashback.corridor");
	const piles = cityPiles(archive);

	if (piles.length === 0) return null;

	return (
		<ul
			className="fb-corridor-piles"
			aria-label={tCorridor("pilesAria", { name: archive.name ?? archive.key })}
		>
			{piles.map((pile, pileIdx) => (
				<li
					key={pile.city}
					className="fb-corridor-pile"
					data-testid="fb-corridor-pile"
					data-city={pile.city}
					data-count={pile.count}
				>
					{/* 堆可点（用户定稿）：点堆直接进该场次页（链接删除后这是唯一入口）。
					    整堆（拍立得+计数）都是可点面，hover/按压反馈在 CSS。 */}
					<Link href={`/flashback/event/${archive.key}`} className="fb-corridor-pile-link">
						{/* 一城一摞（原型 D 错落感）：同卡重复 4 张层叠，阶梯/转角在 CSS */}
						<div className="fb-corridor-stack">
							{[0, 1, 2, 3].map((i) => (
								<div
									key={i}
									className="fb-polaroid fb-grain fb-corridor-polaroid fb-develop-soft"
									/* 原型 --d 手法：(count%5)*0.3 + i*0.2——基数按人数取模打散，
									    同人数的城跨帧同时闪、异人数错开，空间上多点闪耀（群星感） */
									style={{ "--fb-d": `${((pile.count % 5) * 0.3 + i * 0.2).toFixed(1)}s` } as CSSProperties}
								>
									<span className="fb-photo fb-corridor-photo">{pile.city}</span>
									{/* 窗下小字（原型 D）：印在纸白边内，拍立得语感的收尾 */}
									<span className="fb-corridor-caption">{tCorridor("pileCaption", { count: pile.count })}</span>
								</div>
							))}
						</div>
						<p className="fb-corridor-count">{tCorridor("pileCount", { city: pile.city, count: pile.count })}</p>
					</Link>
				</li>
			))}
		</ul>
	);
}

/** 宽屏判定（两形态单源；SSR 快照按窄屏，客户端首帧纠正） */
export function useWideCorridor(): boolean {
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
