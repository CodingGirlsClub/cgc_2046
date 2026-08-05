"use client";

/**
 * 工作区列表侧边栏（共享，issue #83）。
 *
 * 首页（/）与加入页（/join）共用。侧栏项统一 <Link href="/w/:slug">，
 * 点击即导航（URL 即资源，可收藏 / 刷新保持），不再用纯前端 state 切换。
 *
 * 与工作区内页的 ws-shell-sidebar 语义不同：本组件是「我在哪些工作区之间
 * 切换」（横向），ws-shell-sidebar 是「我在当前工作区的哪些功能之间切换」
 * （纵向），故不合并。
 *
 * 差异点仅由 props 控制：
 * - selectedSlug：高亮当前所在工作区（首页传当前路径 slug，Join 不传）
 * - activeAction="discover"：高亮「发现 / 申请」虚线项（Join 用）
 */

import Link from "next/link";
import ProfileEntry from "@/components/profile-entry";
import ThemeToggle from "@/components/theme-toggle";
import {
	getWorkspaceRoles,
	getWorkspaceStatus,
	StatusTag,
	WorkspaceAvatar,
} from "@/components/workspace-ui";
import type { WorkspaceListItem } from "@/lib/workspaces";

function WorkspaceListNavItem({
	ws,
	selected,
}: {
	ws: WorkspaceListItem;
	selected: boolean;
}) {
	const status = getWorkspaceStatus(ws);
	const roles = getWorkspaceRoles(ws);

	return (
		<Link
			href={`/w/${ws.slug}`}
			className={`workspace-nav-item ${selected ? "workspace-nav-item--selected" : ""}`}
			aria-current={selected ? "page" : undefined}
		>
			<WorkspaceAvatar ws={ws} />
			<span className="workspace-nav-item__body">
				<strong>{ws.name}</strong>
				{status === "active" ? (
					<span className="workspace-nav-item__subline">
						{roles.length ? roles.join(" / ") : "已加入"}
					</span>
				) : (
					<StatusTag status={status} />
				)}
			</span>
			{ws.unreadCount ? (
				<span className="workspace-unread">{ws.unreadCount}</span>
			) : null}
			{status !== "active" && (
				<span className="workspace-nav-item__chevron" aria-hidden="true">
					›
				</span>
			)}
		</Link>
	);
}

export default function WorkspaceListSidebar({
	workspaces,
	selectedSlug = null,
	activeAction = null,
	onSignOut,
}: {
	workspaces: WorkspaceListItem[];
	selectedSlug?: string | null;
	activeAction?: "discover" | null;
	onSignOut: () => void;
}) {
	const activeCount = workspaces.filter(
		(ws) => getWorkspaceStatus(ws) === "active",
	).length;
	const pendingCount = workspaces.length - activeCount;

	return (
		<aside className="workspace-sidebar" aria-label="工作区导航">
			<Link href="/" className="workspace-sidebar__brand">
				CGC 2046
			</Link>
			<div className="workspace-sidebar__heading">
				<h1>我的工作区</h1>
				<p>
					你加入了 {activeCount} 个工作区
					{pendingCount > 0 ? ` · ${pendingCount} 个待处理` : ""}
				</p>
			</div>

			<nav className="workspace-sidebar__nav" aria-label="我的工作区列表">
				{workspaces.map((ws) => (
					<WorkspaceListNavItem
						key={ws.id}
						ws={ws}
						selected={ws.slug === selectedSlug}
					/>
				))}
			</nav>

			<div className="workspace-sidebar__footer">
				<Link
					href="/join"
					className={`workspace-dashed-action ${activeAction === "discover" ? "workspace-dashed-action--active" : ""}`}
					aria-current={activeAction === "discover" ? "page" : undefined}
				>
					<span aria-hidden="true">＋</span>
					发现 / 申请加入新工作区
				</Link>
				<div className="workspace-sidebar__account">
					<ProfileEntry />
					<ThemeToggle />
					<button
						type="button"
						className="workspace-signout"
						onClick={onSignOut}
					>
						退出登录
					</button>
				</div>
			</div>
		</aside>
	);
}