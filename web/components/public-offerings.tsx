"use client";

/**
 * E-5 #50 公开发现页 /events 与 /courses（站点级，游客免登录）。
 *
 * - 只列 open + public（匿名读策略白名单）；
 * - 无 WorkspaceShell：公开面是站点级漏斗，登录态不影响浏览（J-Visitor）；
 * - 数据唯一真实路径：fetchPublicOfferings（GraphQL 匿名查询）；
 * - 方向 B：跟随站点主题，以品牌导航 + 信息卡承载公开目录；
 * - 行内状态标签 = 后端派生报名 badge（KTD1），卡片分层展示
 *   政策/截止/开始/地点（地点仅 event，R3 兜底「时间待定」「地点待定」）。
 */

import EnrollmentBadgeTag from "@/components/enrollment-badge-tag";
import PublicCatalogShell from "@/components/public-catalog-shell";
import { Link } from "@/i18n/navigation";
import { useEffect, useState } from "react";
import { useLocale, useTranslations } from "next-intl";
import { fetchPublicOfferings, formatVenue, parseVenue } from "@/lib/public-offerings";
import type { OfferingKind, PublicOfferingItem } from "@/lib/graphql/events";
import {
	ENROLLMENT_POLICY_LABEL,
	OFFERING_LABEL,
} from "@/lib/graphql/events";
import { formatDeadline } from "@/lib/events";

interface PageState {
	kind: OfferingKind;
	rows: PublicOfferingItem[] | null;
	error: string | null;
}

function PublicOfferingCard({
	item,
	kind,
}: {
	item: PublicOfferingItem;
	kind: OfferingKind;
}) {
	const t = useTranslations("publicOfferings");
	const tCommon = useTranslations("common");
	const labelsT = useTranslations();
	const locale = useLocale();
	const base = kind === "event" ? "/events" : "/courses";
	const startsAt = formatDeadline(
		item.startsAt ?? null,
		tCommon("timeTbd"),
		locale,
	);
	const venue =
		kind === "event"
			? formatVenue(parseVenue(item.venue)) ?? tCommon("venueTbd")
			: null;

	return (
		<li>
			<Link href={`${base}/${item.slug}`} className="public-catalog-card">
				<span className="public-catalog-card__head">
					<span className="public-catalog-card__title">{item.title}</span>
					<EnrollmentBadgeTag badge={item.enrollmentBadge} />
				</span>

				<dl className="public-catalog-card__facts">
					<div>
						<dt>{t("timeLabel")}</dt>
						<dd>{startsAt}</dd>
					</div>
					{venue ? (
						<div>
							<dt>{t("venueLabel")}</dt>
							<dd>{venue}</dd>
						</div>
					) : null}
				</dl>

				<span className="public-catalog-card__foot">
					<span>
						{labelsT(ENROLLMENT_POLICY_LABEL[item.enrollmentPolicy])}
					</span>
					<span>
						{t("deadline", {
							deadline: formatDeadline(
								item.registrationDeadline,
								tCommon("noDeadline"),
								locale,
							),
						})}
					</span>
					<span className="public-catalog-card__arrow" aria-hidden="true">
						→
					</span>
				</span>
			</Link>
		</li>
	);
}

export default function PublicOfferingsPage({ kind }: { kind: OfferingKind }) {
	const t = useTranslations("publicOfferings");
	const tCommon = useTranslations("common");
	const labelsT = useTranslations();
	const [state, setState] = useState<PageState>({ kind, rows: null, error: null });
	// 重试 nonce：error 态点击重试 → 复位 + 触发 effect 重新拉取
	const [nonce, setNonce] = useState(0);

	useEffect(() => {
		let cancelled = false;

		fetchPublicOfferings(kind)
			.then((rows) => {
				if (!cancelled) setState({ kind, rows, error: null });
			})
			.catch((e: unknown) => {
				if (!cancelled) {
					setState({
						kind,
						rows: null,
						error: e instanceof Error ? e.message : t("loadFailed"),
					});
				}
			});

		return () => {
			cancelled = true;
		};
	}, [kind, nonce, t]);

	const stale = state.kind !== kind;
	const rows = stale ? null : state.rows;
	const loadError = stale ? null : state.error;
	const label = OFFERING_LABEL[kind];
	const otherKind = kind === "event" ? "course" : "event";
	const otherHref = kind === "event" ? "/courses" : "/events";

	function retry() {
		setState({ kind, rows: null, error: null });
		setNonce((n) => n + 1);
	}

	return (
		<PublicCatalogShell activeKind={kind}>
			<div className="public-catalog-container">
					<header className="public-catalog-heading">
						<div>
							<h1>{t("publicTitle", { label: labelsT(label) })}</h1>
							<p>{t("publicDesc", { label: labelsT(label) })}</p>
						</div>
						<Link href={otherHref} className="public-catalog-heading__switch">
							{t("viewOther", { label: labelsT(OFFERING_LABEL[otherKind]) })}
						</Link>
					</header>

					{loadError ? (
						<div className="public-catalog-state" role="alert">
							<p>
								{t("loadFailed")}：{loadError}
							</p>
							<button type="button" onClick={retry} className="public-catalog-retry">
								{tCommon("retry")}
							</button>
						</div>
					) : rows === null ? (
						// 3 块与真实卡片近似等高，加载完成不发生明显布局位移。
						<ul className="public-catalog-grid" aria-hidden="true">
							<li className="public-catalog-skeleton" />
							<li className="public-catalog-skeleton" />
							<li className="public-catalog-skeleton" />
						</ul>
					) : rows.length === 0 ? (
						<p className="public-catalog-state">
							{t("empty", { label: labelsT(label) })}
						</p>
					) : (
						<ul className="public-catalog-grid">
							{rows.map((item) => (
								<PublicOfferingCard key={item.id} item={item} kind={kind} />
							))}
						</ul>
					)}
			</div>
		</PublicCatalogShell>
	);
}
