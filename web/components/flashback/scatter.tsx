"use client";

import { useTranslations } from "next-intl";
import type { FlashbackScatterPhoto } from "@/lib/graphql/flashback";
import { surnameMasked } from "@/lib/graphql/flashback";
import { useStageTitleFocus } from "./use-reduced-motion";

/**
 * 桌面散照（原型 B「桌面散照式」，批次二 R5 数据驱动迭代）：
 *
 * - 照片**来自多场次**（后端 enter scatter 投影：本人那张 + 其他场次各一人），
 *   不再是单场的固定三张——每张绑定一个场次的人与「年份 · 城市」线索；
 * - **放大 = 回报**：被放大的那张显影出线索标签（年份 · 城市，参照原型 B 的
 *   「2012 · 上海」），帮玩家在问答里认出自己的场次；
 * - 单场库（pilot 上线初期）候选仅一张，散照仍是仪式——自适应逻辑在 desk.tsx。
 *
 * 位置/转角/入场延迟全部由 CSS nth-child 驱动（KTD9：零内联 style）且确定性；
 * 键盘可操作：每张照片是 button（Enter/Space 触发），`aria-pressed` 表态。
 */
export default function Scatter({
	photos,
	picked,
	dimmed = false,
	onPick,
}: {
	photos: FlashbackScatterPhoto[];
	picked: number | null;
	/** 已选定（显影中/已显影）：桌面退到背景，把注意力让给卡片 */
	dimmed?: boolean;
	onPick: (index: number) => void;
}) {
	const t = useTranslations("flashback.scatter");
	const titleRef = useStageTitleFocus<HTMLHeadingElement>([]);

	return (
		<section className={`fb-desk-scene${dimmed ? " fb-desk-scene--done" : ""}`}>
			<h2 className="fb-stage-title" ref={titleRef} tabIndex={-1}>
				{t("title")}
			</h2>
			<p className="fb-lead">{t("hint")}</p>
			<div className="fb-desk-table" role="group" aria-label={t("groupAria")}>
				{photos.map((photo, index) => (
					<button
						key={photo.photoKey}
						type="button"
						className={`fb-polaroid fb-grain fb-scatter-photo${
							picked === index ? " fb-scatter-photo--picked" : ""
						}`}
						data-testid="fb-scatter-photo"
						data-picked={picked === index ? "true" : "false"}
						data-mine={photo.isMine ? "true" : "false"}
						data-label={photo.label}
						aria-pressed={picked === index}
						onClick={() => onPick(index)}
						aria-label={t("cardAria", { index: index + 1, label: photo.label })}
					>
						<span className="fb-photo">
							<span className="fb-scatter-label" data-testid="fb-scatter-label">
								{photo.label}
							</span>
							<span className="fb-visually-hidden">{t("photoHidden")}</span>
						</span>
						<span className="fb-card-caption">
							<span className="fb-caption-tilt">
								{picked === index && photo.surname
									? t("owned", { name: surnameMasked(photo.surname, photo.surname) })
									: t("mystery")}
							</span>
						</span>
					</button>
				))}
			</div>
		</section>
	);
}
