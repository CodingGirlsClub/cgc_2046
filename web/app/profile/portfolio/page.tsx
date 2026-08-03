"use client";

/**
 * Profile 作品集全量页。
 * 查看首页只预览前三条；这里用普通文档流承载任意数量作品，避免首页卡片内滚动。
 * 管理壳（侧栏/退出/未认证）由 WorkspaceShell 提供（⑤ 壳收敛）。
 */

import { Suspense, useEffect, useState } from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { useAuthed } from "@/lib/use-authed";
import {
	fetchCurrentProfile,
	fetchPortfolioItems,
	fetchProfileRoleSummary,
	pickRoleSummary,
	profileHref,
	type ProfilePortfolioItem,
} from "@/lib/profile";
import {
	ROLE_BADGE_CLASS,
	ROLE_LABEL,
	type MembershipRoleName,
} from "@/lib/graphql/workspace";
import WorkspaceShell from "@/components/workspace-shell";
import { Icon, type IconName } from "@/components/icons";

function portfolioIconName(
	icon: ProfilePortfolioItem["icon"] | undefined,
): IconName {
	if (icon === "book") return "book";
	if (icon === "guide") return "guide";
	return "document";
}

function PortfolioIcon({ icon }: { icon?: ProfilePortfolioItem["icon"] }) {
	return (
		<span
			className={`profile-portfolio-icon profile-portfolio-icon--${icon ?? "document"}`}
			aria-hidden="true"
		>
			<Icon name={portfolioIconName(icon)} size={22} />
		</span>
	);
}

function ProfilePortfolioInner() {
	// 数据 effect 的认证守卫（壳管渲染/重定向；页面管「未认证不拉数据」）
	const { authed, confirmed } = useAuthed();
	const ws = useSearchParams().get("ws");
	const [portfolio, setPortfolio] = useState<ProfilePortfolioItem[]>([]);
	const [profileName, setProfileName] = useState("我的个人资料");
	const [workspaceSlug, setWorkspaceSlug] = useState("");
	const [roles, setRoles] = useState<MembershipRoleName[]>([]);
	const [loading, setLoading] = useState(true);
	const [errorMsg, setErrorMsg] = useState<string | null>(null);

	useEffect(() => {
		if (!confirmed || !authed) return;
		let cancelled = false;
		Promise.all([
			fetchCurrentProfile(),
			fetchProfileRoleSummary(),
			fetchPortfolioItems(),
		])
			.then(([profile, summaries, portfolio]) => {
				if (cancelled) return;
				const summary = pickRoleSummary(summaries, ws);
				setProfileName(profile.displayName?.trim() || "我的个人资料");
				setWorkspaceSlug(profile.workspaceSlug || summary?.workspaceSlug || "");
				setRoles(
					profile.workspaceRoles?.length
						? profile.workspaceRoles
						: (summary?.myRoleNames ?? []),
				);
				setPortfolio(portfolio);
			})
			.catch((error: unknown) => {
				if (!cancelled)
					setErrorMsg(
						error instanceof Error ? error.message : "加载作品集失败",
					);
			})
			.finally(() => {
				if (!cancelled) setLoading(false);
			});
		return () => {
			cancelled = true;
		};
	}, [authed, confirmed, ws]);

	if (loading) return <main className="profile-loading">正在加载作品集…</main>;

	if (errorMsg)
		return (
			<main className="profile-loading">
				<strong>无法加载作品集</strong>
				<span>{errorMsg}</span>
				<Link
					href={profileHref(workspaceSlug)}
					className="profile-button profile-button--outline"
				>
					返回个人资料
				</Link>
			</main>
		);

	return (
		<WorkspaceShell slug={workspaceSlug} requireWs={false}>
			<div className="profile-main__inner">
				<div className="profile-breadcrumb" aria-label="页面路径">
					<Link href={profileHref(workspaceSlug)}>个人资料</Link>
					<span>›</span>
					<strong>全部作品集</strong>
				</div>
				<header className="profile-heading profile-portfolio-heading">
					<div>
						<h1>全部作品集</h1>
						<p>
							来自 {profileName} 的 {portfolio.length} 个作品
						</p>
					</div>
					<Link
						href={profileHref(workspaceSlug)}
						className="profile-button profile-button--outline"
					>
						返回个人资料
					</Link>
				</header>
				{portfolio.length === 0 ? (
					<div className="profile-card profile-portfolio-empty">
						还没有添加作品集。
					</div>
				) : (
					<section
						className="profile-card profile-portfolio-full-list"
						data-testid="portfolio-full-list"
					>
						<div className="profile-portfolio-full-list__meta">
							<span>共 {portfolio.length} 个作品</span>
							<div className="profile-role-chips">
								{roles.map((role) => (
									<span key={role} className={ROLE_BADGE_CLASS[role]}>
										{ROLE_LABEL[role]}
									</span>
								))}
							</div>
						</div>
						<div className="profile-portfolio-list">
							{portfolio.map((item) => (
								<Link
									key={item.id}
									href={item.url || "#"}
									className="profile-portfolio-item"
								>
									<PortfolioIcon icon={item.icon} />
									<span className="profile-portfolio-item__body">
										<strong>{item.title}</strong>
										<span>{item.description}</span>
									</span>
									<span className="profile-portfolio-link-label">
										查看 <span aria-hidden="true">→</span>
									</span>
								</Link>
							))}
						</div>
						<p className="profile-portfolio-full-list__footer">
							已显示全部 {portfolio.length} 个作品
						</p>
					</section>
				)}
				<footer className="profile-footer">
					<span>资料仅在当前 Workspace 内可见。</span>
				</footer>
			</div>
		</WorkspaceShell>
	);
}

export default function ProfilePortfolioPage() {
	return (
		<Suspense
			fallback={<main className="profile-loading">正在加载作品集…</main>}
		>
			<ProfilePortfolioInner />
		</Suspense>
	);
}
