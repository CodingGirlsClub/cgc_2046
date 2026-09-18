"use client";

import { useTranslations } from "next-intl";
import type { FlashbackProfile } from "@/lib/graphql/flashback";
import { useStageTitleFocus } from "./use-reduced-motion";

export type QuizChoice = "correct" | "dunno";

/**
 * 记忆问答（R6，原型 B：问答与散照**同屏**的 bottom sheet）：pilot 单场事实下
 * 定位为**认领后的确认而非考察**——选项 = 本人真实场次 +「我不记得了」兜底；
 * 「重挑一张」出口回散照（关 sheet、取消放大）。选兜底直接给正确答案、无挫败
 * 文案（AE2：父级展示「没关系——我们替你记得」并原位显影）。
 *
 * 非模态：不锁背景滚动/焦点（选完即走，玩家可以换着看别的照片再选）。
 */
export default function QuizSheet({
	profile,
	onAnswer,
	onRepick,
}: {
	profile: FlashbackProfile;
	onAnswer: (choice: QuizChoice) => void;
	onRepick: () => void;
}) {
	const t = useTranslations("flashback.quiz");
	const titleRef = useStageTitleFocus<HTMLHeadingElement>([]);

	const archiveName = profile.archive?.name ?? t("fallbackArchiveName");
	const occurredOn = profile.archive?.occurredOn?.replace(/-/g, ".");

	return (
		<div className="fb-quiz-sheet" data-testid="fb-quiz-sheet" role="group" aria-labelledby="fb-quiz-title">
			<h2 className="fb-quiz-title" id="fb-quiz-title" ref={titleRef} tabIndex={-1}>
				{t("question")}
			</h2>
			<div className="fb-options">
				<button type="button" className="fb-option" onClick={() => onAnswer("correct")}>
					<span>
						{archiveName}
						{occurredOn ? ` · ${occurredOn}` : ""}
					</span>
					<span className="fb-option-hint">{t("myEventHint")}</span>
				</button>
				<button type="button" className="fb-option" onClick={() => onAnswer("dunno")}>
					<span>{t("dontRemember")}</span>
					<span className="fb-option-hint">{t("dontRememberHint")}</span>
				</button>
				<button type="button" className="fb-option" onClick={onRepick}>
					<span>{t("repick")}</span>
					<span className="fb-option-hint">{t("repickHint")}</span>
				</button>
			</div>
		</div>
	);
}
