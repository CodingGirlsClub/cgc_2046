"use client";

/**
 * /admin 布局（Phase 7 / R1 前端）。
 *
 * AdminGuard 门控（D6 方案 A）+ 平台管理导航。
 * 各页面（Phase 8/9 填充数据源）作为 server components 渲染在 client layout 内。
 *
 * 样式：admin-* 组件类（globals.css），Linear token 双主题自适应（#113 样式收敛）。
 */
import { Link } from "@/i18n/navigation";
import { usePathname } from "next/navigation";
import { useTranslations } from "next-intl";
import AdminGuard from "@/components/admin-guard";
import { Icon } from "@/components/icons";

const ADMIN_NAV = [
	{ href: "/admin", label: "navOverview", exact: true },
	{ href: "/admin/workspaces", label: "navWorkspaces" },
	{ href: "/admin/users", label: "navUsers" },
	{ href: "/admin/applications", label: "navApplications" },
	{ href: "/admin/audit", label: "navAudit" },
	{ href: "/admin/reconciliation", label: "navReconciliation" },
	{ href: "/admin/openclacky", label: "navOpenclacky" },
];

export default function AdminLayout({
	children,
}: Readonly<{ children: React.ReactNode }>) {
	const pathname = usePathname();
	const t = useTranslations("admin");

	return (
		<AdminGuard>
			<div className="admin-shell">
				<header className="admin-topbar">
					<div className="admin-topbar__inner">
						<Link href="/admin" className="admin-brand">
							{t("brand")}
						</Link>
						<nav aria-label={t("navAria")} className="admin-nav">
							{ADMIN_NAV.map((item) => {
								const selected = item.exact
									? pathname === item.href
									: pathname.startsWith(item.href);
								return (
									<Link
										key={item.href}
										href={item.href}
										className={`admin-nav__item ${selected ? "admin-nav__item--selected" : ""}`}
										aria-current={selected ? "page" : undefined}
									>
										{t(item.label)}
									</Link>
								);
							})}
						</nav>
						<Link href="/" className="admin-topbar__exit">
							<Icon name="arrow-left" size={14} />
							<span>{t("backToWorkspaces")}</span>
						</Link>
					</div>
				</header>
				<main className="admin-page">{children}</main>
			</div>
		</AdminGuard>
	);
}
