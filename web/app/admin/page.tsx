"use client";

/**
 * /admin 首页仪表盘概览（Phase 8）。
 * 简单统计（工作台 / 用户 / 待审批申请）+ 子页入口。
 * 统计加载失败不阻塞页面（显示 —）。
 */
import Link from "next/link";
import { useEffect, useState } from "react";
import { fetchApplications, fetchUsers, fetchWorkspaces } from "@/lib/admin";

export default function AdminHomePage() {
	const [counts, setCounts] = useState<{
		workspaces: number | null;
		users: number | null;
		applications: number | null;
	}>({ workspaces: null, users: null, applications: null });

	useEffect(() => {
		let cancelled = false;
		(async () => {
			const [ws, users, apps] = await Promise.allSettled([
				fetchWorkspaces(undefined, { first: 100 }),
				fetchUsers(undefined, { first: 100 }),
				fetchApplications("pending", { first: 100 }),
			]);
			if (cancelled) return;
			setCounts({
				workspaces:
					ws.status === "fulfilled" ? ws.value.length : null,
				users: users.status === "fulfilled" ? users.value.length : null,
				applications:
					apps.status === "fulfilled" ? apps.value.length : null,
			});
		})();
		return () => {
			cancelled = true;
		};
	}, []);

	const stats: Array<{
		label: string;
		value: number | null;
		href: string;
	}> = [
		{ label: "工作台总数", value: counts.workspaces, href: "/admin/workspaces" },
		{ label: "用户总数", value: counts.users, href: "/admin/users" },
		{ label: "待审批申请数", value: counts.applications, href: "/admin/applications" },
	];

	return (
		<section>
			<h1 className="text-2xl font-semibold mb-1">平台管理概览</h1>
			<p className="text-neutral-600 text-sm mb-6">
				平台管理员仪表盘。
			</p>

			<div className="grid grid-cols-3 gap-4 mb-8">
				{stats.map((s) => (
					<Link
						key={s.label}
						href={s.href}
						className="rounded-lg border border-neutral-200 p-4 hover:bg-neutral-50"
					>
						<div
							aria-label={s.label}
							className="text-2xl font-semibold"
						>
							{s.value ?? "—"}
						</div>
						<div className="text-sm text-neutral-500 mt-1">{s.label}</div>
					</Link>
				))}
			</div>

			<nav aria-label="平台管理入口" className="flex flex-col gap-1">
				<Link href="/admin/workspaces" className="text-sm text-blue-600 hover:underline">
					工作台管理
				</Link>
				<Link href="/admin/users" className="text-sm text-blue-600 hover:underline">
					用户管理
				</Link>
				<Link href="/admin/applications" className="text-sm text-blue-600 hover:underline">
					申请审批
				</Link>
				<Link href="/admin/audit" className="text-sm text-blue-600 hover:underline">
					审计
				</Link>
				<Link href="/admin/openclacky" className="text-sm text-blue-600 hover:underline">
					OpenClacky
				</Link>
			</nav>
		</section>
	);
}
