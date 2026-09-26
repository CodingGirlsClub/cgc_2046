"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { useMutation } from "@apollo/client/react";
import {
	FLASHBACK_SET_QUOTE_LICENSE,
	TODAY_FIELDS,
	sentencesWithFogMark,
	type FlashbackCapsuleMe,
} from "@/lib/graphql/flashback";

type QuoteSpan = { questionKey: string; start: number; len: number };

/**
 * 金句授权面板（M1/U9 回访端）：档位三选一 + 圈选，保存时一起发。
 * 与小程序 useQuoteLicense 同语义：off 只关档不清圈选（区间原样随发，
 * 挑句劳动保留），[] 才是显式清空；creditedNote 不在面板里编辑，不随发
 * （#941 起 resolver 只写客户端实际传了的字段，省略 = 保留）。
 * 圈选候选 = 非雾面句（R14 同源规则）；已被雾住的既有圈选不显示也不丢——
 * 保存时仍随发，直到用户主动取消。
 */
export default function QuoteLicensePanel({
	me,
	token,
	onChanged,
}: {
	me: FlashbackCapsuleMe;
	token?: string | null;
	onChanged?: () => void;
}) {
	const t = useTranslations("flashback.licensePanel");
	const writeT = useTranslations("flashback.write");
	const [runSetQuoteLicense] = useMutation(FLASHBACK_SET_QUOTE_LICENSE);
	const [level, setLevel] = useState(me.quoteLevel ?? "off");
	const [picks, setPicks] = useState<QuoteSpan[]>(me.quoteSpans ?? []);
	const [busy, setBusy] = useState(false);
	const [feedback, setFeedback] = useState<"saved" | "error" | null>(null);

	// 候选 = 当年答案 + 今天四字段中的非雾面句（grapheme 偏移随句携带）
	const candidates: Array<QuoteSpan & { sentence: string }> = [];
	for (const answer of me.answers) {
		for (const sentence of sentencesWithFogMark(answer.rawText, answer.fogSpans)) {
			if (!sentence.fogged) {
				candidates.push({ questionKey: answer.questionKey, sentence: sentence.text, start: sentence.start, len: sentence.len });
			}
		}
	}
	if (me.today) {
		for (const host of TODAY_FIELDS) {
			const raw = me.today[host.field];
			if (!raw) continue;
			for (const sentence of sentencesWithFogMark(raw, me.today.fogSpans?.[host.fog])) {
				if (!sentence.fogged) {
					candidates.push({ questionKey: host.questionKey, sentence: sentence.text, start: sentence.start, len: sentence.len });
				}
			}
		}
	}

	const isPicked = (candidate: QuoteSpan) =>
		picks.some((item) => item.questionKey === candidate.questionKey && item.start === candidate.start);

	const togglePick = (candidate: QuoteSpan) =>
		setPicks((current) =>
			current.some((item) => item.questionKey === candidate.questionKey && item.start === candidate.start)
				? current.filter((item) => !(item.questionKey === candidate.questionKey && item.start === candidate.start))
				: [...current, candidate],
		);

	const save = async () => {
		if (busy) return;
		setBusy(true);
		setFeedback(null);
		try {
			await runSetQuoteLicense({
				variables: { token: token ?? undefined, level, chosenQuoteSpans: picks },
			});
			setFeedback("saved");
			onChanged?.();
		} catch {
			setFeedback("error");
		} finally {
			setBusy(false);
		}
	};

	return (
		<section className="fb-license-panel" aria-label={t("title")}>
			<h3 className="fb-field-label">{t("title")}</h3>
			<fieldset className="fb-checks fb-quote">
				<legend className="fb-quote-courage">{writeT("quoteCourage")}</legend>
				{(["off", "anonymous", "credited"] as const).map((value) => (
					<label key={value}>
						<input
							type="radio"
							name="fb-license-level"
							checked={level === value}
							onChange={() => setLevel(value)}
						/>
						{writeT(`quote_${value}`)}
					</label>
				))}
				{level !== "off" && (
					<div className="fb-quote-picker">
						<p className="fb-field-label">{writeT("quotePick")}</p>
						<ul className="fb-quote-list">
							{candidates.map((candidate) => (
								<li key={`${candidate.questionKey}:${candidate.start}`}>
									<button
										type="button"
										className={`fb-option${isPicked(candidate) ? " fb-option-selected" : ""}`}
										aria-pressed={isPicked(candidate)}
										onClick={() => togglePick(candidate)}
									>
										{candidate.sentence.trim()}
									</button>
								</li>
							))}
						</ul>
						{candidates.length === 0 && <p className="fb-hint">{writeT("quoteNoCandidate")}</p>}
					</div>
				)}
			</fieldset>
			<div className="fb-license-actions">
				<button type="button" className="fb-cta" disabled={busy} onClick={() => void save()}>
					{busy ? t("saving") : t("save")}
				</button>
				{feedback === "saved" && (
					<p role="status" className="fb-hint">
						{t("saved")}
					</p>
				)}
				{feedback === "error" && (
					<p role="alert" className="fb-error">
						{t("error")}
					</p>
				)}
			</div>
		</section>
	);
}
