"use client";

import { useEffect, useState } from "react";
import { useLocale, useTranslations } from "next-intl";
import PublicCatalogShell from "@/components/public-catalog-shell";
import { Link, useRouter } from "@/i18n/navigation";
import { formatDeadline } from "@/lib/events";
import { fetchPublicInitiative, type InitiativeEvent, type PublicInitiative } from "@/lib/graphql/initiatives";
import { formatAmountShort, positiveAmountOrNull } from "@/lib/payment";
import { formatVenue, parseVenue } from "@/lib/public-offerings";
import { toParagraphs } from "@/lib/text-paragraphs";

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
	// 缴费槽三态文案复用管理面同一份（`offerings.paymentSlot*`）——同一句话只有一个
	// 出处，公开页与报名页口径不可能漂移（#627）。
	const tPayment = useTranslations("offerings");
	const locale = useLocale();
	const router = useRouter();
	const [data, setData] = useState<PublicInitiative | null>(null);
	const [loading, setLoading] = useState(true);
	const [error, setError] = useState(false);
	const [selectedCity, setSelectedCity] = useState<string | null>(null); // null = 全部
	const [descExpanded, setDescExpanded] = useState(false);

	const badgeText = (event: InitiativeEvent): string => {
		switch (event.qualificationBadge) {
			case "cancelled": return t("cancelled");
			case "closed": return t("closed");
			case "confirmed": return t("qualified");
			case "short_by": return t("shortBy", { count: event.shortBy ?? 0 });
			default: return t("open");
		}
	};

	/**
	 * 参与条件（#627）：缴费槽**单槽三态**（免费 / 收费 ¥xx 起 / 押金 ¥xx（到场退））
	 * + 年龄门槛存在性（「限 18+」），不投校验策略。
	 *
	 * 三态互斥只出一枚，绝不出现「免费」与「押金 ¥69」并列（R10/KTD10 同纪律）；
	 * 金额缺失/非正 → 不表态形态（`positiveAmountOrNull` 守卫），绝不 ¥0；
	 * 缴费态未知/缺失 → 「缴费信息待定」，绝不 fail-open 成「免费」（#586 同红线）。
	 * **成班进度不在本行**：由既有成班徽章承载（#593 裁决：minParticipants 是阈值
	 * 不是名额，两个数字不互相解释）。
	 */
	const conditionText = (event: InitiativeEvent): string => {
		const payment = (() => {
			if (event.paymentMode === "deposit") {
				const amount = positiveAmountOrNull(event.deposit?.amountCents);
				// 不表态文案单源在 `offerings`（#675）：全仓只此一个 key 承载该句
				return amount === null
					? tPayment("paymentSlotDepositUnknown")
					: tPayment("paymentSlotDeposit", { amount: formatAmountShort(amount) });
			}
			if (event.paymentMode === "pricing") {
				const from = positiveAmountOrNull(event.priceRangeMinCents);
				return from === null
					? t("paymentPricingUnknown")
					: tPayment("paymentSlotPricing", {
							overview: t("priceFrom", { amount: formatAmountShort(from) }),
						});
			}
			if (event.paymentMode === "free") return tPayment("paymentSlotFree");
			// 未知/缺失态**不猜**：落「缴费信息待定」而非「免费」——用默认值冒充事实
			// 正是 #586 的病根（把押金场说成免费），这里同一条红线。
			return t("paymentUnknown");
		})();

		// 年龄门槛只渲染**正数**（与 F5 后端同判据、与金额守卫同精神）：`minAge: 0`
		// 只会来自陈旧 payload，渲染成「限 0+」比不渲染更糟。
		return typeof event.minAge === "number" && event.minAge > 0
			? t("conditionWithAge", { payment, age: event.minAge })
			: payment;
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

	const allEvents = data.cities.flatMap((g) => g.events.map((e) => ({ ...e, city: g.city })));
	const visibleEvents = selectedCity === null ? allEvents : allEvents.filter((e) => e.city === selectedCity);

	const descParagraphs = toParagraphs(data.description);
	const descLength = descParagraphs.reduce((n, p) => n + p.length, 0);
	// 阈值收折：短描述（≤300 字且 ≤3 段）原样完整展示；长描述默认前 2 段
	const descCollapsible = descParagraphs.length > 3 || descLength > 300;
	const visibleDescParagraphs = descCollapsible && !descExpanded ? descParagraphs.slice(0, 2) : descParagraphs;

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
			{data.description ? (
				<div className="initiative-hero__desc">
					{visibleDescParagraphs.map((p, i) => <p key={i}>{p}</p>)}
					{descCollapsible ? (
						<button type="button" className="initiative-hero__desc-toggle"
							aria-expanded={descExpanded}
							onClick={() => setDescExpanded((v) => !v)}>
							{descExpanded ? t("descCollapse") : t("descExpand")}
						</button>
					) : null}
				</div>
			) : null}
			<dl className="initiative-stats">
				<div><dt>{t("cities")}</dt><dd>{data.cityCount}</dd></div>
				<div><dt>{t("events")}</dt><dd>{data.eventCount}</dd></div>
				<div><dt>{t("participants")}</dt><dd>{data.confirmedCount}</dd></div>
				<div><dt>{t("qualified")}</dt><dd>{data.qualifiedEventCount}</dd></div>
			</dl>
		</header>
		{data.cities.length > 1 ? (
			<div className="initiative-filter" role="group" aria-label={t("filterByCity")}>
				<button type="button" aria-pressed={selectedCity === null}
					className={`initiative-filter__chip${selectedCity === null ? " initiative-filter__chip--active" : ""}`}
					onClick={() => setSelectedCity(null)}>
					{t("allCities")}
				</button>
				{data.cities.map((g) => (
					<button key={g.city} type="button" aria-pressed={selectedCity === g.city}
						className={`initiative-filter__chip${selectedCity === g.city ? " initiative-filter__chip--active" : ""}`}
						onClick={() => setSelectedCity(g.city)}>
						{g.city} · {t("cityEvents", { count: g.events.length })}
					</button>
				))}
			</div>
		) : null}
		<ul className="public-catalog-grid">{visibleEvents.map((event) => {
			const startsAt = formatDeadline(event.startsAt, tCommon("timeTbd"), locale);
			const venue = formatVenue(parseVenue(event.venue)) ?? tCommon("venueTbd");
			return <li key={event.id}>
				<Link href={`/events/${event.slug}`} className={`public-catalog-card${event.archived ? " initiative-card--archived" : ""}`}>
					<span className="public-catalog-card__head">
						<span className="public-catalog-card__title">{event.title}</span>
						<span className={`initiative-badge initiative-badge--${BADGE_TONE[event.qualificationBadge]}`}>{badgeText(event)}</span>
					</span>
					{/* 参与条件（#627）独占一行：`__head` 是 nowrap flex（标题 flex:1 +
						成班徽章 flex:none），与成班徽章同排会把标题挤到 0px（360px 视口实测：
						titleW 0 → 182.8）。成班进度仍只由上一行的徽章承载，本行不出人数。 */}
					<span className="initiative-badge initiative-badge--condition">{conditionText(event)}</span>
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
	</div></PublicCatalogShell>;
}
