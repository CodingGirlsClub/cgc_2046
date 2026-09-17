"use client";

import { useSyncExternalStore } from "react";
import { useTranslations } from "next-intl";
import type { FlashbackCapsule } from "@/lib/graphql/flashback";
import EventRoster from "./event-roster";
import TodaySlot from "./today-slot";

const WIDE_QUERY = "(min-width: 768px)";

/**
 * 时间走廊（U5/R12）：宽屏横向滚动、窄屏纵向（原型 variant-d/mobile-journey
 * 双形态；布局类名切换由 useWideCorridor 驱动，动效/布局在 flashback.css）。
 * 时间从上（最早场次）往下（今天 + 未来），下滑 = 时间前进。
 */
export default function Corridor({ capsule }: { capsule: FlashbackCapsule }) {
	const t = useTranslations("flashback.corridor");
	const wide = useWideCorridor();

	return (
		<section className={`fb-corridor${wide ? " fb-corridor--wide" : ""}`} aria-label={t("ariaLabel")}>
			{capsule.archives.map((archive) => (
				<article key={archive.key} className="fb-corridor-frame">
					<h3 className="fb-corridor-when">
						{archive.occurredOn?.replace(/-/g, ".") ?? archive.key}
						<span className="fb-corridor-flabel">{archive.name}</span>
					</h3>
					<EventRoster archive={archive} />
				</article>
			))}
			<TodaySlot me={capsule.me} />
		</section>
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
