"use client";

import type { ReactNode } from "react";
import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import { useAuthed } from "@/lib/auth-provider";
import styles from "./flashback-nav.module.css";

/** 公共页面共用入口；城市只在金句墙与许愿树之间传递，不携带个人链接。 */
export default function FlashbackNav({ active, city, children }: {
	active?: "home" | "voices" | "wishes";
	city?: string | null;
	children?: ReactNode;
}) {
	const t = useTranslations("flashback.nav");
	const { authed, confirmed } = useAuthed();
	const cityQuery = city ? `?city=${encodeURIComponent(city)}` : "";
	return (
		<header className={styles.header}>
			<Link className={styles.brand} href="/">{t("brand")}</Link>
			<nav className={styles.links} aria-label={t("label")}>
				{([
					["home", "/flashback"],
					["voices", `/flashback/voices${cityQuery}`],
					["wishes", `/flashback/wishes${cityQuery}`],
				] as const).map(([key, href]) => (
					<Link key={key} href={href} aria-current={active === key ? "page" : undefined}>{t(key)}</Link>
				))}
			</nav>
			<div className={styles.account}>
				{confirmed && (authed
					? <Link href="/flashback/capsule">{t("capsule")}</Link>
					: <Link href="/login?next=%2Fflashback%2Fcapsule">{t("login")}</Link>)}
			</div>
			{children && <div className={styles.actions}>{children}</div>}
		</header>
	);
}
