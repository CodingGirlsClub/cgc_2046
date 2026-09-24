"use client";

import { useState } from "react";
import type {
	FlashbackAnswer,
	FlashbackDreamTarget,
	FlashbackProfile,
	FlashbackProgress,
	FlashbackScatterPhoto,
} from "@/lib/graphql/flashback";
import Scatter from "./scatter";
import QuizSheet, { quizCandidatesOf, type QuizChoice } from "./quiz";
import Reveal from "./reveal";
import type { TodayFormState } from "./write";

/**
 * 散照桌面场景（原型 B/E 的「场景连续性」核心）：散照、问答、显影、翻面写字
 * 全在**同一场景**里完成，不再一页一步——
 *
 *  1. 桌面散照（scatter.tsx）：照片来自多场次（enter scatter 投影），点一张
 *     放大到最前，放大即显影「年份 · 城市」线索；可反复换着看；
 *  2. 问答 bottom sheet 同屏弹出（quiz.tsx）：选项 = 散照里的真实场次（正确项
 *     + 干扰项）+「重挑一张」出口；反馈三态（对/错/不记得——错也有显影回报）；
 *  3. 选定 → 桌面退到背景 + 被选的那张**原位显影**（reveal.tsx：1.2s 中速显影
 *     = 全流程唯一的慢时刻）。
 *
 * 场次候选自适应（批次二）：候选 >=2 场 → 问答流程；**=1 场（pilot 上线初期）
 * → 点照片直接原位显影、跳过问答**——无谜时不再设谜（单场占位问答的教训）。
 *
 * 回访（AE9：已填今天未寄出）可直接落在显影/书写态（startOnBack）；圆梦线
 * （信封）不走散照/问答，拆开即显影（R9）。
 */
export default function Desk({
	profile,
	line,
	dreamTarget,
	quizChoice,
	startOnBack = false,
	role,
	answers,
	progress,
	scatter = [],
	onAnswer,
	onRevealed,
	onWriteNext,
}: {
	profile: FlashbackProfile;
	line: "memory" | "dream";
	dreamTarget: FlashbackDreamTarget | null;
	quizChoice: QuizChoice | null;
	startOnBack?: boolean;
	role: string;
	answers: FlashbackAnswer[];
	progress: FlashbackProgress;
	/** 桌面散照候选（enter scatter 投影；缺失时桌面空态由 scatter 呈现） */
	scatter?: FlashbackScatterPhoto[];
	onAnswer: (choice: QuizChoice) => void;
	onRevealed: () => void;
	onWriteNext: (form: TodayFormState) => void;
}) {
	/** 被认领（放大）的那张：null = 还在挑 */
	const [picked, setPicked] = useState<number | null>(startOnBack ? 0 : null);
	/** 单场自适应：无谜可答，点照片即显影（不产生对/错反馈） */
	const [pickedWithoutQuiz, setPickedWithoutQuiz] = useState(false);

	const candidates = quizCandidatesOf(scatter);
	const needsQuiz = candidates.length >= 2;
	const dream = line === "dream";
	const revealed = quizChoice !== null || startOnBack || dream || pickedWithoutQuiz;

	const handlePick = (index: number) => {
		setPicked(index);
		if (!needsQuiz) setPickedWithoutQuiz(true);
	};

	return (
		<div className={`fb-desk${revealed ? " fb-desk--revealed" : ""}`}>
			{!dream && (
				<Scatter
					photos={scatter}
					picked={picked}
					dimmed={revealed}
					onPick={handlePick}
				/>
			)}
			{/* 问答与散照同屏（原型 B）：仅多场且未选定时在场 */}
			{!dream && picked !== null && needsQuiz && !revealed && (
				<QuizSheet candidates={candidates} onAnswer={onAnswer} onRepick={() => setPicked(null)} />
			)}
			{/* 原位显影：同一场景里长出拍立得（含翻面写字） */}
			{revealed && (
				<div className="fb-desk-reveal" data-testid="fb-desk-reveal">
					<Reveal
						profile={profile}
						line={line}
						dreamTarget={dreamTarget}
						quizChoice={quizChoice}
						startOnBack={startOnBack}
						role={role}
						answers={answers}
						progress={progress}
						onRevealed={onRevealed}
						onWriteNext={onWriteNext}
					/>
				</div>
			)}
		</div>
	);
}
