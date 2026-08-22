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
 * - 侧栏（members 设计为基准，2026-08-02 ⑤ Q2 决策：壳单设计）：CGC 品牌行
 *   （火焰标 + 双语名，链接回首页）、workspace 上下文切换块、工作区设置导航
 *   （激活态由 pathname 派生）、底部 ProfileEntry + 退出登录；
 * - 工作区不可访问态（requireWs 时：slug 无法解析 → 整页「不可访问」）。
 *
 * 可选 props：
 * - `requireWs=false`：跳过 ws 解析与「不可访问」态 —— profile 页的
 *   workspace 上下文来自档案数据（content.workspaceSlug），且页面有自己
 *   的资料加载失败态，不能强制要求 ws 可解析；
 * - `requireAbility`：管理类设置页的页面级守卫（2026-08-22 决策：这些页
 *   对普通成员「能看见没有任何意义」）——ws 解析后 myAbilities 缺失该能力
 *   时主区渲染「需要管理权限」空态替代 children；只读审计访客
 *   （readOnlyVisitor PlatformAdmin）豁免，保留审计视图。数据权威拦截
 *   仍在后端 Ash policy，此守卫只是 UX 层；
 * - `className`：附加到页面根节点（页面态布局钩子，如 profile 编辑态
 *   收窄侧栏 `.ws-shell-page--editing`）。
 */

// usePathname/useRouter 一律走 @/i18n/navigation（2026-08-22 诊断修复）：
// 裸 next/navigation 的 usePathname 在 EN 下返回 /en/... 前缀路径，
// isSettings / navSection 的 startsWith 判定恒 false（设置侧栏错渲染成
// 工作区导航、激活态失效）；i18n 版返回去前缀内部路径，且 router.push
// 目的地自动带当前 locale（登出跳 /login 不再丢 EN）。
import { Link, usePathname, useRouter } from "@/i18n/navigation";
import { useEffect, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { clearSession } from "@/lib/auth";
import { useAuthed } from "@/lib/use-authed";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import { fetchMyWorkspaces, type WorkspaceListItem } from "@/lib/workspaces";
import { writeLastWorkspace } from "@/lib/use-last-workspace";
import { fetchCurrentProfile, type CurrentProfile } from "@/lib/profile";
import { WorkspaceAvatar } from "@/components/workspace-ui";
import WorkspaceSwitcherMenu from "@/components/workspace-switcher-menu";
import { BrandLockup } from "@/components/brand";
import { Icon } from "@/components/icons";
import {
	SETTINGS_NAV,
	canSee,
	type NavSection,
} from "@/components/workspace-nav";

function navSection(pathname: string, slug: string): NavSection {
	if (pathname === `/w/${slug}`) return "overview";
	// plan 020 U1：/w/[slug]/agents 工作面一级入口（须在 settings 前缀判定之前）
	if (pathname.startsWith(`/w/${slug}/agents`)) return "agents";
	if (pathname.startsWith(`/w/${slug}/workflows`)) return "workflows";
	if (
		pathname.startsWith(`/w/${slug}/events`) ||
		pathname.startsWith(`/w/${slug}/courses`)
	) {
		return pathname.startsWith(`/w/${slug}/courses`) ? "courses" : "events";
	}
	if (
		pathname.startsWith(`/w/${slug}/settings/members`)
	) {
		return "members";
	}
	if (pathname.startsWith(`/w/${slug}/settings/permissions`)) {
		return "settings-permissions";
	}
	if (pathname === `/w/${slug}/settings/join-policy`) return "settings-join-policy";
	if (pathname.startsWith(`/w/${slug}/settings/requests`))
		return "settings-requests";
	if (pathname.startsWith(`/w/${slug}/settings/invitations`))
		return "settings-invitations";
	if (pathname.startsWith(`/w/${slug}/settings/account/profile`))
		return "settings-account-profile";
	if (pathname.startsWith(`/w/${slug}/settings/account/preferences`))
		return "settings-account-preferences";
	if (
		pathname.startsWith(
			`/w/${slug}/settings/integrations/agents`,
		)
	)
		return "settings-integrations-agents";
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
	/** 管理页守卫：ws.myAbilities 需含此能力，否则主区渲染「需要管理权限」空态 */
	requireAbility?: string;
	/** 附加到页面根节点的类名（页面态布局钩子） */
	className?: string;
	children: React.ReactNode;
}

export default function WorkspaceShell({
	slug,
	requireWs = true,
	workspaceName,
	requireAbility,
	className,
	children,
}: WorkspaceShellProps) {
	const pathname = usePathname();
	const router = useRouter();
	const t = useTranslations("workspace.shell");
	const navT = useTranslations("workspaceNav");
	const { authed, confirmed } = useAuthed();
	// requireWs=false（profile）时 slug 传 ""：hook 空 slug 不解析（见 hook 文档），
	// 侧栏上下文块只展示 slug，不出现「不可访问」态
	const {
		ws,
		readOnlyVisitor,
		loading,
		error: wsError,
		retry,
	} = useWorkspaceBySlug(requireWs ? slug : "");

	// 工作区切换 dropdown（issue #83：ws-shell-brand ⌄ 可切换已加入的工作区）
	const [workspaces, setWorkspaces] = useState<WorkspaceListItem[]>([]);
	const [profile, setProfile] = useState<CurrentProfile | null>(null);
	const [brandOpen, setBrandOpen] = useState(false);
	// 登出失败上报（#018）：mutation 失败不导航，原菜单内展示错误 + 可重试
	const [signOutError, setSignOutError] = useState<string | null>(null);
	const [signingOut, setSigningOut] = useState(false);
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

	// IA 收敛：进入某工作区时记忆 slug（首页 / 分发用「最近记忆 > 第一个 active」）。
	// requireWs=false（profile 页）时 ws 为 undefined，不写——看个人资料不算「进入某工作区」。
	useEffect(() => {
		if (ws?.slug) writeLastWorkspace(ws.slug);
	}, [ws?.slug]);

	useEffect(() => {
		if (confirmed && !authed) {
			router.replace("/login");
		}
	}, [authed, confirmed, router]);

	async function handleSignOut() {
		setSigningOut(true);
		setSignOutError(null);
		const result = await clearSession();
		setSigningOut(false);
		if (!result.ok) {
			setSignOutError(t("signOutFailed"));
			return; // 不导航 —— 让用户看到错误并重试
		}
		router.push("/login");
	}

	if (!authed) {
		return (
			<main className="ws-shell-loading">
				<span>{t("confirming")}</span>
			</main>
		);
	}

	if (requireWs && slug && !ws && !loading) {
		// #017 Bug B：网络/服务器错误 ≠「无权限」——给重试出口，不误报「工作区不可访问」
		if (wsError) {
			return (
				<main className="ws-shell-page">
					<div className="ws-shell-empty-page">
						<h1>{t("loadFailed")}</h1>
						<p>{t("loadError", { message: wsError.message })}</p>
						<button
							type="button"
							className="join-button join-button--primary"
							onClick={retry}
						>
							{t("retry")}
						</button>
						<Link href="/" className="ws-shell-primary-link">
							{t("backToHome")}
						</Link>
					</div>
				</main>
			);
		}
		return (
			<main className="ws-shell-page">
				<div className="ws-shell-empty-page">
					<h1>{t("notAccessible")}</h1>
					<p>{t("notAccessibleDesc", { slug })}</p>
					<Link href="/" className="ws-shell-primary-link">
						{t("backToHome")}
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
	// 页面级门控不变（后端 policy 权威拦截，导航过滤仅为 UX）。
	// plan 016：门控单源化 —— 侧栏/tab 条/下拉菜单统一消费 SETTINGS_NAV 注册表，
	// 审批/邀请跟随 manage_members（不再跟随 list_members）。
	const abilities = ws?.myAbilities ?? [];
	const workspaceNav = SETTINGS_NAV.filter(
		(d) => d.group === "workspace" && canSee(d, abilities),
	);

	// 管理页守卫：ws 解析完成后才判定（加载中让页面自己的骨架渲染，不闪空态）；
	// 只读审计访客豁免（审计视图靠页面内 readOnlyVisitor 只读降级）
	const abilityBlocked =
		!!requireAbility &&
		!!ws &&
		!readOnlyVisitor &&
		!abilities.includes(requireAbility);

	return (
		<div className={`ws-shell-page ${className ?? ""}`}>
			<aside className="ws-shell-sidebar">
				<Link href="/" className="ws-shell-cgc-brand">
					<BrandLockup />
				</Link>
				<div className="ws-shell-brand-wrap" ref={brandRef}>
					<button
						type="button"
						className="ws-shell-brand"
						aria-expanded={brandOpen}
						aria-haspopup="menu"
						aria-label={`${workspaceName ?? ws?.name ?? (slug || t("workspaceFallback"))} Workspace Menu`}
						onClick={() => setBrandOpen((v) => !v)}
					>
						{ws && <WorkspaceAvatar ws={ws} small />}
						<span className="ws-shell-brand__name">
							{workspaceName ?? ws?.name ?? (slug || t("workspaceFallback"))}
						</span>
						<Icon name="chevron" size={16} className="ws-shell-brand__chevron" />
					</button>
					{brandOpen && (
						<WorkspaceSwitcherMenu
							workspaces={workspaces}
							currentSlug={slug}
							currentWorkspaceId={ws?.id}
							abilities={abilities}
							profile={profile}
							onNavigate={() => setBrandOpen(false)}
							onSignOut={handleSignOut}
							signOutError={signOutError}
							signingOut={signingOut}
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
							<span>{t("backToApp")}</span>
						</Link>
						<div className="ws-shell-heading">{t("headingPersonal")}</div>
						<nav className="ws-shell-nav" aria-label={t("headingPersonal")}>
							<Link
								href={`/w/${slug}/settings/account/preferences`}
								className={`ws-shell-item ${active === "settings-account-preferences" ? "ws-shell-item--selected" : ""}`}
								aria-current={
									active === "settings-account-preferences" ? "page" : undefined
								}
							>
								<Icon name="settings" />
								<span>{t("headingPersonal")}</span>
							</Link>
							<Link
								href={`/w/${slug}/settings/account/profile`}
								className={`ws-shell-item ${active === "settings-account-profile" ? "ws-shell-item--selected" : ""}`}
								aria-current={
									active === "settings-account-profile" ? "page" : undefined
								}
							>
								<Icon name="user" />
								<span>{t("profileLink")}</span>
							</Link>
						</nav>
						<div className="ws-shell-heading">{t("headingIntegrations")}</div>
						<nav className="ws-shell-nav" aria-label={t("headingIntegrations")}>
							<Link
								href={`/w/${slug}/settings/integrations/agents`}
								className={`ws-shell-item ${active === "settings-integrations-agents" ? "ws-shell-item--selected" : ""}`}
								aria-current={
									active === "settings-integrations-agents" ? "page" : undefined
								}
							>
								<Icon name="activity" />
								<span>{t("integrationsLink")}</span>
							</Link>
						</nav>
						{/* Workspace 组恒有 Agents/活动/课程无门控工作面入口，组不会为空 */}
						<div className="ws-shell-heading">{t("headingWorkspace")}</div>
						<nav className="ws-shell-nav" aria-label={t("headingWorkspace")}>
							{workspaceNav.map((dest) => (
								<Link
									key={dest.key}
									href={dest.href(slug)}
									className={`ws-shell-item ${active === dest.active ? "ws-shell-item--selected" : ""}`}
									aria-current={
										active === dest.active ? "page" : undefined
									}
								>
									<Icon name={dest.icon!} />
									<span>{navT(dest.labelKey)}</span>
								</Link>
							))}
						</nav>
					</>
				)}

				{slug && !isSettings && (
					<>
						<div className="ws-shell-heading">{t("navGroup")}</div>
						<nav className="ws-shell-nav" aria-label={t("navGroup")}>
							<Link
								href={`/w/${slug}`}
								className={`ws-shell-item ${active === "overview" ? "ws-shell-item--selected" : ""}`}
								aria-current={active === "overview" ? "page" : undefined}
							>
								<Icon name="grid" />
								<span>{t("navOverview")}</span>
							</Link>
							{/* plan 020 U1：Agents 工作面一级入口（workspace 侧边栏） */}
							<Link
								href={`/w/${slug}/agents`}
								className={`ws-shell-item ${active === "agents" ? "ws-shell-item--selected" : ""}`}
								aria-current={active === "agents" ? "page" : undefined}
							>
								<Icon name="activity" />
								<span>{t("navAgents")}</span>
							</Link>
							<Link
								href={`/w/${slug}/workflows`}
								className={`ws-shell-item ${active === "workflows" ? "ws-shell-item--selected" : ""}`}
								aria-current={active === "workflows" ? "page" : undefined}
							>
								<Icon name="book" />
								<span>{t("navWorkflows")}</span>
							</Link>
							<Link
								href={`/w/${slug}/events`}
								className={`ws-shell-item ${active === "events" ? "ws-shell-item--selected" : ""}`}
								aria-current={active === "events" ? "page" : undefined}
							>
								<Icon name="book" />
								<span>{t("navEvents")}</span>
							</Link>
							<Link
								href={`/w/${slug}/courses`}
								className={`ws-shell-item ${active === "courses" ? "ws-shell-item--selected" : ""}`}
								aria-current={active === "courses" ? "page" : undefined}
							>
								<Icon name="guide" />
								<span>{t("navCourses")}</span>
							</Link>
						</nav>
					</>
				)}
			</aside>

			<main className="ws-shell-main">
				{readOnlyVisitor && (
					<div className="ws-shell-readonly-banner" role="status">
						{t("readonlyBanner")}
					</div>
				)}
				{abilityBlocked ? (
					<div className="ws-shell-empty-page" data-testid="shell-no-permission">
						<h1>{t("noPermissionTitle")}</h1>
						<p>{t("noPermissionDesc")}</p>
						<Link href={`/w/${slug}`} className="ws-shell-primary-link">
							{t("backToOverview")}
						</Link>
					</div>
				) : (
					children
				)}
			</main>
		</div>
	);
}
