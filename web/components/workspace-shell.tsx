"use client";

/**
 * WorkspaceShell 工作区管理壳（⑤ 壳去重）。
 *
 * 三页（members / permissions / profile）原先各抄一份 sidebar / 退出登录 /
 * 未认证壳 / Icon 集；本组件收壳，页面退化为纯内容（interface：slug +
 * children）。导航/主题变更只落一处；加一个导航项不再改 3~4 个页面。
 *
 * 职责：
 * - 未认证壳：useAuthed 守卫 + 未登录重定向 /login（页面不再各自实现）；
 * - 侧栏（members 设计为基准，2026-08-02 ⑤ Q2 决策：壳单设计）：品牌、
 *   workspace 上下文块、Workspace 设置导航（激活态由 pathname 派生）、
 *   底部 ProfileEntry + 退出登录；
 * - 工作区不可访问态（requireWs 时：slug 无法解析 → 整页「不可访问」）。
 *
 * 可选 props：
 * - `requireWs=false`：跳过 ws 解析与「不可访问」态 —— profile 页的
 *   workspace 上下文来自档案数据（content.workspaceSlug），且页面有自己
 *   的资料加载失败态，不能强制要求 ws 可解析；
 * - `className`：附加到页面根节点（页面态布局钩子，如 profile 编辑态
 *   收窄侧栏 `.ws-shell-page--editing`）。
 */

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useEffect } from "react";
import { clearAuthToken } from "@/lib/auth";
import { useAuthed } from "@/lib/use-authed";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import ProfileEntry from "@/components/profile-entry";
import ThemeToggle from "@/components/theme-toggle";
import { Icon } from "@/components/icons";

type NavSection = "overview" | "members" | "settings" | "profile" | null;

function navSection(pathname: string, slug: string): NavSection {
	if (pathname === `/w/${slug}`) return "overview";
	if (
		pathname.startsWith(`/w/${slug}/members`) ||
		pathname.startsWith(`/w/${slug}/permissions`)
	) {
		// 权限映射是「成员与角色」的子页
		return "members";
	}
	if (pathname.startsWith(`/w/${slug}/settings`)) {
		// #78：设置页（含后续 B-3 子页 requests/invitations 的父级高亮）
		return "settings";
	}
	if (pathname.startsWith("/profile")) return "profile";
	return null;
}

interface WorkspaceShellProps {
	/** 当前工作区 slug（profile 页传 content.workspaceSlug，可能为空字符串） */
	slug: string;
	/** 是否要求工作区可解析（默认 true）；false 时跳过 ws 解析与「不可访问」态 */
	requireWs?: boolean;
	/** 附加到页面根节点的类名（页面态布局钩子） */
	className?: string;
	children: React.ReactNode;
}

export default function WorkspaceShell({
	slug,
	requireWs = true,
	className,
	children,
}: WorkspaceShellProps) {
	const pathname = usePathname();
	const router = useRouter();
	const { authed, confirmed } = useAuthed();
	// requireWs=false（profile）时 slug 传 ""：hook 空 slug 不解析（见 hook 文档），
	// 侧栏上下文块只展示 slug，不出现「不可访问」态
	const { ws, loading } = useWorkspaceBySlug(requireWs ? slug : "");

	useEffect(() => {
		if (confirmed && !authed) {
			router.replace("/login");
		}
	}, [authed, confirmed, router]);

	function handleSignOut() {
		clearAuthToken();
		router.push("/login");
	}

	if (!authed) {
		return (
			<main className="ws-shell-loading">
				<span>正在确认登录状态…</span>
			</main>
		);
	}

	if (requireWs && slug && !ws && !loading) {
		return (
			<main className="ws-shell-page">
				<div className="ws-shell-empty-page">
					<h1>工作区不可访问</h1>
					<p>工作区「{slug}」不存在或你没有访问权限。</p>
					<Link href="/" className="ws-shell-primary-link">
						返回工作台
					</Link>
				</div>
			</main>
		);
	}

	const active = navSection(pathname, slug);

	return (
		<div className={`ws-shell-page ${className ?? ""}`}>
			<aside className="ws-shell-sidebar">
				<div className="ws-shell-brand">
					<span className="ws-shell-brand__mark">CGC</span>
					<span>上海 Coding Girls Club</span>
					<span className="ws-shell-brand__chevron">⌄</span>
				</div>

				{slug && (
					<div className="ws-shell-workspace">
						<span>当前 Workspace</span>
						<strong>{ws?.name ?? slug}</strong>
						<code>{ws?.slug ?? slug}</code>
					</div>
				)}

				{slug && (
					<>
						<div className="ws-shell-heading">Workspace 设置</div>
						<nav className="ws-shell-nav" aria-label="Workspace 设置">
							<Link
								href={`/w/${slug}`}
								className={`ws-shell-item ${active === "overview" ? "ws-shell-item--selected" : ""}`}
								aria-current={active === "overview" ? "page" : undefined}
							>
								<Icon name="grid" />
								<span>概览</span>
							</Link>
							<Link
								href={`/w/${slug}/members`}
								className={`ws-shell-item ${active === "members" ? "ws-shell-item--selected" : ""}`}
								aria-current={active === "members" ? "page" : undefined}
							>
								<Icon name="users" />
								<span>成员与角色</span>
							</Link>
							<Link
								href={`/w/${slug}/settings`}
								className={`ws-shell-item ${active === "settings" ? "ws-shell-item--selected" : ""}`}
								aria-current={active === "settings" ? "page" : undefined}
							>
								<Icon name="settings" />
								<span>工作区设置</span>
							</Link>
							<Link
								href={`/profile?ws=${slug}`}
								className={`ws-shell-item ${active === "profile" ? "ws-shell-item--selected" : ""}`}
								aria-current={active === "profile" ? "page" : undefined}
							>
								<Icon name="user" />
								<span>个人资料</span>
							</Link>
						</nav>
					</>
				)}

				<div className="ws-shell-footer">
					<ProfileEntry slug={slug} />
					<div className="ws-shell-footer-actions">
						<ThemeToggle />
						<button
							type="button"
							className="ws-shell-signout"
							onClick={handleSignOut}
						>
							退出登录
						</button>
					</div>
				</div>
			</aside>

			<main className="ws-shell-main">{children}</main>
		</div>
	);
}
