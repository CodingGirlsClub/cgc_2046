"use client";

import { useEffect, useState } from "react";
import { Link, useRouter } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import { fetchPublicInitiative, type InitiativeEvent, type PublicInitiative } from "@/lib/graphql/initiatives";

export default function InitiativePage({ params }: { params: Promise<{ slug: string }> }) {
	const t = useTranslations("initiatives");
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
		void params.then(({ slug }) => fetchPublicInitiative(slug).then((value) => {
			if (!cancelled) { setData(value); setLoading(false); }
		}).catch(() => { if (!cancelled) { setError(true); setLoading(false); } }));
		return () => { cancelled = true; };
	}, [params]);

	if (loading) return <main className="public-catalog-main"><p className="public-catalog-state">{t("loading")}</p></main>;
	if (error || !data) return <main className="public-catalog-main"><section className="public-catalog-state"><h1>{t("notFound")}</h1><button type="button" onClick={() => router.back()}>{t("back")}</button></section></main>;

	return <main className="public-catalog-main"><div className="public-catalog-container initiative-page">
		<header className="public-catalog-heading"><div><p className="initiative-page__hashtag">{data.hashtag}</p><h1>{data.name}</h1><p>{data.description}</p></div></header>
		<dl className="initiative-stats"><div><dt>{t("cities")}</dt><dd>{data.cityCount}</dd></div><div><dt>{t("events")}</dt><dd>{data.eventCount}</dd></div><div><dt>{t("participants")}</dt><dd>{data.confirmedCount}</dd></div><div><dt>{t("qualified")}</dt><dd>{data.qualifiedEventCount}</dd></div></dl>
		{data.cities.map((group) => <section key={group.city} className="initiative-city"><h2>{group.city}</h2><ul className="public-catalog-grid">{group.events.map((event) => <li key={event.id}><Link href={`/events/${event.slug}`} className="public-catalog-card"><span className="public-catalog-card__head"><span className="public-catalog-card__title">{event.title}</span><strong>{badgeText(event)}</strong></span><span>{event.startsAt ? new Date(event.startsAt).toLocaleString() : t("timeTbd")}</span></Link></li>)}</ul></section>)}
	</div></main>;
}
