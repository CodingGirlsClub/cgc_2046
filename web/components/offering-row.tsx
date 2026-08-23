import { Link } from "@/i18n/navigation";
import { useLocale, useTranslations } from "next-intl";
import { formatDeadline } from "@/lib/events";
import type { OfferingKind, PublicOfferingItem } from "@/lib/graphql/events";
import { ENROLLMENT_POLICY_LABEL } from "@/lib/graphql/events";
import EnrollmentBadgeTag from "@/components/enrollment-badge-tag";

/**
 * 活动/课程公开行（R8 parity）：landing 首页与 /events、/courses 公开列表
 * 同源共用，两处渲染零跳变。meta 基线 = 政策标签 · 截止时间；调用点经
 * meta prop 追加段（公开列表页追加开始时间/地点，landing 首页不追加）。
 * 截止文案取 publicOfferings.deadline（与 landing.sections.deadline 同值）。
 */

export default function OfferingRow({
	item,
	kind,
	meta = [],
}: {
	item: PublicOfferingItem;
	kind: OfferingKind;
	/** 追加 meta 段，按序拼在基线之后（公开列表页传开始时间/地点） */
	meta?: string[];
}) {
	const t = useTranslations("publicOfferings");
	const tCommon = useTranslations("common");
	const labelsT = useTranslations();
	const locale = useLocale();
	const base = kind === "event" ? "/events" : "/courses";
	const segments = [
		labelsT(ENROLLMENT_POLICY_LABEL[item.enrollmentPolicy]),
		t("deadline", {
			deadline: formatDeadline(
				item.registrationDeadline,
				tCommon("noDeadline"),
				locale,
			),
		}),
		...meta,
	];
	return (
		<li>
			<Link href={`${base}/${item.slug}`} className="ld-offer-row">
				<span className="ld-offer-row__main">
					<span className="ld-offer-row__title">{item.title}</span>
					<EnrollmentBadgeTag badge={item.enrollmentBadge} />
				</span>
				<span className="ld-offer-row__meta">{segments.join(" · ")}</span>
				<span className="ld-offer-row__arrow" aria-hidden="true">
					→
				</span>
			</Link>
		</li>
	);
}
