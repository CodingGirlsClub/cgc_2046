import { useTranslations } from "next-intl";
import type { EnrollmentBadge } from "@/lib/graphql/events";
import { ENROLLMENT_BADGE_LABEL } from "@/lib/graphql/events";

/**
 * 公开面报名标签（R6/KTD1：后端派生 full > starting_soon > enrolling）。
 * 公开页（landing + /events /courses + 详情）统一用它替代 EventStatusTag
 * （活动状态机标签仅留工作区内部页）；token 类随 .ld-root 解析为暗色值。
 */

const TONE_CLASS: Record<EnrollmentBadge, string> = {
	enrolling: "border-accent text-accent",
	starting_soon: "border-accent bg-accent-mentionbg text-accent",
	full: "border-line text-ink-3",
};

export default function EnrollmentBadgeTag({
	badge,
}: {
	badge?: EnrollmentBadge | null;
}) {
	const t = useTranslations();
	if (!badge) return null;
	return (
		<span
			className={`inline-flex flex-none items-center rounded-full border px-2 py-0.5 text-[12px] leading-4 ${TONE_CLASS[badge]}`}
		>
			{t(ENROLLMENT_BADGE_LABEL[badge])}
		</span>
	);
}
