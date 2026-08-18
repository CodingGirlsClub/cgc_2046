"use client";

/**
 * /admin 布局（Phase 7 / R1 前端）。
 *
 * AdminGuard 门控（D6 方案 A）+ 平台管理导航。
 * 各页面（Phase 8/9 填充数据源）作为 server components 渲染在 client layout 内。
 *
 * 样式：admin-* 组件类（globals.css），Linear token 双主题自适应（#113 样式收敛）。
 */
import Link from "next/link";
import { usePathname } from "next/navigation";
import AdminGuard from "@/components/admin-guard";
import { Icon } from "@/components/icons";

const ADMIN_NAV = [
	{ href: "/admin", label: "概览", exact: true },
	{ href: "/admin/workspaces", label: "工作台" },
	{ href: "/admin/users", label: "用户" },
	{ href: "/admin/applications", label: "申请审批" },
	{ href: "/admin/audit", label: "审计" },
	{ href: "/admin/reconciliation", label: "对账" },
	{ href: "/admin/openclacky", label: "OpenClacky" },
];

export default function AdminLayout({
	children,
}: Readonly<{ children: React.ReactNode }>) {
	const pathname = usePathname();

	return (
		<AdminGuard>
			<div className="admin-shell">
				<header className="admin-topbar">
					<div className="admin-topbar__inner">
						<Link href="/admin" className="admin-brand">
							平台管理
						</Link>
						<nav aria-label="平台管理导航" className="admin-nav">
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
										{item.label}
									</Link>
								);
							})}
						</nav>
						<Link href="/" className="admin-topbar__exit">
							<Icon name="arrow-left" size={14} />
							<span>返回工作台</span>
						</Link>
					</div>
				</header>
				<main className="admin-page">{children}</main>
			</div>
		</AdminGuard>
	);
}
