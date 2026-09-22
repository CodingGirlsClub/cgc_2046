"use client";

import { useEffect, useState, useSyncExternalStore } from "react";
import { useTranslations } from "next-intl";
import { client } from "@/lib/apollo-client";
import { ensureVoterKey } from "@/lib/flashback-voter";
import {
	FLASHBACK_PUBLIC_WISH,
	type FlashbackPublicWish,
} from "@/lib/graphql/flashback";
import WishesWall from "./wishes-wall";

const VOICES_INTRO_SEEN_KEY = "flashback.voicesIntroSeen";
const WISHES_INTRO_SEEN_KEY = "flashback.wishesIntroSeen";

type Direct = FlashbackPublicWish | "gone" | null;

/**
 * 入口编排（wish2 U7/KTD8，与 voices-page 同型）：
 *
 * - `?item=<wish_id>`：客户端 network-only 校验（`flashbackPublicWish` 四条件
 *   口径）——有效 → 直达该愿 + 抑制开场；失效 → 「这个愿望目前无法查看」
 *   （HTTP 200 软 404，不泄露存在性）；item 变化时 direct 状态随 prop 重置
 *   （软导航复用组件实例的既有坑，#808 模式）；
 * - 开场记忆跨页共享（KTD8）：voices 或 wishes 任一已看过开场即不再播。
 */
export default function WishesPage({
	item,
	initialCity,
}: {
	item?: string;
	initialCity?: string;
}) {
	const t = useTranslations("flashback.wishes");
	// undefined = 校验中；null = 无直达；wish = 有效直达；"gone" = 失效
	const [prevItem, setPrevItem] = useState(item);
	const [direct, setDirect] = useState<Direct | undefined>(item ? undefined : null);

	if (prevItem !== item) {
		setPrevItem(item);
		setDirect(item ? undefined : null);
	}

	// 跨页开场记忆（KTD8）：voices ∥ wishes 任一标记即视为已看。
	const introSeen = useSyncExternalStore(
		() => () => {},
		() => {
			try {
				return Boolean(
					window.localStorage.getItem(VOICES_INTRO_SEEN_KEY) ||
						window.localStorage.getItem(WISHES_INTRO_SEEN_KEY),
				);
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
				query: FLASHBACK_PUBLIC_WISH,
				variables: { wishId: item, voterKey: ensureVoterKey(window.localStorage) },
				fetchPolicy: "network-only",
			})
			.then(({ data }) => {
				if (cancelled) return;
				setDirect(data?.flashbackPublicWish ?? "gone");
			})
			.catch(() => {
				if (!cancelled) setDirect("gone");
			});
		return () => {
			cancelled = true;
		};
	}, [item]);

	// 直达校验中：加载壳（不播开场——避免校验完成后的状态闪断）
	if (item && direct === undefined) {
		return (
			<div className="fb-root fb-public">
				<p className="fb-hint" role="status">
					{t("loading")}
				</p>
			</div>
		);
	}

	// 失效视图（U7）：这个愿望目前无法查看 + 看全树入口（软 404 语义）
	if (direct === "gone") {
		return (
			<div className="fb-root fb-public">
				<h1 className="fb-stage-title">{t("goneTitle")}</h1>
				<p className="fb-lead">{t("goneLead")}</p>
				<p className="fb-hint">
					<a href="/flashback/wishes">{t("goneBack")}</a>
				</p>
			</div>
		);
	}

	if (introSeen === null) return null;

	return (
		<WishesWall
			initialItem={direct ?? undefined}
			initialCity={initialCity}
			showIntro={!direct && !introSeen}
		/>
	);
}
