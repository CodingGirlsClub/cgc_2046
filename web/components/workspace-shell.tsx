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
 *   workspace 上下文块、工作区设置导航（激活态由 pathname 派生）、
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
import { useEffect, useRef, useState } from "react";
import { clearSession } from "@/lib/auth";
import { useAuthed } from "@/lib/use-authed";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import { fetchMyWorkspaces, type WorkspaceListItem } from "@/lib/workspaces";
import { fetchCurrentProfile, type CurrentProfile } from "@/lib/profile";
import { WorkspaceAvatar } from "@/components/workspace-ui";
import WorkspaceSwitcherMenu from "@/components/workspace-switcher-menu";
import { Icon } from "@/components/icons";

type NavSection =
	| "overview"
	| "workflows"
	| "members"
	| "settings-join-policy"
	| "settings-requests"
	| "settings-invitations"
	| "settings-account-profile"
	| "settings-account-preferences"
	| null;

function navSection(pathname: string, slug: string): NavSection {
	if (pathname === `/w/${slug}`) return "overview";
	if (pathname.startsWith(`/w/${slug}/workflows`)) return "workflows";
	if (
		pathname.startsWith(`/w/${slug}/settings/members`) ||
		pathname.startsWith(`/w/${slug}/settings/permissions`)
	) {
		// 权限映射是「成员与角色」的子页
		return "members";
	}
	if (pathname === `/w/${slug}/settings`) return "settings-join-policy";
	if (pathname.startsWith(`/w/${slug}/settings/requests`))
		return "settings-requests";
	if (pathname.startsWith(`/w/${slug}/settings/invitations`))
		return "settings-invitations";
	if (pathname.startsWith(`/w/${slug}/settings/account/profile`))
		return "settings-account-profile";
	if (pathname.startsWith(`/w/${slug}/settings/account/preferences`))
		return "settings-account-preferences";
	return null;
}

interface WorkspaceShellProps {
	/** 当前工作区 slug（profile 页传 content.workspaceSlug，可能为空字符串） */
	slug: string;
	/** 是否要求工作区可解析（默认 true）；false 时跳过 ws 解析与「不可访问」态 */
	requireWs?: boolean;
	/**
	 * 显式工作区名（profile 页 requireWs=false 时用：档案数据自带 workspaceName，
	 * 无需走 useWorkspaceBySlug）。优先于 ws?.name 与 slug 显示。
	 */
	workspaceName?: string;
	/** 附加到页面根节点的类名（页面态布局钩子） */
	className?: string;
	children: React.ReactNode;
}

export default function WorkspaceShell({
	slug,
	requireWs = true,
	workspaceName,
	className,
	children,
}: WorkspaceShellProps) {
	const pathname = usePathname();
	const router = useRouter();
	const { authed, confirmed } = useAuthed();
	// requireWs=false（profile）时 slug 传 ""：hook 空 slug 不解析（见 hook 文档），
	// 侧栏上下文块只展示 slug，不出现「不可访问」态
	const { ws, loading } = useWorkspaceBySlug(requireWs ? slug : "");

	// 工作区切换 dropdown（issue #83：ws-shell-brand ⌄ 可切换已加入的工作区）
	const [workspaces, setWorkspaces] = useState<WorkspaceListItem[]>([]);
	const [profile, setProfile] = useState<CurrentProfile | null>(null);
	const [brandOpen, setBrandOpen] = useState(false);
	const brandRef = useRef<HTMLDivElement>(null);

	useEffect(() => {
		if (!authed) return;
		let cancelled = false;
		// profile 走 fetchCurrentProfile（Apollo 缓存命中零网络，见 lib/profile 注释）
		Promise.all([fetchMyWorkspaces(), fetchCurrentProfile()])
			.then(([list, p]) => {
				if (cancelled) return;
				setWorkspaces(list);
				setProfile(p);
			})
			.catch(() => {});
		return () => {
			cancelled = true;
		};
	}, [authed]);

	// 点外部收起 dropdown
	useEffect(() => {
		if (!brandOpen) return;
		function onPointerDown(e: PointerEvent) {
			if (brandRef.current && !brandRef.current.contains(e.target as Node)) {
				setBrandOpen(false);
			}
		}
		document.addEventListener("pointerdown", onPointerDown);
		return () => document.removeEventListener("pointerdown", onPointerDown);
	}, [brandOpen]);

	// 路由变化时收起（点 dropdown 项后导航走）
	// 微任务提交，避免 react-hooks/set-state-in-effect 同步 setState
	useEffect(() => {
		queueMicrotask(() => setBrandOpen(false));
	}, [pathname]);

	useEffect(() => {
		if (confirmed && !authed) {
			router.replace("/login");
		}
	}, [authed, confirmed, router]);

	async function handleSignOut() {
		await clearSession();
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
	// settings 模式：/w/[slug]/settings 前缀下侧边栏切换为 Linear 式分组导航
	// （Personal / Workspace），非 settings 路由保持工作区导航
	const isSettings = pathname.startsWith(`/w/${slug}/settings`);

	// #79 IA：管理项按能力过滤（普通成员仅见 概览/个人资料）；
	// 页面级门控不变（后端 policy 权威拦截，导航过滤仅为 UX）
	const abilities = ws?.myAbilities ?? [];
	const canSeeMembers = abilities.includes("list_members");
	const canSeeJoinPolicy = abilities.includes("update_join_policy");
	const canSeeManagement = canSeeMembers; // B-3 占位跟随管理可见性

	return (
		<div className={`ws-shell-page ${className ?? ""}`}>
			<aside className="ws-shell-sidebar">
				<div className="ws-shell-brand-wrap" ref={brandRef}>
					<Link href="/" className="ws-shell-brand__mark" aria-label="返回工作台">
						CGC
					</Link>
					<button
						type="button"
						className="ws-shell-brand"
						aria-expanded={brandOpen}
						aria-haspopup="menu"
						aria-label={`${workspaceName ?? ws?.name ?? (slug || "工作区")} Workspace Menu`}
						onClick={() => setBrandOpen((v) => !v)}
					>
						{ws && <WorkspaceAvatar ws={ws} small />}
						<span className="ws-shell-brand__name">
							{workspaceName ?? ws?.name ?? (slug || "工作区")}
						</span>
						<Icon name="chevron" size={16} className="ws-shell-brand__chevron" />
					</button>
					{brandOpen && (
						<WorkspaceSwitcherMenu
							workspaces={workspaces}
							currentSlug={slug}
							profile={profile}
							onNavigate={() => setBrandOpen(false)}
							onSignOut={handleSignOut}
						/>
					)}
				</div>

				{slug && isSettings && (
					<>
						<Link
							href={`/w/${slug}`}
							className="ws-shell-item ws-shell-item--back"
						>
							<Icon name="arrow-left" />
							<span>Back to app</span>
						</Link>
						<div className="ws-shell-heading">Personal</div>
						<nav className="ws-shell-nav" aria-label="Personal">
							<Link
								href={`/w/${slug}/settings/account/preferences`}
								className={`ws-shell-item ${active === "settings-account-preferences" ? "ws-shell-item--selected" : ""}`}
								aria-current={
									active === "settings-account-preferences" ? "page" : undefined
								}
							>
								<Icon name="settings" />
								<span>Preferences</span>
							</Link>
							<Link
								href={`/w/${slug}/settings/account/profile`}
								className={`ws-shell-item ${active === "settings-account-profile" ? "ws-shell-item--selected" : ""}`}
								aria-current={
									active === "settings-account-profile" ? "page" : undefined
								}
							>
								<Icon name="user" />
								<span>个人资料</span>
							</Link>
						</nav>
						<div className="ws-shell-heading">Workspace</div>
						<nav className="ws-shell-nav" aria-label="Workspace">
							{canSeeMembers && (
								<Link
									href={`/w/${slug}/settings/members`}
									className={`ws-shell-item ${active === "members" ? "ws-shell-item--selected" : ""}`}
									aria-current={active === "members" ? "page" : undefined}
								>
									<Icon name="users" />
									<span>成员与角色</span>
								</Link>
							)}
							{canSeeJoinPolicy && (
								<Link
									href={`/w/${slug}/settings`}
									className={`ws-shell-item ${active === "settings-join-policy" ? "ws-shell-item--selected" : ""}`}
									aria-current={
										active === "settings-join-policy" ? "page" : undefined
									}
								>
									<Icon name="settings" />
									<span>加入策略</span>
								</Link>
							)}
							{canSeeManagement && (
								<>
									<Link
										href={`/w/${slug}/settings/requests`}
										className={`ws-shell-item ${active === "settings-requests" ? "ws-shell-item--selected" : ""}`}
										aria-current={
											active === "settings-requests" ? "page" : undefined
										}
									>
										<Icon name="shield" />
										<span>加入审批</span>
									</Link>
									<Link
										href={`/w/${slug}/settings/invitations`}
										className={`ws-shell-item ${active === "settings-invitations" ? "ws-shell-item--selected" : ""}`}
										aria-current={
											active === "settings-invitations" ? "page" : undefined
										}
									>
										<Icon name="invite" />
										<span>邀请管理</span>
									</Link>
								</>
							)}
						</nav>
					</>
				)}

				{slug && !isSettings && (
					<>
						<div className="ws-shell-heading">工作区导航</div>
						<nav className="ws-shell-nav" aria-label="工作区导航">
							<Link
								href={`/w/${slug}`}
								className={`ws-shell-item ${active === "overview" ? "ws-shell-item--selected" : ""}`}
								aria-current={active === "overview" ? "page" : undefined}
							>
								<Icon name="grid" />
								<span>概览</span>
							</Link>
							<Link
								href={`/w/${slug}/workflows`}
								className={`ws-shell-item ${active === "workflows" ? "ws-shell-item--selected" : ""}`}
								aria-current={active === "workflows" ? "page" : undefined}
							>
								<Icon name="book" />
								<span>教研产出</span>
							</Link>
						</nav>
					</>
				)}
			</aside>

			<main className="ws-shell-main">{children}</main>
		</div>
	);
}
