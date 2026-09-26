"use client";

import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { client } from "@/lib/apollo-client";
import {
	FLASHBACK_ADJUST_FOG,
	sentencesWithFogMark,
	type FlashbackCapsuleMe,
	type FlashbackFogSpan,
} from "@/lib/graphql/flashback";
import { normalizeSpans, sameSpans, toggleSpanIn } from "./fog-toggle";
import { useDialogA11y } from "../modal-a11y";

/** 保存成功轻反馈后自动关弹层的停留时长（today-actions 同款） */
const SAVED_LINGER_MS = 600;

/**
 * M4：寄出后回访也能逐句调「当年答案」的雾。flashbackAdjustFog 双入口
 * （token 或登录态），今天雾的编辑在 today-actions；本组件管「当年答案」。
 * 脏检查与 today 同纪律：区间相对服务端基线没变的答案零 mutation，
 * 全部切回亮也显式同步清雾；雾调整失败暂停在上墙前，可重试。
 */
export default function AnswersFog({
	me,
	token,
	onChanged,
}: {
	me: FlashbackCapsuleMe;
	token: string | null;
	onChanged: () => void;
}) {
	const t = useTranslations("flashback.answersFog");
	const questionT = useTranslations("flashback.questionLabels");
	const [editing, setEditing] = useState(false);

	return (
		<>
			<button type="button" className="fb-cta" onClick={() => setEditing(true)}>
				{t("entry")}
			</button>
			{editing && (
				<AnswersFogDialog
					me={me}
					token={token}
					questionT={questionT}
					onClose={() => setEditing(false)}
					onSaved={() => {
						setEditing(false);
						onChanged();
					}}
				/>
			)}
		</>
	);
}

function AnswersFogDialog({
	me,
	token,
	questionT,
	onClose,
	onSaved,
}: {
	me: FlashbackCapsuleMe;
	token: string | null;
	questionT: ReturnType<typeof useTranslations>;
	onClose: () => void;
	onSaved: () => void;
}) {
	const t = useTranslations("flashback.answersFog");
	const { dialogRef, handleKeyDown } = useDialogA11y(onClose);
	const [spansByAnswer, setSpansByAnswer] = useState<Record<string, FlashbackFogSpan[]>>(() =>
		Object.fromEntries(me.answers.map((answer) => [answer.id, [...(answer.fogSpans ?? [])]])),
	);
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState(false);
	const [saved, setSaved] = useState(false);

	useEffect(() => {
		if (!saved) return;
		const timer = window.setTimeout(onSaved, SAVED_LINGER_MS);
		return () => window.clearTimeout(timer);
	}, [saved, onSaved]);

	const save = async () => {
		if (busy || saved) return;
		setBusy(true);
		setError(false);
		try {
			for (const answer of me.answers) {
				const next = normalizeSpans(spansByAnswer[answer.id]);
				if (sameSpans(next, normalizeSpans(answer.fogSpans))) continue;
				const { data } = await client.mutate({
					mutation: FLASHBACK_ADJUST_FOG,
					variables: { token: token ?? null, answerId: answer.id, spans: next },
				});
				if (!data?.flashbackAdjustFog) {
					setError(true);
					return;
				}
			}
			setSaved(true);
		} catch {
			setError(true);
		} finally {
			setBusy(false);
		}
	};

	return (
		<div className="fb-send-overlay" onKeyDown={handleKeyDown}>
			<div
				className="fb-send-step fb-today-dialog"
				role="dialog"
				aria-modal="true"
				aria-labelledby="fb-answers-fog-title"
				tabIndex={-1}
				ref={dialogRef}
				data-testid="fb-answers-fog-dialog"
			>
				<h3 id="fb-answers-fog-title" className="fb-send-title">
					{t("title")}
				</h3>
				{saved ? (
					<p className="fb-promise" role="status">
						{t("saved")}
					</p>
				) : (
					<>
						{me.answers.map((answer) => (
							<div key={answer.id}>
								<p className="fb-field-label">
									{questionT.has(answer.questionKey) ? questionT(answer.questionKey) : answer.questionKey}
								</p>
								<div className="fb-review-sentences">
									{sentencesWithFogMark(answer.rawText, spansByAnswer[answer.id]).map((sentence) => (
										<button
											key={sentence.start}
											type="button"
											className={`fb-review-sentence${sentence.fogged ? " fb-review-sentence--fog" : ""}`}
											aria-pressed={sentence.fogged}
											onClick={() =>
												setSpansByAnswer((prev) => toggleSpanIn(prev, answer.id, sentence))
											}
										>
											<span className="fb-review-sentence-text">{sentence.text}</span>
											{sentence.fogged && (
												<span className="fb-review-fog-badge" aria-hidden="true">
													{t("fogBadge")}
												</span>
											)}
										</button>
									))}
								</div>
							</div>
						))}
						{me.answers.length === 0 && <p className="fb-hint">{t("none")}</p>}
						<p className="fb-hint">{t("hint")}</p>
						{error && (
							<p role="alert" className="fb-hint">
								{t("error")}
							</p>
						)}
						<button
							type="button"
							className="fb-cta fb-cta-primary"
							disabled={busy}
							onClick={() => void save()}
						>
							{busy ? t("saving") : t("save")}
						</button>
						<button type="button" className="fb-cta" disabled={busy} onClick={onClose}>
							{t("cancel")}
						</button>
					</>
				)}
			</div>
		</div>
	);
}
