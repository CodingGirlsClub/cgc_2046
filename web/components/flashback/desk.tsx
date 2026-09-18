"use client";

import { useState } from "react";
import type {
	FlashbackAnswer,
	FlashbackDreamTarget,
	FlashbackProfile,
	FlashbackProgress,
} from "@/lib/graphql/flashback";
import Scatter from "./scatter";
import QuizSheet, { type QuizChoice } from "./quiz";
import Reveal from "./reveal";
import type { TodayFormState } from "./write";

/**
 * 散照桌面场景（原型 B/E 的「场景连续性」核心）：散照、问答、显影、翻面写字
 * 全在**同一场景**里完成，不再一页一步——
 *
 *  1. 桌面散照（scatter.tsx）：点一张放大到最前，可反复换着看；
 *  2. 问答 bottom sheet 同屏弹出（quiz.tsx）：「重挑一张」关 sheet 回桌面；
 *  3. 选定 → 桌面退到背景 + 被选的那张**原位显影**（reveal.tsx：1.2s 中速显影
 *     = 全流程唯一的慢时刻），同一位置出现可翻面的拍立得与书写面。
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
	onAnswer: (choice: QuizChoice) => void;
	onRevealed: () => void;
	onWriteNext: (form: TodayFormState) => void;
}) {
	/** 被认领（放大）的那张：null = 还在挑 */
	const [picked, setPicked] = useState<number | null>(startOnBack ? 0 : null);
	/** 圆梦线（信封）不走散照/问答：拆开即显影当年答案 + 1024 邀请（R9）；
	 *  记忆线走「散照 → 同屏问答 → 原位显影」；回访（AE9）直达显影。 */
	const dream = line === "dream";
	const revealed = quizChoice !== null || startOnBack || dream;

	return (
		<div className={`fb-desk${revealed ? " fb-desk--revealed" : ""}`}>
			{!dream && (
				<Scatter
					profile={profile}
					picked={picked}
					dimmed={revealed}
					onPick={(index) => setPicked(index)}
				/>
			)}
			{/* 问答与散照同屏（原型 B）：未选定时才在场 */}
			{!dream && picked !== null && !revealed && (
				<QuizSheet profile={profile} onAnswer={onAnswer} onRepick={() => setPicked(null)} />
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
