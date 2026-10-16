"use client";

/**
 * 对话栏的审批与提问卡片（R19、R20）：agent 停下来等学员时出现，由持有这门课的标签页作答。
 * 标题、命令、提问与选项都来自 agent，一律按纯文本渲染。
 */

import { useId, useState } from "react";
import { useTranslations } from "next-intl";
import type { AnswerValue, CardAnswer, ChatCard, QuestionProperty } from "./use-host-chat";

type Card<K extends ChatCard["kind"]> = Extract<ChatCard, { kind: K }>;

/** 选项原样来自学员的 OMP，与终端里一致；「始终允许」只在这条对话、这个 OMP 进程里有效（U6 真机核验） */
function PermissionCard({ card, busy, onAnswer }: { card: Card<"permission">; busy: boolean; onAnswer: (answer: CardAnswer) => void }) {
	const t = useTranslations("hostChat.card");
	const noteId = useId();
	const always = card.options.find((option) => option.kind === "allow_always");
	return (
		<div className="learning-chat__card" role="group" aria-label={t("permission")}>
			<p className="learning-chat__kicker">
				{t("permission")}
				{card.toolKind ? ` · ${card.toolKind}` : null}
			</p>
			<p className="learning-chat__card-title">{card.title}</p>
			{card.input ? (
				<details className="learning-chat__fold">
					<summary>{t("input")}</summary>
					<pre>{card.input}</pre>
				</details>
			) : null}
			<div className="learning-chat__options">
				{card.options.map((option) => (
					<button
						key={option.optionId}
						type="button"
						className="learning-chat__option"
						disabled={busy}
						aria-describedby={option === always ? noteId : undefined}
						onClick={() => onAnswer({ optionId: option.optionId })}
					>
						{option.name}
					</button>
				))}
			</div>
			{always ? (
				<p id={noteId} className="learning-chat__note">
					{t("alwaysAllowNote", { name: always.name })}
				</p>
			) : null}
		</div>
	);
}

function choicesOf(property: QuestionProperty, options = property.oneOf, values = property.enum): [string, string][] | null {
	if (options) return options.map((option) => [option.const, option.title]);
	return values ? values.map((value) => [value, value]) : null;
}

/** 一个表单字段（ACP elicitation 的 form 模式）：单选、多选、文字、数字、开关；未知类型不渲染 */
function Field({
	name,
	property,
	value,
	hideLabel,
	onChange,
}: {
	name: string;
	property: QuestionProperty;
	value: AnswerValue | undefined;
	/** OMP 的 ask 工具把问题本身当作 q0 的标题：与提问重复时不再显示 */
	hideLabel: boolean;
	onChange: (value: AnswerValue | undefined) => void;
}) {
	const groupName = useId();
	const label = property.title || name;
	const single = property.type === "string" ? choicesOf(property) : null;
	const multi = property.type === "array" ? choicesOf(property, property.items?.anyOf, property.items?.enum) : null;
	if (single || multi) {
		const picked = Array.isArray(value) ? value : [];
		return (
			<fieldset className="learning-chat__field">
				<legend className={hideLabel ? "sr-only" : undefined}>{label}</legend>
				{(single ?? multi)!.map(([optionValue, optionTitle]) => (
					<label key={optionValue} className="learning-chat__choice">
						<input
							type={single ? "radio" : "checkbox"}
							name={groupName}
							checked={single ? value === optionValue : picked.includes(optionValue)}
							onChange={(e) =>
								onChange(
									single
										? optionValue
										: e.target.checked
											? [...picked, optionValue]
											: picked.filter((v) => v !== optionValue),
								)
							}
						/>
						{optionTitle}
					</label>
				))}
			</fieldset>
		);
	}
	if (property.type === "boolean") {
		return (
			<label className="learning-chat__choice">
				<input type="checkbox" checked={value === true} onChange={(e) => onChange(e.target.checked)} />
				{label}
			</label>
		);
	}
	if (property.type === "string" || property.type === "number" || property.type === "integer") {
		const numeric = property.type !== "string";
		return (
			<label className="learning-chat__field">
				<span>{label}</span>
				<input
					type={numeric ? "number" : "text"}
					step={property.type === "integer" ? 1 : undefined}
					value={value === undefined ? "" : String(value)}
					onChange={(e) => {
						const raw = e.target.value;
						onChange(raw === "" ? undefined : numeric ? Number(raw) : raw);
					}}
				/>
			</label>
		);
	}
	return null;
}

function QuestionCard({ card, busy, onAnswer }: { card: Card<"question">; busy: boolean; onAnswer: (answer: CardAnswer) => void }) {
	const t = useTranslations("hostChat.card");
	const [values, setValues] = useState<Record<string, AnswerValue>>({});
	const properties = Object.entries(card.schema.properties ?? {});
	return (
		<form
			className="learning-chat__card"
			role="group"
			aria-label={t("question")}
			onSubmit={(e) => {
				e.preventDefault();
				// 只回填答了的字段：Host 只认 schema 里的键与字符串、数字、布尔、字符串数组
				const content = Object.fromEntries(
					Object.entries(values).filter(([, v]) => !(Array.isArray(v) && v.length === 0) && !Number.isNaN(v)),
				);
				onAnswer({ action: "accept", content });
			}}
		>
			<p className="learning-chat__kicker">{t("question")}</p>
			<p className="learning-chat__card-title">{card.message}</p>
			{properties.map(([name, property]) => (
				<Field
					key={name}
					name={name}
					property={property}
					value={values[name]}
					hideLabel={property.title === card.message}
					onChange={(value) =>
						setValues((current) => {
							const next = { ...current };
							if (value === undefined) delete next[name];
							else next[name] = value;
							return next;
						})
					}
				/>
			))}
			<div className="learning-chat__options">
				<button type="submit" className="learning-chat__primary" disabled={busy}>
					{t("submit")}
				</button>
				<button type="button" className="learning-chat__option" disabled={busy} onClick={() => onAnswer({ action: "decline" })}>
					{t("skip")}
				</button>
			</div>
		</form>
	);
}

export default function HostChatCard({ card, onAnswer }: { card: ChatCard; onAnswer: (answer: CardAnswer) => Promise<void> }) {
	const [busy, setBusy] = useState(false);
	const answer = (value: CardAnswer) => {
		setBusy(true);
		void onAnswer(value).finally(() => setBusy(false));
	};
	return card.kind === "permission" ? (
		<PermissionCard card={card} busy={busy} onAnswer={answer} />
	) : (
		<QuestionCard card={card} busy={busy} onAnswer={answer} />
	);
}
