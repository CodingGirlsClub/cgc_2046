"use client";

import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import { appliedStamp, yearsAgo, type FlashbackCapsuleMe } from "@/lib/graphql/flashback";

/**
 * 「今天」格（U5/R12/R30）：胶囊时间轴上此 moment 的位置。寄出者亮起显示
 * 自己的卡；未寄出（或撤回后）为虚线位 + 「去寄出」出口——撤回后三处呈现
 * 之二（名册结构化卡 / 今天格虚线 / 已附议保留）。
 */
export default function TodaySlot({ me }: { me: FlashbackCapsuleMe }) {
	const t = useTranslations("flashback.todaySlot");
	const introT = useTranslations("flashback.intro");

	const sent = Boolean(me.today?.sentToWallAt);
	const years = yearsAgo(me.appliedAt);
	const stamp = appliedStamp(me.appliedAt);

	return (
		<article className="fb-corridor-frame fb-corridor-now" data-testid="fb-today-slot" data-sent={sent ? "true" : "false"}>
			<h3 className="fb-corridor-when fb-corridor-when--now">
				{t("when")}
				<span className="fb-corridor-flabel">{t("flabel")}</span>
			</h3>
			<div className={`fb-polaroid fb-grain fb-today-card${sent ? " fb-today-card--lit" : " fb-paper-blank"}`}>
				<div className="fb-photo fb-today-photo">
					{sent ? (
						<div className="fb-answers">
							<span className="fb-answer-q">
								{stamp ? introT("yearsAgo", { years }) + " · " + me.city : me.city}
							</span>
							{me.today?.nowStatus ? <p className="fb-answer-a">{me.today.nowStatus}</p> : null}
							{me.today?.want ? <p className="fb-answer-a">{me.today.want}</p> : null}
						</div>
					) : (
						<div className="fb-today-placeholder">
							<p className="fb-roster-dashed">{t("dashed")}</p>
							<Link href="/flashback/enter" className="fb-cta">
								{t("goSend")}
							</Link>
						</div>
					)}
				</div>
			</div>
		</article>
	);
}
