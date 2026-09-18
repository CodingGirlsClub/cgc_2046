"use client";

import { useTranslations } from "next-intl";
import { surnameMasked, type FlashbackProfile } from "@/lib/graphql/flashback";
import { useStageTitleFocus } from "./use-reduced-motion";

/** 散照张数（pilot 单场事实：认领不设对错，每张都是候选） */
export const SCATTER_COUNT = 3;

/**
 * 桌面散照（原型 B「桌面散照式」，E 的散照步同源）：一叠模糊旧照片散在桌上，
 * 点一张放大到最前（scale 1.28 + 摆正 + z 提升），可反复换着看；问答在同屏
 * bottom sheet（desk.tsx 组装），选定后原位显影。
 *
 * 位置/转角/入场延迟全部由 CSS nth-child 驱动（KTD9：零内联 style）且确定性
 * ——同一张卡每次都在同一处，换着看不会跳位；入场仍是「快显影 0.6s + 错峰」。
 * 键盘可操作：每张照片是 button（Enter/Space 触发），`aria-pressed` 表态。
 *
 * 角色差异化（教练看学员名单/志愿者看档案）依赖导入数据，2014-01-11
 * 场仅学员视角——散照统一为本场城市的照片堆。
 */
export default function Scatter({
	profile,
	picked,
	dimmed = false,
	onPick,
}: {
	profile: FlashbackProfile;
	picked: number | null;
	/** 已选定（显影中/已显影）：桌面退到背景，把注意力让给卡片 */
	dimmed?: boolean;
	onPick: (index: number) => void;
}) {
	const t = useTranslations("flashback.scatter");
	const titleRef = useStageTitleFocus<HTMLHeadingElement>([]);

	const city = profile.archive?.city ?? profile.city ?? "";

	return (
		<section className={`fb-desk-scene${dimmed ? " fb-desk-scene--done" : ""}`}>
			<h2 className="fb-stage-title" ref={titleRef} tabIndex={-1}>
				{t("title")}
			</h2>
			<p className="fb-lead">{t("hint")}</p>
			<div className="fb-desk-table" role="group" aria-label={t("groupAria")}>
				{Array.from({ length: SCATTER_COUNT }, (_, index) => (
					<button
						key={index}
						type="button"
						className={`fb-polaroid fb-grain fb-scatter-photo${
							picked === index ? " fb-scatter-photo--picked" : ""
						}`}
						data-testid="fb-scatter-photo"
						data-picked={picked === index ? "true" : "false"}
						aria-pressed={picked === index}
						onClick={() => onPick(index)}
						aria-label={t("cardAria", { city, index: index + 1 })}
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
