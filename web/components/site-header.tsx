"use client";

import { useTranslations } from "next-intl";
import { BrandLockup } from "@/components/brand";
import LanguageSwitcher from "@/components/language-switcher";
import { Link, usePathname } from "@/i18n/navigation";
import { useAuthed } from "@/lib/use-authed";

export type SiteNavLink = "campaign" | "events" | "courses" | "initiatives" | "flashback";

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
	const { authed, confirmed } = useAuthed();
	const signedIn = confirmed && authed;
	// 报名引导链路：从公开页点「登录/注册」后必须回得来。
	// home/login/register 本身不构造 next，避免无意义回环。
	const pathname = usePathname();
	const withNext = (href: string) =>
		pathname && !["/", "/login", "/register"].includes(pathname)
			? `${href}?next=${encodeURIComponent(pathname)}`
			: href;

	return (
		<header className="site-nav">
			<div className="site-nav__inner">
				<Link href="/" className="site-nav__brand">
					<BrandLockup />
				</Link>
				<nav className="site-nav__links" aria-label={t("ariaLabel")}>
					{/* 十周年主 campaign（2026.10-2027 全年）：站内唯一入口，活动结束随本项一并移除 */}
					<Link
						href="/hackerstart-1024"
						aria-current={active === "campaign" ? "page" : undefined}
						className={`site-nav__link${active === "campaign" ? " site-nav__link--active" : ""}`}
					>
						{t("campaign")}
					</Link>
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
					{signedIn ? (
						<>
							<Link href="/participations" className="site-nav__link">
								{t("myParticipations")}
							</Link>
							<Link href="/learning" className="site-nav__link">
								{t("myLearning")}
							</Link>
						</>
					) : null}
					<Link
						href="/initiatives"
						aria-current={active === "initiatives" ? "page" : undefined}
						className={`site-nav__link${active === "initiatives" ? " site-nav__link--active" : ""}`}
					>
						{t("initiatives")}
					</Link>
					{/* 闪念间入口（R10）：Initiative 边上——传播回流的第一落点 */}
					<Link
						href="/flashback"
						aria-current={active === "flashback" ? "page" : undefined}
						className={`site-nav__link${active === "flashback" ? " site-nav__link--active" : ""}`}
					>
						{t("flashback")}
					</Link>
				</nav>
				<div className="site-nav__right">
					<LanguageSwitcher className="site-nav__lang" />
					{signedIn ? (
						<Link href="/" className="join-button join-button--primary">
							{t("workspace")}
						</Link>
					) : (
						<>
							<Link href={withNext("/login")} className="site-nav__login">
								{t("login")} <span aria-hidden="true">→</span>
							</Link>
							<Link href={withNext("/register")} className="join-button join-button--primary">
								{t("join")}
							</Link>
						</>
					)}
				</div>
			</div>
		</header>
	);
}
