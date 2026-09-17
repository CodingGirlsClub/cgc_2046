"use client";

import { useEffect, useState } from "react";
import { useLocale, useTranslations } from "next-intl";
import PublicCatalogShell from "@/components/public-catalog-shell";
import { Link, useRouter } from "@/i18n/navigation";
import { formatDeadline } from "@/lib/events";
import { fetchPublicInitiative, type InitiativeEvent, type PublicInitiative } from "@/lib/graphql/initiatives";
import { formatVenue, parseVenue } from "@/lib/public-offerings";

/**
 * Initiative 公开详情页主体（/initiatives/[slug] 的客户端渲染面）。
 *
 * 自路由 page.tsx 抽出：Next 的 `generateMetadata` 只在 Server Component 生效，
 * 客户端组件无法声明 canonical/hreflang——抽出后 page.tsx 作为 server wrapper
 * 调 `pageAlternates`（与 /events/[slug]、/courses/[slug] 同款；#239 契约）。
 *
 * 契约：slug 由 server wrapper 解出后传入（组件不再吃 `params` Promise）。
 */

/**
 * 活动级状态文案（#628）：`cancelled`（中止）与 `closed`（收尾）必须分叉——
 * 中止 = 已作废，收尾 = 正常结束留档。两者都仍可直达（slug 是投放契约），
 * hero 文案是唯一的语义出口。
 */
export function initiativeStatusText(status: string, t: (key: string) => string): string {
	switch (status) {
		case "closed": return t("archived");
		case "cancelled": return t("cancelledArchive");
		default: return t("ongoing");
	}
}

const BADGE_TONE: Record<InitiativeEvent["qualificationBadge"], string> = {
	cancelled: "cancelled",
	closed: "closed",
	confirmed: "confirmed",
	short_by: "short",
	open: "open",
};

export default function InitiativeDetail({ slug }: { slug: string }) {
	const t = useTranslations("initiatives");
	const tCommon = useTranslations("common");
	const tOfferings = useTranslations("publicOfferings");
	const locale = useLocale();
	const router = useRouter();
	const [data, setData] = useState<PublicInitiative | null>(null);
	const [loading, setLoading] = useState(true);
	const [error, setError] = useState(false);

	const badgeText = (event: InitiativeEvent): string => {
		switch (event.qualificationBadge) {
			case "cancelled": return t("cancelled");
			case "closed": return t("closed");
			case "confirmed": return t("qualified");
			case "short_by": return t("shortBy", { count: event.shortBy ?? 0 });
			default: return t("open");
		}
	};

	useEffect(() => {
		let cancelled = false;
		void fetchPublicInitiative(slug).then((value) => {
			if (!cancelled) { setData(value); setLoading(false); }
		}).catch(() => { if (!cancelled) { setError(true); setLoading(false); } });
		return () => { cancelled = true; };
	}, [slug]);

	if (loading) return <PublicCatalogShell activeKind="initiative"><div className="public-catalog-container"><p className="public-catalog-state">{t("loading")}</p></div></PublicCatalogShell>;
	if (error || !data) return <PublicCatalogShell activeKind="initiative"><div className="public-catalog-container"><section className="public-catalog-state"><h1>{t("notFound")}</h1><button type="button" className="public-catalog-retry" onClick={() => router.back()}>{t("back")}</button></section></div></PublicCatalogShell>;

	return <PublicCatalogShell activeKind="initiative"><div className="public-catalog-container initiative-page">
		<header className="initiative-hero">
			{data.hashtag ? <p className="initiative-hero__hashtag">{data.hashtag}</p> : null}
			<h1>{data.name}</h1>
			<p className="initiative-hero__status">{initiativeStatusText(data.status, t)}</p>
			{data.status === "cancelled" ? <p className="initiative-hero__cancelled">{t("cancelledNotice")}</p> : null}
			{data.windowStartsAt ? (
				<p className="initiative-hero__window">
					{`${formatDeadline(data.windowStartsAt, tCommon("timeTbd"), locale)} – ${formatDeadline(data.windowEndsAt, tCommon("timeTbd"), locale)}`}
				</p>
			) : null}
			{data.description ? <p className="initiative-hero__desc">{data.description}</p> : null}
			<dl className="initiative-stats">
				<div><dt>{t("cities")}</dt><dd>{data.cityCount}</dd></div>
				<div><dt>{t("events")}</dt><dd>{data.eventCount}</dd></div>
				<div><dt>{t("participants")}</dt><dd>{data.confirmedCount}</dd></div>
				<div><dt>{t("qualified")}</dt><dd>{data.qualifiedEventCount}</dd></div>
			</dl>
		</header>
		{data.cities.map((group) => <section key={group.city} className="initiative-city">
			<header className="initiative-city__head"><h2>{group.city}</h2><span className="initiative-city__count">{t("cityEvents", { count: group.events.length })}</span></header>
			<ul className="public-catalog-grid">{group.events.map((event) => {
				const startsAt = formatDeadline(event.startsAt, tCommon("timeTbd"), locale);
				const venue = formatVenue(parseVenue(event.venue)) ?? tCommon("venueTbd");
				return <li key={event.id}>
					<Link href={`/events/${event.slug}`} className={`public-catalog-card${event.archived ? " initiative-card--archived" : ""}`}>
						<span className="public-catalog-card__head">
							<span className="public-catalog-card__title">{event.title}</span>
							<span className={`initiative-badge initiative-badge--${BADGE_TONE[event.qualificationBadge]}`}>{badgeText(event)}</span>
						</span>
						<dl className="public-catalog-card__facts">
							<div><dt>{tOfferings("timeLabel")}</dt><dd>{startsAt}</dd></div>
							<div><dt>{tOfferings("venueLabel")}</dt><dd>{venue}</dd></div>
							{/* 复用 hero 同 key「报名人数」——同一数量口径（卡片计数与 hero 汇总同源），
							    不各写一份文案；minParticipants 是成班阈值不是名额，成班语义只由徽章承载（#593）。 */}
							<div><dt>{t("participants")}</dt><dd>{event.confirmedCount}</dd></div>
						</dl>
						<span className="public-catalog-card__foot">
							<span>{tOfferings("deadline", { deadline: formatDeadline(event.registrationDeadline, tCommon("noDeadline"), locale) })}</span>
							<span className="public-catalog-card__arrow" aria-hidden="true">→</span>
						</span>
					</Link>
				</li>;
			})}</ul>
		</section>)}
	</div></PublicCatalogShell>;
}
