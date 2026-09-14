"use client";

import type { ReactNode } from "react";
import SiteHeader from "@/components/site-header";
import type { OfferingKind } from "@/lib/graphql/events";

export default function PublicCatalogShell({
	activeKind,
	children,
	mainClassName = "",
}: {
	/** 活动/课程目录页传 kind 以高亮对应顶导项；其他公开页省略（不高亮任何项） */
	activeKind?: OfferingKind;
	children: ReactNode;
	mainClassName?: string;
}) {
	return (
		<div className="public-catalog">
			<SiteHeader
				active={
					activeKind === "event"
						? "events"
						: activeKind === "course"
							? "courses"
							: undefined
				}
			/>
			<main
				id="main-content"
				className={`public-catalog-main${mainClassName ? ` ${mainClassName}` : ""}`}
			>
				{children}
			</main>
		</div>
	);
}
