"use client";

import { useTranslations } from "next-intl";
import type { FlashbackProfile } from "@/lib/graphql/flashback";
import { useStageTitleFocus } from "./use-reduced-motion";

export type QuizChoice = "correct" | "dunno";

/**
 * 记忆问答（R6）：pilot 单场事实下定位为**认领后的确认而非考察**——
 * 选项 = 本人真实场次 +「我不记得了」兜底；「重挑一张」出口回散照。
 * 选兜底直接给正确答案、无挫败文案（AE2：选择后父级展示
 * 「没关系——我们替你记得」并进入显影）。
 */
export default function Quiz({
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
		<section className="fb-stage fb-stage-pad">
			<h2 className="fb-stage-title" ref={titleRef} tabIndex={-1}>
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
		</section>
	);
}
