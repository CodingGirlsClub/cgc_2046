"use client";

import { useTranslations } from "next-intl";
import type { FlashbackCapsuleArchive } from "@/lib/graphql/flashback";
import { developClass, useDevelopEnabled, useDevelopOnView } from "./use-develop-on-view";
import PolaroidFlip from "./polaroid-flip";
import { tiltClass } from "./tilt";

/**
 * 场次名册（U5/R12 分层墙 + 用户定稿两态卡；场次页 /flashback/event/[key] 3 列网格）：
 * - 名册 = 一叠**合着的拍立得**（默认卡面：寄出者全名+年份+城市+回来了微标）；
 *   点击 3D 翻转看内容（正面当年雾面段 + 背面今天的你）——PolaroidFlip；
 * - 未寄出者保持结构化卡（姓氏隐名 + 虚线内容位「她的答案，还在等她」，
 *   R12：不寄出不亮名、无内容可翻）；
 * 名册仅含当年实际参与者（后端已滤 not_selected，R12）。
 *
 * 显影（第 7a 件，对齐原型 D 的 develop-soft 节奏）：卡片进入视口才从模糊到清晰
 * （--pending 前置态 → --develop 动画，只播一次），滚动进视口的新卡同样显影；
 * 环境无 IntersectionObserver（jsdom）时直接终态。
 */
export default function EventRoster({ archive }: { archive: FlashbackCapsuleArchive }) {
	const t = useTranslations("flashback.roster");
	// 环境能力（IntersectionObserver）用 useSyncExternalStore 读：SSR/首帧取服务端快照
	// false（终态），客户端随即纠正为 true——避免水合不一致，也避免「先清晰后模糊」的闪一下。
	// 显影是暗房叙事动画，不受 prefers-reduced-motion 短路（用户定稿）。
	const developActive = useDevelopEnabled();
	const { developed, registerDevelop } = useDevelopOnView(developActive);

	return (
		<div className="fb-roster" role="group" aria-label={t("groupAria", { name: archive.name ?? archive.key })}>
			<p className="fb-roster-meta">{t("meta", { total: archive.roster.length })}</p>
			<ul className="fb-roster-grid" data-total={archive.roster.length} data-testid="fb-roster-grid">
				{archive.roster.map((entry) => (
					<li
						key={entry.id}
						ref={registerDevelop}
						data-develop-id={entry.id}
						data-card-id={entry.id}
						className={`fb-roster-card ${tiltClass(entry.id)}${entry.sentToWallAt ? " fb-roster-card--lit" : ""}${developClass(
							"fb-roster-card",
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
				))}
			</ul>
		</div>
	);
}
