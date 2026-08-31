"use client";

import { useTranslations } from "next-intl";
import { BrandLockup } from "@/components/brand";
import LanguageSwitcher from "@/components/language-switcher";
import { Link } from "@/i18n/navigation";

export type SiteNavLink = "events" | "courses";

/**
 * 站点级品牌导航条（全站唯一实现，R8 parity 同源零跳变原则）。
 *
 * 首页、公开目录（/events /courses 及详情）、其余站点级页面共用同一组件
 * 与单套 .site-nav token，跨页 header 字号 / 字重 / 高度 / 间距全等。
 * active 高亮当前目录：aria-current + 底部 accent 下划线（inset box-shadow，
 * 不占布局空间，切换不引起跳动）。主题跟随所处容器：首页 .ld-root 深色
 * 门面与全局双主题均按 CSS 变量解析。
 */
export default function SiteHeader({ active }: { active?: SiteNavLink }) {
	const t = useTranslations("landing.nav");

	return (
		<header className="site-nav">
			<div className="site-nav__inner">
				<Link href="/" className="site-nav__brand">
					<BrandLockup />
				</Link>
				<nav className="site-nav__links" aria-label={t("ariaLabel")}>
					<Link
						href="/events"
						aria-current={active === "events" ? "page" : undefined}
						className={`site-nav__link${active === "events" ? " site-nav__link--active" : ""}`}
					>
						{t("events")}
					</Link>
					<Link
						href="/courses"
						aria-current={active === "courses" ? "page" : undefined}
						className={`site-nav__link${active === "courses" ? " site-nav__link--active" : ""}`}
					>
						{t("courses")}
					</Link>
				</nav>
				<div className="site-nav__right">
					<LanguageSwitcher className="site-nav__lang" />
					<Link href="/login" className="site-nav__login">
						{t("login")} <span aria-hidden="true">→</span>
					</Link>
					<Link href="/register" className="join-button join-button--primary">
						{t("join")}
					</Link>
				</div>
			</div>
		</header>
	);
}
