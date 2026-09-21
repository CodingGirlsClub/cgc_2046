"use client";

import { useTranslations } from "next-intl";
import { useStageTitleFocus } from "./use-reduced-motion";

export type QuizChoice = "correct" | "wrong" | "dunno";

/** 场次候选（R5 数据驱动）：label 派生自散照（去重、保序），isMine 标正确项 */
export interface QuizCandidate {
	label: string;
	isMine: boolean;
}

/**
 * 从散照候选派生问答选项：label 去重、保留首次出现顺序；同一 label 只要有一张
 * 是本人的场次即视为正确项。候选 >=2 场 → 问答流程；=1 场（pilot 上线初期）
 * 由 desk 自适应跳过问答（消除「无谜之谜」）。
 */
export function quizCandidatesOf(photos: { label: string; isMine: boolean }[]): QuizCandidate[] {
	const seen = new Map<string, boolean>();
	for (const photo of photos) {
		const known = seen.get(photo.label);
		seen.set(photo.label, known === true || photo.isMine);
	}
	return [...seen.entries()].map(([label, isMine]) => ({ label, isMine }));
}

/**
 * 记忆问答（R6，原型 B：问答与散照**同屏**的 bottom sheet）：
 *
 * - 批次二数据驱动：选项 = 散照里出现过的**真实场次**（本人场次 + 其他场次
 *   干扰项），不再是单场占位——选「别的场次」即答错（wrong 三态）；
 * - 「我不记得了」兜底直接给正确场次、无挫败文案（AE2）；「重挑一张」回散照；
 * - 非模态：不锁背景滚动/焦点（选完即走，可以换着看别的照片再选）。
 */
export default function QuizSheet({
	candidates,
	onAnswer,
	onRepick,
}: {
	candidates: QuizCandidate[];
	onAnswer: (choice: QuizChoice) => void;
	onRepick: () => void;
}) {
	const t = useTranslations("flashback.quiz");
	const titleRef = useStageTitleFocus<HTMLHeadingElement>([]);

	return (
		<div className="fb-quiz-sheet" data-testid="fb-quiz-sheet" role="group" aria-labelledby="fb-quiz-title">
			<h2 className="fb-quiz-title" id="fb-quiz-title" ref={titleRef} tabIndex={-1}>
				{t("question")}
			</h2>
			<p className="fb-quiz-hint">{t("sheetHint")}</p>
			<div className="fb-options">
				{candidates.map((candidate) => (
					<button
						key={candidate.label}
						type="button"
						className="fb-option"
						data-testid="fb-quiz-option"
						data-mine={candidate.isMine ? "true" : "false"}
						onClick={() => onAnswer(candidate.isMine ? "correct" : "wrong")}
					>
						<span>{candidate.label}</span>
					</button>
				))}
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
