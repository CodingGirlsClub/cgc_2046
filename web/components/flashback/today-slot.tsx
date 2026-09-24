"use client";

import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import { appliedStamp, yearsAgo, type FlashbackCapsuleMe } from "@/lib/graphql/flashback";
import TodayActions from "./today-actions";

/**
 * 「今天」格（U5/R12/R30）：胶囊时间轴上此 moment 的位置。寄出者亮起显示
 * 自己的卡；未寄出（或撤回后）为虚线位 + 「去寄出」出口——撤回后三处呈现
 * 之二（名册结构化卡 / 今天格虚线 / 已附议保留）。
 *
 * 「我的卡」动作（G2/G3）：编辑今天的你（token / 登录态双入口）+ 撤下
 * （token 面，已寄出才渲染）——细则在 today-actions.tsx。
 */
export default function TodaySlot({
	me,
	token = null,
	onChanged = () => {},
}: {
	me: FlashbackCapsuleMe;
	/** 撤下与编辑 mutation 的 token（无 token 走登录会话；撤下仅 token 面渲染） */
	token?: string | null;
	/** 保存 / 撤下成功后的数据刷新（重拉 capsule） */
	onChanged?: () => void;
}) {
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
			{/* 「我的卡」动作：编辑今天的你（恒在）；撤下（已寄出 + token 才渲染） */}
			<TodayActions me={me} token={token} onChanged={onChanged} />
		</article>
	);
}
