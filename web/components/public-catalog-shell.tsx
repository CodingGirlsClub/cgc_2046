"use client";

import type { ReactNode } from "react";
import SiteHeader from "@/components/site-header";
import type { OfferingKind } from "@/lib/graphql/events";

export default function PublicCatalogShell({
	activeKind,
	children,
	mainClassName = "",
}: {
	activeKind: OfferingKind;
	children: ReactNode;
	mainClassName?: string;
}) {
	return (
		<div className="public-catalog">
			<SiteHeader active={activeKind === "event" ? "events" : "courses"} />
			<main
				id="main-content"
				className={`public-catalog-main${mainClassName ? ` ${mainClassName}` : ""}`}
			>
				{children}
			</main>
		</div>
	);
}
