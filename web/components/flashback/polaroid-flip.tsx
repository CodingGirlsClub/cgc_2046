"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { appliedStamp, type FlashbackRosterEntry } from "@/lib/graphql/flashback";

/**
 * 合着→翻转的两态拍立得（用户定稿 ①，原型 A 的 rotateY + D 的白边卡面）：
 *
 * - 默认态（卡面）：白边拍立得合着——寄出者**全名** + 年份 + 城市 +
 *   「她回来了」微标记（金色小点，视觉暗示不堆文字）；
 * - 点击 → 3D 翻转（fb-flip-scene/fb-flip-inner，U4 既有语言）：
 *   正面 = 当年答案（雾面段渲染 + 时间戳白边脚注）；
 *   背面 = 今天的你（写过则显示；没写显示「背面还是空白的」空态）；
 * - 再点翻回卡面态；reduced-motion 由 fb-root 全局 --fb-flip-dur 归零直达终态；
 * - 无障碍：button 承载翻转、aria-expanded 表态、两面内容读屏均可达
 *   （翻转只改视觉，3D 背面 backface 隐藏仅为视觉层）。
 */
export default function PolaroidFlip({ entry }: { entry: FlashbackRosterEntry }) {
	const t = useTranslations("flashback.roster.flip");
	const questionT = useTranslations("flashback.questionLabels");
	const [flipped, setFlipped] = useState(false);

	const stamp = appliedStamp(entry.appliedAt);
	const today = entry.today;
	const hasToday = Boolean(today?.nowStatus || today?.want || today?.say);

	return (
		<button
			type="button"
			className="fb-polaroid-flip"
			data-testid="fb-polaroid-flip"
			data-flipped={flipped ? "true" : "false"}
			aria-expanded={flipped}
			onClick={() => setFlipped((value) => !value)}
		>
			{/* 合着卡面（默认态）：照片区灰窗内是名字（原型 D/F 的拍立得语言——
			   白边 + 灰窗 + 下方标注小字），年份·城市做窗下小字 */}
			{!flipped && (
				<span className="fb-flip-cover">
					<span className="fb-flip-cover-photo">
						<span className="fb-flip-cover-dot" aria-hidden="true" />
						<span className="fb-visually-hidden">{t("backAria")}</span>
						<span className="fb-flip-cover-name">{entry.fullName ?? entry.surnameMasked}</span>
					</span>
					<span className="fb-flip-cover-facts">
						{[stamp?.slice(0, 4) ?? "", entry.city].filter(Boolean).join(" · ")}
					</span>
				</span>
			)}

			{flipped && (
				<span className="fb-flip-open">
					{/* 正面：照片区灰窗内是当年答案（雾面段），窗下是时间戳小字 */}
					<span className="fb-flip-face fb-flip-face--front">
						<span className="fb-flip-photo">
						{entry.answers.map((answer) => (
							<span key={answer.questionKey} className="fb-flip-answer">
								<span className="fb-answer-q">
									{questionT.has(answer.questionKey) ? questionT(answer.questionKey) : answer.questionKey}
								</span>
								{answer.segments.map((segment, i) =>
									segment.fog ? (
										<span
											key={i}
											aria-hidden="true"
											className={`fb-fog-block fb-fog-block--${segment.len <= 6 ? "s" : segment.len <= 14 ? "m" : "l"}`}
										/>
									) : (
										<span key={i}>{segment.text}</span>
									),
								)}
							</span>
						))}
						</span>
						<span className="fb-flip-caption">{stamp ?? t("noStamp")}</span>
					</span>
					{/* 背面：今天的你（纸白窗，与正面的灰窗区分） */}
					<span className="fb-flip-face fb-flip-face--back">
						<span className="fb-flip-photo fb-flip-photo--back">
							<span className="fb-answer-q">{t("backTitle")}</span>
							{hasToday ? (
								<>
									{today?.nowStatus && <span className="fb-flip-today-line">{today.nowStatus}</span>}
									{today?.want && <span className="fb-flip-today-line">{today.want}</span>}
									{today?.say && <span className="fb-flip-today-line">{today.say}</span>}
								</>
							) : (
								<span className="fb-flip-today-empty">{t("backEmpty")}</span>
							)}
						</span>
					</span>
				</span>
			)}
		</button>
	);
}
