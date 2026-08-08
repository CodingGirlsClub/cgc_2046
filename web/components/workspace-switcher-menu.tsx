"use client";

/**
 * 工作区切换下拉菜单（复刻 Linear 两级结构）。
 *
 * 一级：Settings / 邀请管理 / Switch workspace ▸ / 退出登录；
 * 二级（Switch workspace 展开，右侧飞出）：账号邮箱 → 工作区列表（头像+名称+✓+序号）
 * → Account 分组 → 发现加入 / 主题切换。
 *
 * 由 WorkspaceShell 品牌按钮触发；壳只管 brandOpen 开关与外部点击收起。
 * 数据经 props 传入（fetchMyWorkspaces + fetchCurrentProfile 在壳内并行拉取）。
 */

import { useState, useRef, useLayoutEffect } from "react";
import Link from "next/link";
import { WorkspaceAvatar } from "@/components/workspace-ui";
import ThemeToggle from "@/components/theme-toggle";
import { Icon } from "@/components/icons";
import { canSeeByKey } from "@/components/workspace-nav";
import type { CurrentProfile } from "@/lib/profile";
import type { WorkspaceListItem } from "@/lib/workspaces";

interface WorkspaceSwitcherMenuProps {
	/** 已 fetchMyWorkspaces 的工作区列表 */
	workspaces: WorkspaceListItem[];
	/** 当前工作区 slug（高亮 + ✓） */
	currentSlug: string;
	/** 当前工作区 id（per-workspace 主题持久化目标） */
	currentWorkspaceId?: string;
	/** 当前工作区能力列表（plan 016：邀请管理链接按 manage_members 门控） */
	abilities: string[];
	/** 当前用户（邮箱展示；null 时显示占位） */
	profile: CurrentProfile | null;
	/** 点任意项后收起菜单 */
	onNavigate: () => void;
	/** 退出登录 */
	onSignOut: () => void;
	/** 登出失败错误文案（#018：非 null 时在退出登录项下方展示） */
	signOutError?: string | null;
	/** 登出进行中（禁用退出登录项防重复触发） */
	signingOut?: boolean;
}

export default function WorkspaceSwitcherMenu({
	workspaces,
	currentSlug,
	currentWorkspaceId,
	abilities,
	profile,
	onNavigate,
	onSignOut,
	signOutError = null,
	signingOut = false,
}: WorkspaceSwitcherMenuProps) {
	// 二级（Switch workspace）展开态；由菜单内 state 管理（Linear 式子菜单）
	const [submenuOpen, setSubmenuOpen] = useState(false);
	// 一级菜单容器 ref：二级用 fixed 定位（避开一级 overflow 裁剪）
	const menuRef = useRef<HTMLDivElement>(null);
	const [subPos, setSubPos] = useState<{ top: number; left: number } | null>(
		null,
	);

	useLayoutEffect(() => {
		if (!submenuOpen || !menuRef.current) return;
		const update = () => {
			const r = menuRef.current?.getBoundingClientRect();
			if (r) setSubPos({ top: r.top, left: r.right + 4 });
		};
		update();
		// 展开后滚动/窗口尺寸变化时重算，避免 fixed 定位过期
		// scroll 用 capture 捕获任意可滚动容器的滚动
		window.addEventListener("scroll", update, true);
		window.addEventListener("resize", update);
		return () => {
			window.removeEventListener("scroll", update, true);
			window.removeEventListener("resize", update);
		};
	}, [submenuOpen]);

	return (
		<div
			className="ws-shell-brand-menu"
			role="menu"
			ref={menuRef}
			onMouseLeave={() => setSubmenuOpen(false)}
		>
			<Link
				href={`/w/${currentSlug}/settings/account/preferences`}
				className="ws-shell-brand-menu__item"
				role="menuitem"
				onClick={onNavigate}
			>
				<span className="ws-shell-brand-menu__name">Settings</span>
			</Link>
			{canSeeByKey("invitations", abilities) && (
				<Link
					href={`/w/${currentSlug}/settings/invitations`}
					className="ws-shell-brand-menu__item"
					role="menuitem"
					onClick={onNavigate}
				>
					<span className="ws-shell-brand-menu__name">邀请管理</span>
				</Link>
			)}

			<div className="ws-shell-brand-menu__divider" />

			<button
				type="button"
				className={`ws-shell-brand-menu__item ws-shell-brand-menu__submenu-trigger ${submenuOpen ? "ws-shell-brand-menu__item--current" : ""}`}
				role="menuitem"
				aria-haspopup="menu"
				aria-expanded={submenuOpen}
				onMouseEnter={() => setSubmenuOpen(true)}
				onClick={() => setSubmenuOpen(true)}
			>
				<span className="ws-shell-brand-menu__name">Switch workspace</span>
				<Icon name="chevron" size={14} className="ws-shell-brand-menu__arrow" />
			</button>

			<div className="ws-shell-brand-menu__divider" />

			<button
				type="button"
				className="ws-shell-brand-menu__item ws-shell-brand-menu__item--action"
				role="menuitem"
				onClick={onSignOut}
				disabled={signingOut}
			>
				<span className="ws-shell-brand-menu__name">
					{signingOut ? "退出中…" : "退出登录"}
				</span>
			</button>

			{signOutError && (
				<div className="members-error" role="alert">
					{signOutError}
				</div>
			)}

			{submenuOpen && subPos && (
				<div
					className="ws-shell-brand-menu ws-shell-brand-menu--sub"
					role="menu"
					style={{ top: subPos.top, left: subPos.left }}
				>
					<div className="ws-shell-brand-menu__account">
						{profile?.email || "…"}
					</div>

					{workspaces.map((w, i) => (
						<Link
							key={w.id}
							href={`/w/${w.slug}`}
							className={`ws-shell-brand-menu__item ${w.slug === currentSlug ? "ws-shell-brand-menu__item--current" : ""}`}
							role="menuitem"
							onClick={onNavigate}
						>
							<WorkspaceAvatar ws={w} small />
							<span className="ws-shell-brand-menu__name">{w.name}</span>
							<span className="ws-shell-brand-menu__index" aria-hidden="true">
								{i + 1}
							</span>
							{w.slug === currentSlug && (
								<span
									className="ws-shell-brand-menu__check"
									aria-hidden="true"
								>
									✓
								</span>
							)}
						</Link>
					))}

					<div className="ws-shell-brand-menu__divider" />

					<div className="ws-shell-brand-menu__group">Account</div>
					<Link
						href="/join"
						className="ws-shell-brand-menu__item"
						role="menuitem"
						onClick={onNavigate}
					>
						<span className="ws-shell-brand-menu__name">发现 / 加入工作区</span>
					</Link>
					<ThemeToggle variant="menuitem" workspaceId={currentWorkspaceId} />
				</div>
			)}
		</div>
	);
}
