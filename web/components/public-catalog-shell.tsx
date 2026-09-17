"use client";

import type { ReactNode } from "react";
import SiteHeader, { type SiteNavLink } from "@/components/site-header";
import type { OfferingKind } from "@/lib/graphql/events";

/** 目录页 kind → 顶导高亮项（倡导活动与活动/课程同列公开入口） */
const ACTIVE_LINK: Record<OfferingKind | "initiative", SiteNavLink> = {
	event: "events",
	course: "courses",
	initiative: "initiatives",
};

export default function PublicCatalogShell({
	activeKind,
	children,
	mainClassName = "",
}: {
	/** 活动/课程/倡导活动目录页传 kind 以高亮对应顶导项；其他公开页省略（不高亮任何项） */
	activeKind?: OfferingKind | "initiative";
	children: ReactNode;
	mainClassName?: string;
}) {
	return (
		<div className="public-catalog">
			<SiteHeader active={activeKind ? ACTIVE_LINK[activeKind] : undefined} />
			<main
				id="main-content"
				className={`public-catalog-main${mainClassName ? ` ${mainClassName}` : ""}`}
			>
				{children}
			</main>
		</div>
	);
}
