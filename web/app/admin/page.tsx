"use client";

/**
 * /admin 首页仪表盘概览（Phase 8）。
 * 简单统计（工作台 / 用户 / 待审批申请）+ 子页入口。
 * 统计加载失败不阻塞页面（显示 —）。
 */
import Link from "next/link";
import { useEffect, useState } from "react";
import { fetchApplications, fetchUsers, fetchWorkspaces } from "@/lib/admin";
import { Icon } from "@/components/icons";

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

	const links: Array<{ label: string; href: string }> = [
		{ label: "工作台管理", href: "/admin/workspaces" },
		{ label: "用户管理", href: "/admin/users" },
		{ label: "申请审批", href: "/admin/applications" },
		{ label: "审计", href: "/admin/audit" },
		{ label: "OpenClacky", href: "/admin/openclacky" },
	];

	return (
		<section>
			<div className="admin-page__head">
				<div>
					<h1>平台管理概览</h1>
					<p className="admin-page__desc">平台管理员仪表盘。</p>
				</div>
			</div>

			<div className="admin-stats">
				{stats.map((s) => (
					<Link key={s.label} href={s.href} className="admin-card admin-stat">
						<span aria-label={s.label} className="admin-stat__value">
							{s.value ?? "—"}
						</span>
						<span className="admin-stat__label">{s.label}</span>
					</Link>
				))}
			</div>

			<nav aria-label="平台管理入口" className="admin-card admin-links">
				{links.map((l) => (
					<Link key={l.href} href={l.href} className="admin-links__item">
						<span>{l.label}</span>
						<Icon name="arrow" size={14} />
					</Link>
				))}
			</nav>
		</section>
	);
}
