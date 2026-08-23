"use client";

/**
 * E-5 #50 公开发现页 /events 与 /courses（站点级，游客免登录；U4 全暗重建）。
 *
 * - 只列 open + public（匿名读策略白名单）；
 * - 无 WorkspaceShell：公开面是站点级漏斗，登录态不影响浏览（J-Visitor）；
 * - 数据唯一真实路径：fetchPublicOfferings（GraphQL 匿名查询）；
 * - 固定深色门面（R7/KD2）：.ld-root 重声明暗色 token，html.light 下仍为深色；
 * - 行式列表（R8）：复用 landing OfferingRow 同款 .ld-offer-row 语言，零跳变；
 *   行内状态标签 = 后端派生报名 badge（KTD1），meta 行排政策/截止/开始/地点
 *   （地点仅 event，R3 兜底「时间待定」「地点待定」）。
 */

import { Link } from "@/i18n/navigation";
import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { fetchPublicOfferings, formatVenue, parseVenue } from "@/lib/public-offerings";
import type { OfferingKind, PublicOfferingItem } from "@/lib/graphql/events";
import {
	ENROLLMENT_POLICY_LABEL,
	OFFERING_LABEL,
} from "@/lib/graphql/events";
import EnrollmentBadgeTag from "@/components/enrollment-badge-tag";
import { formatDeadline } from "@/lib/events";

interface PageState {
	kind: OfferingKind;
	rows: PublicOfferingItem[] | null;
	error: string | null;
}

function OfferingRow({ item, kind }: { item: PublicOfferingItem; kind: OfferingKind }) {
	const t = useTranslations("publicOfferings");
	const tCommon = useTranslations("common");
	const labelsT = useTranslations();
	const base = kind === "event" ? "/events" : "/courses";
	// 时间为空/非法 → 「时间待定」；空 venue → 「地点待定」（R3，任何面不出现空白）
	const starts = formatDeadline(item.startsAt ?? null, "");
	const venue = kind === "event" ? formatVenue(parseVenue(item.venue)) : null;
	const meta = [
		labelsT(ENROLLMENT_POLICY_LABEL[item.enrollmentPolicy]),
		t("deadline", {
			deadline: formatDeadline(item.registrationDeadline, tCommon("noDeadline")),
		}),
		starts ? t("startsAt", { time: starts }) : tCommon("timeTbd"),
	];
	if (kind === "event") meta.push(venue ?? tCommon("venueTbd"));
	return (
		<li>
			<Link href={`${base}/${item.slug}`} className="ld-offer-row">
				<span className="ld-offer-row__main">
					<span className="ld-offer-row__title">{item.title}</span>
					<EnrollmentBadgeTag badge={item.enrollmentBadge} />
				</span>
				<span className="ld-offer-row__meta">{meta.join(" · ")}</span>
				<span className="ld-offer-row__arrow" aria-hidden="true">
					→
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
		<main className="ld-root">
			<div className="ld-container py-16">
				<header className="mb-10">
					<p className="text-[13px] text-ink-3">
						<Link href="/" className="hover:text-ink">
							{t("breadcrumbHome")}
						</Link>
						{" › "}
						<strong>{labelsT(label)}</strong>
					</p>
					<h1 className="ld-section__title mt-3">
						{t("publicTitle", { label: labelsT(label) })}
					</h1>
					<p className="ld-section__desc">
						{t("publicDesc", { label: labelsT(label) })}
					</p>
					<Link href={otherHref} className="ld-section__more mt-3 inline-block">
						{t("viewOther", { label: labelsT(OFFERING_LABEL[otherKind]) })}
					</Link>
				</header>

				{loadError ? (
					<div role="alert">
						<p className="ld-offer-fallback">
							{t("loadFailed")}：{loadError}
						</p>
						<button
							type="button"
							onClick={retry}
							className="join-button join-button--outline mt-4"
						>
							{tCommon("retry")}
						</button>
					</div>
				) : rows === null ? (
					// 3 块与真实行等高的 skeleton：加载完成不发生布局位移（同 landing）
					<div aria-hidden="true">
						<div className="ld-skeleton" />
						<div className="ld-skeleton" />
						<div className="ld-skeleton" />
					</div>
				) : rows.length === 0 ? (
					<p className="ld-offer-fallback">{t("empty", { label: labelsT(label) })}</p>
				) : (
					<ul className="ld-offers">
						{rows.map((item) => (
							<OfferingRow key={item.id} item={item} kind={kind} />
						))}
					</ul>
				)}
			</div>
		</main>
	);
}
