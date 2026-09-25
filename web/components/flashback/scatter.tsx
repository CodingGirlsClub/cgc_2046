"use client";

import { useTranslations } from "next-intl";
import type { FlashbackScatterPhoto } from "@/lib/graphql/flashback";
import { useStageTitleFocus } from "./use-reduced-motion";

/**
 * 桌面散照（原型 B「桌面散照式」，批次二 R5 数据驱动迭代）：
 *
 * - 照片**来自多场次**（后端 enter scatter 投影：本人那张 + 其他场次各一人），
 *   不再是单场的固定三张——每张绑定一个场次的人与真实日期；
 * - **放大 = 回报**：被放大的那张渐显**拍立得日期戳**（「2016 10 15」，只给
 *   日期不给城市——玩家对照问答里的场次全名，中间有一小步认知参与，猜才
 *   成立，谜不泄底）；
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
						data-stamp={photo.dateStamp}
						aria-pressed={picked === index}
						onClick={() => onPick(index)}
						aria-label={t("cardAria", { index: index + 1, label: photo.label })}
					>
						<span className="fb-photo">
							<span className="fb-scatter-stamp" data-testid="fb-scatter-stamp">
								{photo.dateStamp}
							</span>
							<span className="fb-visually-hidden">{t("photoHidden")}</span>
						</span>
						<span className="fb-card-caption">
							<span className="fb-caption-tilt">
								{picked === index && photo.surname
									// payload 的 surname 即姓本体（名字不下信道）：直接渲染，
									// 复姓（欧阳等）不再被 masked 兜底第一字符折成单字（D14）
									? t("owned", { name: photo.surname })
									: t("mystery")}
							</span>
						</span>
					</button>
				))}
			</div>
		</section>
	);
}
