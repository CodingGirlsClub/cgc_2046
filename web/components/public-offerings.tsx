"use client";

/**
 * E-5 #50 公开发现页 /events 与 /courses（站点级，游客免登录）。
 *
 * - 只列 open + public（匿名读策略白名单）；
 * - 无 WorkspaceShell：公开面是站点级漏斗，登录态不影响浏览（J-Visitor）；
 * - 数据唯一真实路径：fetchPublicOfferings（GraphQL 匿名查询）。
 */

import Link from "next/link";
import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import {
	fetchPublicOfferings,
} from "@/lib/public-offerings";
import type { OfferingKind, PublicOfferingItem } from "@/lib/graphql/events";
import {
	ENROLLMENT_POLICY_LABEL,
	OFFERING_LABEL,
} from "@/lib/graphql/events";
import EventStatusTag from "@/components/event-status-tag";
import { formatDeadline } from "@/lib/events";

interface PageState {
	kind: OfferingKind;
	rows: PublicOfferingItem[] | null;
	error: string | null;
}

function OfferingCard({ item, kind }: { item: PublicOfferingItem; kind: OfferingKind }) {
	const t = useTranslations("publicOfferings");
	const base = kind === "event" ? "/events" : "/courses";
	return (
		<Link
			href={`${base}/${item.slug}`}
			className="join-card flex items-center gap-4 !p-6"
		>
			<span className="min-w-0 flex-1">
				<span className="flex items-center gap-2">
					<span className="block truncate text-sm font-medium">{item.title}</span>
					<EventStatusTag status={item.status} />
				</span>
				<span className="mt-1 block text-[13px] leading-5 text-ink-3">
					{ENROLLMENT_POLICY_LABEL[item.enrollmentPolicy]} ·{" "}
					{t("deadline", { deadline: formatDeadline(item.registrationDeadline) })}
				</span>
			</span>
			<span className="flex-none text-ink-3">›</span>
		</Link>
	);
}

export default function PublicOfferingsPage({ kind }: { kind: OfferingKind }) {
	const t = useTranslations("publicOfferings");
	const [state, setState] = useState<PageState>({ kind, rows: null, error: null });

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
	}, [kind, t]);

	const stale = state.kind !== kind;
	const rows = stale ? null : state.rows;
	const loadError = stale ? null : state.error;
	const label = OFFERING_LABEL[kind];
	const otherKind = kind === "event" ? "course" : "event";
	const otherHref = kind === "event" ? "/courses" : "/events";

	return (
		<main className="mx-auto w-full max-w-3xl px-4 py-10">
			<header className="mb-6">
				<p className="text-[13px] text-ink-3">
					<Link href="/" className="hover:text-ink">
						{t("breadcrumbHome")}
					</Link>
					{" › "}
					<strong>{label}</strong>
				</p>
				<h1 className="mt-2 text-2xl font-semibold">
					{t("publicTitle", { label })}
				</h1>
				<p className="mt-1 text-sm text-ink-3">
					{t("publicDesc", { label })}
				</p>
				<Link href={otherHref} className="mt-2 inline-block text-sm text-accent">
					{t("viewOther", { label: OFFERING_LABEL[otherKind] })} ›
				</Link>
			</header>

			{loadError ? (
				<div className="join-card" role="alert">
					{t("loadFailed")}：{loadError}
				</div>
			) : rows === null ? (
				<div className="h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
			) : rows.length === 0 ? (
				<div className="join-card text-center text-sm text-ink-3">
					{t("empty", { label })}
				</div>
			) : (
				<div className="grid gap-3">
					{rows.map((item) => (
						<OfferingCard key={item.id} item={item} kind={kind} />
					))}
				</div>
			)}
		</main>
	);
}
