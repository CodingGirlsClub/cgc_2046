"use client";

/**
 * 工作区切换下拉菜单（对齐 Linear 实测：账号邮箱 → 工作区列表 → 操作项）。
 *
 * 由 WorkspaceShell 品牌按钮触发；壳只管 brandOpen 开关与外部点击收起，
 * 本组件只渲染菜单内容。数据经 props 传入（fetchMyWorkspaces +
 * fetchCurrentProfile 在壳内并行拉取，profile 走 Apollo 缓存零网络）。
 *
 * 结构（自上而下）：
 * 1. 账号邮箱行（只读展示）；
 * 2. 工作区列表（WorkspaceAvatar small + 名称 + 当前项 ✓）；
 * 3. 分隔线；
 * 4. 操作项：个人资料（settings/account/profile）/ 发现加入工作区（/join）/ 退出登录。
 */

import Link from "next/link";
import { WorkspaceAvatar } from "@/components/workspace-ui";
import { profileHref, type CurrentProfile } from "@/lib/profile";
import type { WorkspaceListItem } from "@/lib/workspaces";

interface WorkspaceSwitcherMenuProps {
	/** 已 fetchMyWorkspaces 的工作区列表 */
	workspaces: WorkspaceListItem[];
	/** 当前工作区 slug（高亮 + ✓） */
	currentSlug: string;
	/** 当前用户（邮箱展示；null 时显示占位） */
	profile: CurrentProfile | null;
	/** 点任意项后收起菜单 */
	onNavigate: () => void;
	/** 退出登录 */
	onSignOut: () => void;
}

export default function WorkspaceSwitcherMenu({
	workspaces,
	currentSlug,
	profile,
	onNavigate,
	onSignOut,
}: WorkspaceSwitcherMenuProps) {
	return (
		<div className="ws-shell-brand-menu" role="menu">
			<div className="ws-shell-brand-menu__account">
				{profile?.email || "…"}
			</div>

			{workspaces.map((w) => (
				<Link
					key={w.id}
					href={`/w/${w.slug}`}
					className={`ws-shell-brand-menu__item ${w.slug === currentSlug ? "ws-shell-brand-menu__item--current" : ""}`}
					role="menuitem"
					onClick={onNavigate}
				>
					<WorkspaceAvatar ws={w} small />
					<span className="ws-shell-brand-menu__name">{w.name}</span>
					{w.slug === currentSlug && (
						<span className="ws-shell-brand-menu__check" aria-hidden="true">
							✓
						</span>
					)}
				</Link>
			))}

			<div className="ws-shell-brand-menu__divider" />

			<Link
				href={`/w/${currentSlug}/settings`}
				className="ws-shell-brand-menu__item"
				role="menuitem"
				onClick={onNavigate}
			>
				<span className="ws-shell-brand-menu__name">Settings</span>
			</Link>
			<Link
				href={profileHref(currentSlug)}
				className="ws-shell-brand-menu__item"
				role="menuitem"
				onClick={onNavigate}
			>
				<span className="ws-shell-brand-menu__name">个人资料</span>
			</Link>
			<Link
				href="/join"
				className="ws-shell-brand-menu__item"
				role="menuitem"
				onClick={onNavigate}
			>
				<span className="ws-shell-brand-menu__name">发现 / 加入工作区</span>
			</Link>
			<button
				type="button"
				className="ws-shell-brand-menu__item ws-shell-brand-menu__item--action"
				role="menuitem"
				onClick={onSignOut}
			>
				<span className="ws-shell-brand-menu__name">退出登录</span>
			</button>
		</div>
	);
}
