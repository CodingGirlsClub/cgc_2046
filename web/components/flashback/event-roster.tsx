"use client";

import { useTranslations } from "next-intl";
import type { FlashbackCapsuleArchive } from "@/lib/graphql/flashback";

/**
 * 场次名册（U5/R12 分层墙）：
 * - 结构化层满员——每人一张结构化卡（姓氏隐名 + 城市 + 当年职业，R12）；
 * - 内容层待点亮——未寄出者 today/answers 为空 → 虚线内容位「她的答案，
 *   还等她」；寄出者完整显影（当年雾化版 + 今天摘要）。
 * 名册仅含当年实际参与者（后端已滤 not_selected，R12）。
 */
export default function EventRoster({ archive }: { archive: FlashbackCapsuleArchive }) {
	const t = useTranslations("flashback.roster");
	const questionT = useTranslations("flashback.questionLabels");

	return (
		<div className="fb-roster" role="group" aria-label={t("groupAria", { name: archive.name ?? archive.key })}>
			<p className="fb-roster-meta">
				{t("meta", {
					attended: archive.attendedCount ?? archive.roster.length,
					total: archive.roster.length,
				})}
			</p>
			<ul className="fb-roster-grid">
				{archive.roster.map((entry) => (
					<li
						key={entry.id}
						className={`fb-roster-card${entry.sentToWallAt ? " fb-roster-card--lit" : ""}`}
						data-testid="fb-roster-card"
						data-sent={entry.sentToWallAt ? "true" : "false"}
					>
						<div className="fb-roster-head">
							<span className="fb-roster-name">{entry.surnameMasked}</span>
							<span className="fb-roster-facts">
								{[entry.city, entry.occupationThen].filter(Boolean).join(" · ")}
							</span>
						</div>
						{entry.sentToWallAt ? (
							<div className="fb-roster-content">
								{entry.answers.map((answer) => (
									<p key={answer.questionKey} className="fb-roster-answer">
										<span className="fb-answer-q">
											{questionT.has(answer.questionKey) ? questionT(answer.questionKey) : answer.questionKey}
										</span>
										{answer.text}
									</p>
								))}
								{entry.today?.want ? (
									<p className="fb-roster-today">
										<span className="fb-answer-q">{t("todayTag")}</span>
										{entry.today.want}
									</p>
								) : null}
							</div>
						) : (
							<p className="fb-roster-dashed" aria-label={t("dashedAria")}>
								{t("dashed")}
							</p>
						)}
					</li>
				))}
			</ul>
		</div>
	);
}
