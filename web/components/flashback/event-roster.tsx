"use client";

import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from "react";
import { useTranslations } from "next-intl";
import type { FlashbackCapsuleArchive } from "@/lib/graphql/flashback";
import { usePrefersReducedMotion } from "./use-reduced-motion";
import PolaroidFlip from "./polaroid-flip";
import { tiltClass } from "./tilt";

/** 显影类：未进视口 → 前置态；进视口 → 播显影；不启用（reduced/无 IO）→ 无类（终态） */
export function rosterDevelopClass(active: boolean, developed: boolean): string {
	if (!active) return "";
	return developed ? " fb-roster-card--develop" : " fb-roster-card--pending";
}

/** 折叠阈值：首屏叠照张数；不足两行（<2×行容量）的小场不折叠 */
const COLLAPSED_COUNT = 12;

function rosterNeedsFold(total: number): boolean {
	// 12 张一屏约 3-4 行（两列错落）；≥2 行余量才值得折叠（用户规格）
	return total > COLLAPSED_COUNT + 6;
}

/**
 * 场次名册（U5/R12 分层墙 + 用户定稿两态卡）：
 * - 名册 = 一叠**合着的拍立得**（默认卡面：寄出者全名+年份+城市+回来了微标）；
 *   点击 3D 翻转看内容（正面当年雾面段 + 背面今天的你）——PolaroidFlip；
 * - 未寄出者保持结构化卡（姓氏隐名 + 虚线内容位「她的答案，还在等她」，
 *   R12：不寄出不亮名、无内容可翻）；
 * 名册仅含当年实际参与者（后端已滤 not_selected，R12）。
 *
 * 折叠（叠照隐喻）：大场（≥2 行余量）默认叠起——首屏 COLLAPSED_COUNT 张 +
 * 叠层边缘暗示下方更多；「展开全部 XXX 位」散开，再点收起。小场直接全量不折叠。
 *
 * 显影（第 7a 件，对齐原型 D 的 develop-soft 节奏）：卡片进入视口才从模糊到清晰
 * （--pending 前置态 → --develop 动画，只播一次），滚动进视口的新卡同样显影；
 * reduced-motion 或环境无 IntersectionObserver（jsdom）时直接终态。
 */
export default function EventRoster({ archive }: { archive: FlashbackCapsuleArchive }) {
	const t = useTranslations("flashback.roster");
	const [expanded, setExpanded] = useState(false);
	const reduced = usePrefersReducedMotion();
	// 环境能力（IntersectionObserver）用 useSyncExternalStore 读：SSR/首帧取服务端快照
	// false（终态），客户端随即纠正为 true——与 usePrefersReducedMotion 同一手法，
	// 避免水合不一致，也避免「先清晰后模糊」的闪一下。
	const developActive = developEnabled(reduced);
	const { developed, registerCard } = useDevelopOnView(developActive);

	const total = archive.roster.length;
	const fold = rosterNeedsFold(total) && !expanded;
	const visible = fold ? archive.roster.slice(0, COLLAPSED_COUNT) : archive.roster;

	// 展开后的错峰与「进视口才显影」同源：CSS nth-child 递进延迟（KTD9 纪律，零内联 style）
	const renderCard = (entry: FlashbackCapsuleArchive["roster"][number]) => (
		<li
			key={entry.id}
			ref={registerCard}
			data-card-id={entry.id}
			className={`fb-roster-card ${tiltClass(entry.id)}${entry.sentToWallAt ? " fb-roster-card--lit" : ""}${rosterDevelopClass(
				developActive,
				developed.has(entry.id),
			)}`}
			data-testid="fb-roster-card"
			data-sent={entry.sentToWallAt ? "true" : "false"}
		>
			{entry.sentToWallAt ? (
				<PolaroidFlip entry={entry} />
			) : (
				<>
					{/* 未寄出 = 雾卡（原型 F 场次页）：虚框 + 透明窗内姓氏隐名 + 窗下小字 */}
					<span className="fb-roster-photo">
						<span className="fb-roster-name">{entry.surnameMasked}</span>
					</span>
					<span className="fb-roster-facts">
						{[entry.city, entry.occupationThen].filter(Boolean).join(" · ")}
					</span>
					<p className="fb-roster-dashed" aria-label={t("dashedAria")}>
						{t("dashed")}
					</p>
				</>
			)}
		</li>
	);

	return (
		<div className="fb-roster" role="group" aria-label={t("groupAria", { name: archive.name ?? archive.key })}>
			<p className="fb-roster-meta">
				{t("meta", {
					attended: archive.attendedCount ?? archive.roster.length,
					total: archive.roster.length,
				})}
			</p>
			<ul
				className={`fb-roster-grid${fold ? " fb-roster-grid--folded" : ""}`}
				data-total={total}
				data-testid="fb-roster-grid"
			>
				{visible.map((entry) => renderCard(entry))}
				{fold && (
					<li className="fb-roster-card fb-roster-card--stacked" aria-hidden="true">
						<span className="fb-roster-name">{t("stackHint", { count: total - COLLAPSED_COUNT })}</span>
					</li>
				)}
			</ul>
			{rosterNeedsFold(total) && (
				<button
					type="button"
					className="fb-roster-toggle"
					data-testid="fb-roster-toggle"
					aria-expanded={expanded}
					onClick={() => setExpanded((value) => !value)}
				>
					{expanded ? t("collapse", { count: total }) : t("expandAll", { count: total })}
				</button>
			)}
		</div>
	);
}

/**
 * 视口内显影（第 7a 件）：IntersectionObserver 观测每张名册卡，进入视口即记入
 * `developed`（React 渲染出 --develop 类，动画在 CSS）并 unobserve（只播一次）。
 * `developActive=false`（reduced-motion / 无 IntersectionObserver）时一律终态——
 * 前置态与动画都不出现，测试与老环境行为不变。
 */
function useDevelopOnView(enabled: boolean) {
	const [developed, setDeveloped] = useState<ReadonlySet<string>>(() => new Set());
	const observerRef = useRef<IntersectionObserver | null>(null);

	const ensureObserver = useCallback(() => {
		if (!enabled || typeof IntersectionObserver === "undefined") return null;
		if (!observerRef.current) {
			observerRef.current = new IntersectionObserver(
				(entries) => {
					const hits = entries.filter((entry) => entry.isIntersecting);
					if (hits.length === 0) return;
					const ids = hits
						.map((entry) => (entry.target as HTMLElement).dataset.cardId ?? "")
						.filter((id) => id !== "");
					hits.forEach((entry) => observerRef.current?.unobserve(entry.target));
					setDeveloped((prev) => new Set([...prev, ...ids]));
				},
				{ rootMargin: "0px 0px -6% 0px", threshold: 0.1 },
			);
		}
		return observerRef.current;
	}, [enabled]);

	useEffect(() => () => observerRef.current?.disconnect(), []);

	const registerCard = useCallback(
		(node: HTMLLIElement | null) => {
			const observer = ensureObserver();
			if (node && observer) observer.observe(node);
		},
		[ensureObserver],
	);

	return { developed, registerCard };
}

/** 显影是否启用：非 reduced-motion 且环境有 IntersectionObserver（能力只读一次） */
function developEnabled(reduced: boolean): boolean {
	const supported = useSyncExternalStore(
		() => () => {},
		() => typeof IntersectionObserver !== "undefined",
		() => false,
	);
	return supported && !reduced;
}
