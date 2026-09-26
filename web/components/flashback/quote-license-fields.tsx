"use client";

import type { ReactNode } from "react";
import { useTranslations } from "next-intl";

export interface QuoteLicenseCandidate {
	questionKey: string;
	start: number;
	len: number;
	sentence: string;
}

export type QuoteLicensePick = { questionKey: string; start: number; len: number };

/**
 * 金句授权「档位 + 圈选」共用字段组（R31）：首程（write）与长廊授权面板
 * （quote-license-panel）的规则只写一处——三档 radio、off 不渲染圈选器、
 * 圈选 toggle 上抛区间三件套（questionKey/start/len）、空候选提示。
 * 候选的构造（非雾面句、来源宿主）由调用方决定；圈选身份 = questionKey+start。
 */
export default function QuoteLicenseFields({
	level,
	onLevelChange,
	candidates,
	picks,
	onTogglePick,
	radioName = "fb-quote-level",
	legend,
	children,
}: {
	level: string;
	onLevelChange: (level: "off" | "anonymous" | "credited") => void;
	candidates: QuoteLicenseCandidate[];
	picks: QuoteLicensePick[];
	onTogglePick: (pick: QuoteLicensePick) => void;
	/** radio 组名：同页多实例时不串组 */
	radioName?: string;
	legend?: ReactNode;
	children?: ReactNode;
}) {
	const writeT = useTranslations("flashback.write");
	const isPicked = (candidate: QuoteLicenseCandidate) =>
		picks.some((item) => item.questionKey === candidate.questionKey && item.start === candidate.start);

	return (
		<fieldset className="fb-checks fb-quote">
			{legend}
			<p className="fb-quote-courage">{writeT("quoteCourage")}</p>
			{(["off", "anonymous", "credited"] as const).map((value) => (
				<label key={value}>
					<input
						type="radio"
						name={radioName}
						checked={level === value}
						onChange={() => onLevelChange(value)}
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
									onClick={() =>
										onTogglePick({
											questionKey: candidate.questionKey,
											start: candidate.start,
											len: candidate.len,
										})
									}
								>
									{candidate.sentence.trim()}
								</button>
							</li>
						))}
					</ul>
					{candidates.length === 0 && <p className="fb-hint">{writeT("quoteNoCandidate")}</p>}
				</div>
			)}
			{children}
		</fieldset>
	);
}
