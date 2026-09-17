"use client";

import { useTranslations } from "next-intl";
import { surnameMasked, type FlashbackProfile } from "@/lib/graphql/flashback";
import { useStageTitleFocus } from "./use-reduced-motion";

/**
 * 散照认领（R5）：一叠模糊旧照片供点击认领。
 *
 * pilot 单场事实（计划 U4 Approach）：认领不设对错——「随便挑一张，
 * 它都会变成你的」；散照以城市快显影呈现（fb-develop-soft，0.6s 档）。
 * 键盘可操作：每张照片是 button（Enter/Space 触发 onPick）。
 *
 * 角色差异化（教练看学员名单/志愿者看档案）依赖导入数据，2014-01-11
 * 场仅学员视角——散照统一为本场城市的照片堆。
 */
export default function Scatter({
	profile,
	onPick,
}: {
	profile: FlashbackProfile;
	onPick: () => void;
}) {
	const t = useTranslations("flashback.scatter");
	const titleRef = useStageTitleFocus<HTMLHeadingElement>([]);

	const city = profile.archive?.city ?? profile.city ?? "";
	const cardLabel = (index: number) => t("cardAria", { city, index });

	return (
		<section className="fb-stage fb-stage-pad">
			<h2 className="fb-stage-title" ref={titleRef} tabIndex={-1}>
				{t("title")}
			</h2>
			<p className="fb-lead">{t("hint")}</p>
			<div className="fb-scatter" role="group" aria-label={t("groupAria")}>
				{[0, 1, 2].map((index) => (
					<button
						key={index}
						type="button"
						className="fb-polaroid fb-grain fb-scatter-photo fb-card-in fb-develop-soft"
						onClick={onPick}
						aria-label={cardLabel(index + 1)}
					>
						<span className="fb-photo">
							{city || t("fallbackCity")}
							<span className="fb-visually-hidden">{t("photoHidden")}</span>
						</span>
						<span className="fb-card-caption">
							<span className="fb-caption-tilt">{surnameMasked(profile.fullName, profile.surname)}</span>
						</span>
					</button>
				))}
			</div>
		</section>
	);
}
