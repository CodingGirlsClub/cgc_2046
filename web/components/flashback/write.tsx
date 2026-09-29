"use client";

import { useState, type FormEvent } from "react";
import { useTranslations } from "next-intl";
import { type FlashbackProgress, type FlashbackTodayInput } from "@/lib/graphql/flashback";
import { useStageTitleFocus } from "./use-reduced-motion";

/** Want/Give 勾选候选（R8：数据层按 Want/Give 分类存储，KTD「回信即参与」） */
const WANT_TAGS = ["want_offline", "want_online", "want_ai_course"] as const;
const GIVE_TAGS = ["give_promote", "give_venue", "give_org", "give_share"] as const;

/** Reconnect 意愿候选（R19） */
const RECONNECT_TAGS = ["job", "project", "social", "hobby"] as const;

/** 表单状态（受控；提交由父级 send-register 在寄出前统一落库） */
export type TodayFormState = FlashbackTodayInput;

export const emptyTodayForm: TodayFormState = {};

/**
 * 翻面写字（R8）：「今天的你」选填问卷 + Want/Give + 动员勾选（R20）+
 * Newsletter（R18）+ Reconnect（R19）+ 联系方式确认/更新入口（R17 掩码回显 +
 * 防劫持验证通道）。
 *
 * 志愿者多一问（AE6）：mobilizationVolunteerLead 仅 role=volunteer 显示。
 * 金句授权不在这里：#1022 起挪到寄出那一刻（send-register 两按钮），写字面只管写。
 */
export default function Write({
	role,
	progress,
	onNext,
}: {
	role: string;
	progress: FlashbackProgress;
	onNext: (form: TodayFormState) => void;
}) {
	const t = useTranslations("flashback.write");
	const tagsT = useTranslations("flashback.tags");
	const titleRef = useStageTitleFocus<HTMLHeadingElement>([]);

	const [form, setForm] = useState<TodayFormState>(emptyTodayForm);

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

				<label className="fb-check">
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
					<p className="fb-hint">
						{t("contactHint")}{" "}
						<a href="mailto:info@codingirlsclub.com">info@codingirlsclub.com</a>
					</p>
				</div>

			</div>

			<button type="submit" className="fb-cta fb-cta-primary">
				{t("submit")}
			</button>
			<p className="fb-send-note">{t("sendPublicNote")}</p>
		</form>
	);
}
