import { useTranslations } from "next-intl";
import type { QualificationBadge } from "@/lib/graphql/events";
import { QUALIFICATION_BADGE_LABEL } from "@/lib/graphql/events";

/**
 * 公开面成班标签（后端 QualificationBadge 投影，不从计数或当前时间推算）。
 * "open" 与报名标签语义重复，详情页不展示；null 同理隐藏。
 */

const TONE_CLASS: Record<Exclude<QualificationBadge, "open">, string> = {
	confirmed: "border-accent bg-accent-mentionbg text-[var(--accent-strong)]",
	short_by: "border-accent text-[var(--accent-strong)]",
	closed: "border-line-strong bg-soft-2 text-ink-2",
	cancelled: "border-line text-ink-3",
};

export default function QualificationBadgeTag({
	badge,
	shortBy,
}: {
	badge?: QualificationBadge | null;
	shortBy?: number | null;
}) {
	const t = useTranslations();
	if (!badge || badge === "open") return null;
	return (
		<span
			className={`inline-flex flex-none items-center rounded-full border px-2 py-0.5 text-[12px] leading-4 ${TONE_CLASS[badge]}`}
		>
			{badge === "short_by"
				? t(QUALIFICATION_BADGE_LABEL[badge], { count: shortBy ?? 0 })
				: t(QUALIFICATION_BADGE_LABEL[badge])}
		</span>
	);
}
