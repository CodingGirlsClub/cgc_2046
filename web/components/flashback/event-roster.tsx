"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import type { FlashbackCapsuleArchive } from "@/lib/graphql/flashback";
import { usePrefersReducedMotion } from "./use-reduced-motion";
import PolaroidFlip from "./polaroid-flip";
import { tiltClass } from "./tilt";

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
 * 叠层边缘暗示下方更多；「展开全部 XXX 位」散开（stagger 渐入照显影语言），
 * 再点收起。小场直接全量不折叠。
 */
export default function EventRoster({ archive }: { archive: FlashbackCapsuleArchive }) {
	const t = useTranslations("flashback.roster");
	const [expanded, setExpanded] = useState(false);
	const reduced = usePrefersReducedMotion();

	const total = archive.roster.length;
	const fold = rosterNeedsFold(total) && !expanded;
	const visible = fold ? archive.roster.slice(0, COLLAPSED_COUNT) : archive.roster;

	// stagger 渐入在 CSS（.fb-roster-card--in + nth-child 递进延迟，KTD9 纪律）
	const renderCard = (entry: FlashbackCapsuleArchive["roster"][number]) => (
		<li
			key={entry.id}
			className={`fb-roster-card ${tiltClass(entry.id)}${entry.sentToWallAt ? " fb-roster-card--lit" : ""}${
				expanded && !reduced ? " fb-roster-card--in" : ""
			}`}
			data-testid="fb-roster-card"
			data-sent={entry.sentToWallAt ? "true" : "false"}
		>
			{entry.sentToWallAt ? (
				<PolaroidFlip entry={entry} />
			) : (
				<>
					<div className="fb-roster-head">
						<span className="fb-roster-name">{entry.surnameMasked}</span>
						<span className="fb-roster-facts">
							{[entry.city, entry.occupationThen].filter(Boolean).join(" · ")}
						</span>
					</div>
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
