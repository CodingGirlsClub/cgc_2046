"use client";

/**
 * /admin 布局（Phase 7 / R1 前端）。
 *
 * AdminGuard 门控（D6 方案 A）+ 平台管理导航。
 * 各页面（Phase 8/9 填充数据源）作为 server components 渲染在 client layout 内。
 */
import Link from "next/link";
import { usePathname } from "next/navigation";
import AdminGuard from "@/components/admin-guard";

const ADMIN_NAV = [
	{ href: "/admin", label: "概览", exact: true },
	{ href: "/admin/workspaces", label: "工作台" },
	{ href: "/admin/users", label: "用户" },
	{ href: "/admin/applications", label: "申请审批" },
	{ href: "/admin/audit", label: "审计" },
	{ href: "/admin/openclacky", label: "OpenClacky" },
];

export default function AdminLayout({
	children,
}: Readonly<{ children: React.ReactNode }>) {
	const pathname = usePathname();

	return (
		<AdminGuard>
			<div className="min-h-screen flex flex-col">
				<header className="border-b border-neutral-200">
					<div className="mx-auto max-w-6xl px-4 py-3 flex items-center justify-between">
						<Link href="/admin" className="font-semibold">
							平台管理
						</Link>
						<nav aria-label="平台管理导航" className="flex gap-1">
							{ADMIN_NAV.map((item) => {
								const selected = item.exact
									? pathname === item.href
									: pathname.startsWith(item.href);
								return (
									<Link
										key={item.href}
										href={item.href}
										className={`px-3 py-1.5 rounded-md text-sm ${
											selected
												? "bg-neutral-100 font-medium"
												: "text-neutral-600 hover:bg-neutral-50"
										}`}
										aria-current={selected ? "page" : undefined}
									>
										{item.label}
									</Link>
								);
							})}
						</nav>
					</div>
				</header>
				<main className="mx-auto max-w-6xl w-full px-4 py-8">{children}</main>
			</div>
		</AdminGuard>
	);
}
