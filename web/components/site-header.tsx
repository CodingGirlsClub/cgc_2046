"use client";

import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { BrandLockup } from "@/components/brand";
import LanguageSwitcher from "@/components/language-switcher";
import { Link, usePathname } from "@/i18n/navigation";
import { useAuthed } from "@/lib/use-authed";

export type SiteNavLink = "campaign" | "events" | "courses" | "initiatives" | "flashback" | "voices" | "wishes";

/**
 * 站点级品牌导航条（全站唯一实现，R8 parity 同源零跳变原则）。
 *
 * 首页、公开目录（/events /courses 及详情）、其余站点级页面共用同一组件
 * 与单套 .site-nav token，跨页 header 字号 / 字重 / 高度 / 间距全等。
 * active 高亮当前目录：aria-current + 底部 accent 下划线（inset box-shadow，
 * 不占布局空间，切换不引起跳动）。主题跟随所处容器：首页 .ld-root 深色
 * 门面与全局双主题均按 CSS 变量解析。
 *
 * 响应式（视觉审计 2026-09）：桌面 ≥1281px 完整横排（en 长标签不再断词换行或
 * 裁掉登录/注册按钮）；≤1280px 收起为「菜单」按钮 + 抽屉，抽屉内容与桌面同源
 * 同序（含登录/加入我们/语言切换），Escape、路径变化均自动收起。
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

	// 抽屉开关按「打开时的 pathname」派生：next-intl Link 软导航不卸载组件，
	// 路径一变 menuOpen 自然变 false，无需 effect 调整 state。
	const [openForPath, setOpenForPath] = useState<string | null>(null);
	const menuOpen = openForPath !== null && openForPath === pathname;
	const closeMenu = () => setOpenForPath(null);

	useEffect(() => {
		if (!menuOpen) return;
		const onKeyDown = (event: KeyboardEvent) => {
			if (event.key === "Escape") setOpenForPath(null);
		};
		document.addEventListener("keydown", onKeyDown);
		return () => document.removeEventListener("keydown", onKeyDown);
	}, [menuOpen]);

	type NavItem = { href: string; label: string; link?: SiteNavLink };
	const items: NavItem[] = [
		// 十周年主 campaign（2026.10-2027 全年）：站内唯一入口，活动结束随本项一并移除
		{ href: "/hackerstart-1024", label: t("campaign"), link: "campaign" },
		{ href: "/events", label: t("events"), link: "events" },
		{ href: "/courses", label: t("courses"), link: "courses" },
		...(signedIn
			? [
					{ href: "/participations", label: t("myParticipations") },
					{ href: "/learning", label: t("myLearning") },
					{ href: "/flashback/capsule", label: t("myFlashback") },
				]
			: []),
		{ href: "/initiatives", label: t("initiatives"), link: "initiatives" },
		// 闪念间入口（R10）：Initiative 边上——传播回流的第一落点
		{ href: "/flashback", label: t("flashback"), link: "flashback" },
		// 金句墙入口（R26）：独立公开页的目录级入口——与闪念间并列
		{ href: "/flashback/voices", label: t("voices"), link: "voices" },
		// 许愿树入口（2026-09 视觉审计后产品位阶提升）：公开树原来只藏在闪念间
		// 流程与金句墙页脚，升为一级导航公开入口（桌面第 7 项/抽屉殿后）
		{ href: "/flashback/wishes", label: t("wishes"), link: "wishes" },
	];

	const linkClass = (link?: SiteNavLink) =>
		`site-nav__link${link && active === link ? " site-nav__link--active" : ""}`;
	const linkAriaCurrent = (link?: SiteNavLink) =>
		link && active === link ? ("page" as const) : undefined;

	return (
		<header className="site-nav">
			<div className="site-nav__inner">
				<Link href="/" className="site-nav__brand">
					<BrandLockup />
				</Link>
				<nav className="site-nav__links" aria-label={t("ariaLabel")}>
					{items.map((item) => (
						<Link
							key={item.href}
							href={item.href}
							aria-current={linkAriaCurrent(item.link)}
							className={linkClass(item.link)}
						>
							{item.label}
						</Link>
					))}
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
				<button
					type="button"
					className="site-nav__menu-button"
					aria-label={t("menu")}
					aria-expanded={menuOpen}
					aria-controls="site-nav-drawer"
					onClick={() => setOpenForPath(menuOpen ? null : pathname)}
				>
					<span className="site-nav__menu-icon" aria-hidden="true" />
				</button>
			</div>
			{menuOpen ? (
				<>
					{/* 点击抽屉外任意处收起（键盘路径由 Escape 覆盖，本元素不参与 tab 序） */}
					<div
						className="site-nav__backdrop"
						aria-hidden="true"
						onClick={closeMenu}
					/>
					<div id="site-nav-drawer" className="site-nav__drawer">
						<div className="site-nav__drawer-inner">
							<nav aria-label={t("ariaLabel")} className="site-nav__drawer-links">
								{items.map((item) => (
									<Link
										key={item.href}
										href={item.href}
										aria-current={linkAriaCurrent(item.link)}
										className={linkClass(item.link)}
									>
										{item.label}
									</Link>
								))}
							</nav>
							<div className="site-nav__drawer-auth">
								{signedIn ? (
									<Link href="/" className="join-button join-button--primary">
										{t("workspace")}
									</Link>
								) : (
									<>
										<Link href={withNext("/login")} className="site-nav__login">
											{t("login")} <span aria-hidden="true">→</span>
										</Link>
										<Link
											href={withNext("/register")}
											className="join-button join-button--primary"
										>
											{t("join")}
										</Link>
									</>
								)}
								<LanguageSwitcher className="site-nav__drawer-lang" />
							</div>
						</div>
					</div>
				</>
			) : null}
		</header>
	);
}
