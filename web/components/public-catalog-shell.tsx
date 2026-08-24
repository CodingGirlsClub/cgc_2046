"use client";

import type { ReactNode } from "react";
import { useTranslations } from "next-intl";
import { BrandLockup } from "@/components/brand";
import LanguageSwitcher from "@/components/language-switcher";
import { Link } from "@/i18n/navigation";
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
	const t = useTranslations("publicOfferings");
	const navT = useTranslations("landing.nav");

	return (
		<div className="public-catalog">
			<header className="public-catalog-nav">
				<div className="public-catalog-container public-catalog-nav__inner">
					<Link href="/" className="public-catalog-nav__brand">
						<BrandLockup />
					</Link>
					<nav
						className="public-catalog-nav__links"
						aria-label={t("navigationLabel")}
					>
						<Link
							href="/events"
							aria-current={activeKind === "event" ? "page" : undefined}
							className={`public-catalog-nav__link${activeKind === "event" ? " public-catalog-nav__link--active" : ""}`}
						>
							{navT("events")}
						</Link>
						<Link
							href="/courses"
							aria-current={activeKind === "course" ? "page" : undefined}
							className={`public-catalog-nav__link${activeKind === "course" ? " public-catalog-nav__link--active" : ""}`}
						>
							{navT("courses")}
						</Link>
					</nav>
					<div className="public-catalog-nav__right">
						<LanguageSwitcher className="public-catalog-nav__lang" />
						<Link href="/login" className="public-catalog-nav__login">
							{navT("login")} <span aria-hidden="true">→</span>
						</Link>
					</div>
				</div>
			</header>

			<main
				id="main-content"
				className={`public-catalog-main${mainClassName ? ` ${mainClassName}` : ""}`}
			>
				{children}
			</main>
		</div>
	);
}
