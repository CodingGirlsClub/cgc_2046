"use client";

import { useState, type FormEvent } from "react";
import { useTranslations } from "next-intl";
import {
	type FlashbackAnswer,
	type FlashbackProgress,
	type FlashbackTodayInput,
	TODAY_FIELDS,
	sentencesWithFogMark,
} from "@/lib/graphql/flashback";
import { useStageTitleFocus } from "./use-reduced-motion";

/** Want/Give 勾选候选（R8：数据层按 Want/Give 分类存储，KTD「回信即参与」） */
const WANT_TAGS = ["want_offline", "want_online", "want_ai_course"] as const;
const GIVE_TAGS = ["give_promote", "give_venue", "give_org", "give_share"] as const;

/** Reconnect 意愿候选（R19） */
const RECONNECT_TAGS = ["job", "project", "social", "hobby"] as const;

/** 表单状态（受控；提交由父级 send-register 在寄出前统一落库） */
export interface TodayFormState extends FlashbackTodayInput {
	quoteLevel: "off" | "anonymous" | "credited";
	/** 句子白名单（多选 toggle）；提交为 chosenQuoteSpans 列表 */
	quotePicks?: { questionKey: string; start: number; len: number }[];
	creditedNote?: string;
}

/** 金句候选：非雾面句（R14 纪律——雾面句不进候选），grapheme 偏移随句携带 */
export interface QuoteCandidate {
	questionKey: string;
	sentence: string;
	start: number;
}

function quoteCandidatesOf(answers: FlashbackAnswer[], today?: Partial<FlashbackTodayInput>): QuoteCandidate[] {
	const result: QuoteCandidate[] = [];
	for (const answer of answers) {
		for (const sentence of sentencesWithFogMark(answer.rawText, answer.fogSpans)) {
			if (!sentence.fogged) result.push({ questionKey: answer.questionKey, sentence: sentence.text, start: sentence.start });
		}
	}
	// 今天正在写的句子也是金句候选(首程表单值,此刻尚无雾面)
	if (today) {
		for (const host of TODAY_FIELDS) {
			const raw = today[host.field];
			if (!raw) continue;
			for (const sentence of sentencesWithFogMark(raw, null)) {
				result.push({ questionKey: host.questionKey, sentence: sentence.text, start: sentence.start });
			}
		}
	}
	return result;
}

export const emptyTodayForm: TodayFormState = {
	quoteLevel: "off",
};

/**
 * 翻面写字（R8）：「今天的你」选填问卷 + Want/Give + 动员勾选（R20）+
 * Newsletter（R18）+ Reconnect（R19）+ 金句授权两档（R31）+ 联系方式
 * 确认/更新入口（R17 掩码回显 + 防劫持验证通道）。
 *
 * 志愿者多一问（AE6）：mobilizationVolunteerLead 仅 role=volunteer 显示。
 * 金句候选只从非雾面句取（R14 摘要卡纪律的同源规则）。
 */
export default function Write({
	role,
	answers,
	progress,
	onNext,
}: {
	role: string;
	answers: FlashbackAnswer[];
	progress: FlashbackProgress;
	onNext: (form: TodayFormState) => void;
}) {
	const t = useTranslations("flashback.write");
	const tagsT = useTranslations("flashback.tags");
	const titleRef = useStageTitleFocus<HTMLHeadingElement>([]);

	const [form, setForm] = useState<TodayFormState>(emptyTodayForm);
	const quoteCandidates = quoteCandidatesOf(answers, form);

	const set = <K extends keyof TodayFormState>(key: K, value: TodayFormState[K]) =>
		setForm((prev) => ({ ...prev, [key]: value }));

	const toggleTag = (key: "wantGiveTags" | "reconnectTags", tag: string) =>
		setForm((prev) => {
			const current = prev[key] ?? [];
			return {
				...prev,
				[key]: current.includes(tag)
					? current.filter((item) => item !== tag)
					: [...current, tag],
			};
		});

	/** 圈选 toggle（多选）：再点取消；顺序 = 提交顺序（首句优先展示） */
	const pickQuote = (candidate: QuoteCandidate) => {
		const pick = {
			questionKey: candidate.questionKey,
			start: candidate.start,
			len: Array.from(candidate.sentence).length,
		};
		setForm((prev) => {
			const current = prev.quotePicks ?? [];
			const exists = current.some(
				(item) => item.questionKey === pick.questionKey && item.start === pick.start,
			);
			return {
				...prev,
				quotePicks: exists
					? current.filter(
							(item) => !(item.questionKey === pick.questionKey && item.start === pick.start),
						)
					: [...current, pick],
			};
		});
	};

	const handleSubmit = (event: FormEvent) => {
		event.preventDefault();
		onNext(form);
	};

	return (
		<form className="fb-write-sheet" data-face="back" onSubmit={handleSubmit}>
			{/* 卡背面 = 今天的你（第 3 件：原独立「写字」阶段并入显影卡背面） */}
			<div className="fb-write-form">
				<h3 className="fb-write-title" ref={titleRef} tabIndex={-1}>
					{t("title")}
				</h3>
				{(
					[
						["nowStatus", "nowLabel", "nowPlaceholder"],
						["want", "wantLabel", "wantPlaceholder"],
						["need", "needLabel", "needPlaceholder"],
						["say", "sayLabel", "sayPlaceholder"],
					] as const
				).map(([field, label, placeholder]) => (
					<div key={field}>
						<label className="fb-field-label" htmlFor={`fb-${field}`}>
							{t(label)}
							{field === "need" ? <span className="fb-hint">{t("courseHint")}</span> : null}
						</label>
						<textarea
							id={`fb-${field}`}
							className="fb-field-textarea"
							placeholder={t(placeholder)}
							value={form[field] ?? ""}
							onChange={(event) => set(field, event.target.value)}
						/>
					</div>
				))}

				<fieldset className="fb-checks">
					<legend className="fb-field-label">{t("wantGiveLegend")}</legend>
					{[...WANT_TAGS, ...GIVE_TAGS].map((tag) => (
						<label key={tag}>
							<input
								type="checkbox"
								checked={(form.wantGiveTags ?? []).includes(tag)}
								onChange={() => toggleTag("wantGiveTags", tag)}
							/>
							{tagsT.has(tag) ? tagsT(tag) : tag}
						</label>
					))}
				</fieldset>

				<fieldset className="fb-checks">
					<legend className="fb-field-label">{t("mobilizationLegend")}</legend>
					<label>
						<input
							type="checkbox"
							checked={form.mobilizationJoin1024 ?? false}
							onChange={(event) => set("mobilizationJoin1024", event.target.checked)}
						/>
						{t("mJoin1024")}
					</label>
					<label>
						<input
							type="checkbox"
							checked={form.mobilizationHelpPromote ?? false}
							onChange={(event) => set("mobilizationHelpPromote", event.target.checked)}
						/>
						{t("mHelpPromote")}
					</label>
					<label>
						<input
							type="checkbox"
							checked={form.mobilizationDonateIntent ?? false}
							onChange={(event) => set("mobilizationDonateIntent", event.target.checked)}
						/>
						{t("mDonate")}
					</label>
					{role === "volunteer" && (
						<label>
							<input
								type="checkbox"
								checked={form.mobilizationVolunteerLead ?? false}
								onChange={(event) => set("mobilizationVolunteerLead", event.target.checked)}
							/>
							{t("mVolunteerLead")}
						</label>
					)}
				</fieldset>

				<fieldset className="fb-checks">
					<legend className="fb-field-label">{t("reconnectLegend")}</legend>
					{RECONNECT_TAGS.map((tag) => (
						<label key={tag}>
							<input
								type="checkbox"
								checked={(form.reconnectTags ?? []).includes(tag)}
								onChange={() => toggleTag("reconnectTags", tag)}
							/>
							{tagsT.has(tag) ? tagsT(tag) : tag}
						</label>
					))}
				</fieldset>

				<label className="fb-checks">
					<input
						type="checkbox"
						checked={form.newsletterOptIn ?? false}
						onChange={(event) => set("newsletterOptIn", event.target.checked)}
					/>
					{t("newsletter")}
				</label>

				<div className="fb-contact">
					<h3 className="fb-field-label">{t("contactTitle")}</h3>
					<p className="fb-hint">
						{t("contactCurrent", {
							phone: progress.maskedPhone ?? t("contactNone"),
							email: progress.maskedEmail ?? t("contactNone"),
						})}
					</p>
					<p className="fb-hint">{t("contactHint")}</p>
				</div>

				<fieldset className="fb-checks fb-quote">
					<legend className="fb-field-label">{t("quoteLegend")}</legend>
					<p className="fb-quote-courage">{t("quoteCourage")}</p>
					{(["off", "anonymous", "credited"] as const).map((level) => (
						<label key={level}>
							<input
								type="radio"
								name="fb-quote-level"
								checked={form.quoteLevel === level}
								onChange={() => set("quoteLevel", level)}
							/>
							{t(`quote_${level}`)}
						</label>
					))}
					{form.quoteLevel !== "off" && (
						<div className="fb-quote-picker">
							<p className="fb-field-label">{t("quotePick")}</p>
							<ul className="fb-quote-list">
								{quoteCandidates.map((candidate) => (
									<li key={`${candidate.questionKey}:${candidate.start}`}>
										<button
											type="button"
											className={`fb-option${
												(form.quotePicks ?? []).some(
													(item) =>
														item.questionKey === candidate.questionKey &&
														item.start === candidate.start,
												)
													? " fb-option-selected"
													: ""
											}`}
											onClick={() => pickQuote(candidate)}
											aria-pressed={(form.quotePicks ?? []).some(
												(item) =>
													item.questionKey === candidate.questionKey &&
													item.start === candidate.start,
											)}
										>
											{candidate.sentence.trim()}
										</button>
									</li>
								))}
							</ul>
							{quoteCandidates.length === 0 && <p className="fb-hint">{t("quoteNoCandidate")}</p>}
						</div>
					)}
					{form.quoteLevel === "credited" && (
						<div>
							<label className="fb-field-label" htmlFor="fb-credited-note">
								{t("creditedNoteLabel")}
							</label>
							<input
								id="fb-credited-note"
								className="fb-field-input"
								placeholder={t("creditedNotePlaceholder")}
								value={form.creditedNote ?? ""}
								onChange={(event) => set("creditedNote", event.target.value)}
							/>
						</div>
					)}
				</fieldset>
			</div>

			<button type="submit" className="fb-cta fb-cta-primary">
				{t("submit")}
			</button>
			<p className="fb-send-note">{t("sendPublicNote")}</p>
		</form>
	);
}
