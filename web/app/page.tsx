"use client";

/**
 * #63 / #83 已登录首页（工作台 Hub）。
 *
 * 正式形态是「共享侧栏 + Hub 占位」：点侧栏工作区跳 /w/:slug（URL 即资源），
 * 首页本身是枢纽起点，不再内联工作区详情（详情归 /w/[slug] 概览页）。
 * 首次登录卡片网格保留为 /?view=grid，便于 onboarding 与验收使用。
 * Hub 占位文字后续由设计补全（issue #83）。
 */

import Link from "next/link";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { clearSession } from "@/lib/auth";
import { useAuthed } from "@/lib/use-authed";
import { fetchMyWorkspaces, type WorkspaceListItem } from "@/lib/workspaces";
import WorkspaceListSidebar from "@/components/workspace-list-sidebar";
import { Icon } from "@/components/icons";
import {
	getWorkspaceRoles,
	getWorkspaceStatus,
	POLICY_META,
	RoleChips,
	STATUS_META,
	StatusTag,
	WorkspaceAvatar,
} from "@/components/workspace-ui";

function HubPlaceholder() {
	return (
		<main className="workspace-detail workspace-detail--empty">
			<header className="workspace-detail__header">
				<h1>工作台</h1>
			</header>
			<div className="workspace-empty-detail">
				<h2>从左侧选择一个工作区开始</h2>
				<p>或发现公开工作区，使用邀请凭据加入新的协作空间。</p>
				<Link
					href="/join"
					className="workspace-button workspace-button--outline"
				>
					发现 / 申请加入新工作区
				</Link>
			</div>
		</main>
	);
}

function GridWorkspaceCard({ ws }: { ws: WorkspaceListItem }) {
	const status = getWorkspaceStatus(ws);
	const roles = getWorkspaceRoles(ws);
	const policy = POLICY_META[ws.joinPolicy];

	return (
		<article className={`workspace-grid-card workspace-grid-card--${status}`}>
			<StatusTag status={status} lowercase />
			<div className="workspace-grid-card__identity">
				<WorkspaceAvatar ws={ws} large />
				<div>
					<h2>{ws.name}</h2>
					<p className="workspace-slug">{ws.slug}</p>
				</div>
			</div>
			<div className="workspace-grid-card__divider" />
			<div className="workspace-grid-card__policy">
				<strong
					className={`workspace-policy workspace-policy--${ws.joinPolicy}`}
				>
					{policy.label}
				</strong>
				<span>
					{status === "active" ? policy.hint : STATUS_META[status].label}
				</span>
			</div>
			{status === "active" ? (
				<>
					<RoleChips roles={roles} />
					<div className="workspace-grid-card__meta">
						<span>
							<Icon name="members" />
							{typeof ws.memberCount === "number"
								? `${ws.memberCount} 位成员`
								: "成员数待同步"}
						</span>
						{ws.unreadCount ? (
							<span>
								<Icon name="activity" />
								{ws.unreadCount} 条未读
							</span>
						) : null}
					</div>
					<Link
						href={`/w/${ws.slug}`}
						className="workspace-button workspace-button--primary"
					>
						进入工作台
					</Link>
				</>
			) : (
				<p className="workspace-grid-card__hint">{policy.hint}</p>
			)}
		</article>
	);
}

function WorkspaceGrid({
	workspaces,
	onSignOut,
}: {
	workspaces: WorkspaceListItem[];
	onSignOut: () => void;
}) {
	return (
		<div className="workspace-grid-page">
			<header className="workspace-grid-page__header">
				<strong>CGC 2046</strong>
				<div className="workspace-grid-page__account">
					<button
						type="button"
						className="workspace-signout"
						onClick={onSignOut}
					>
						退出登录
					</button>
				</div>
			</header>
			<main className="workspace-grid-page__content">
				<h1>选择你的工作区</h1>
				<p>一个账号可以加入多个工作区，随时切换你的协作现场。</p>
				<div className="workspace-grid">
					{workspaces.map((ws) => (
						<GridWorkspaceCard key={ws.id} ws={ws} />
					))}
					<Link
						href="/join"
						className="workspace-grid-card workspace-grid-card--discover"
					>
						<span className="workspace-discover-icon">♧</span>
						<strong>发现 / 申请加入新工作区</strong>
						<span>浏览公开社区，或使用邀请凭据加入</span>
					</Link>
				</div>
			</main>
		</div>
	);
}

function LoadingState() {
	return (
		<main className="workspace-loading" aria-label="正在加载工作区">
			<span className="workspace-loading__brand">CGC 2046</span>
			<span className="workspace-loading__text">加载工作区…</span>
		</main>
	);
}

function WorkspaceLoadError({ onRetry }: { onRetry: () => void }) {
	return (
		<main className="workspace-page">
			<div className="workspace-error" role="alert">
				<h1>工作区加载失败</h1>
				<p>暂时无法获取你的工作区列表，请稍后重试。</p>
				<button
					type="button"
					className="workspace-button workspace-button--outline"
					onClick={onRetry}
				>
					重试
				</button>
			</div>
		</main>
	);
}

export default function HomePage() {
	const router = useRouter();
	const { authed, confirmed } = useAuthed();
	const [workspaces, setWorkspaces] = useState<WorkspaceListItem[]>([]);
	const [loading, setLoading] = useState(true);
	const [loadError, setLoadError] = useState(false);
	const [gridView, setGridView] = useState(false);

	useEffect(() => {
		if (typeof window === "undefined") return;
		queueMicrotask(() => {
			setGridView(
				new URLSearchParams(window.location.search).get("view") === "grid",
			);
		});
	}, []);

	useEffect(() => {
		if (!confirmed) return;
		if (!authed) {
			router.replace("/login");
			return;
		}

		let cancelled = false;
		fetchMyWorkspaces()
			.then((list) => {
				if (!cancelled) setWorkspaces(list);
			})
			.catch(() => {
				// 区分「加载失败」与「真实空数据」：失败保留错误态并允许重试
				if (!cancelled) setLoadError(true);
			})
			.finally(() => {
				if (!cancelled) setLoading(false);
			});

		return () => {
			cancelled = true;
		};
	}, [authed, confirmed, router]);

	function retryLoad() {
		setWorkspaces([]);
		setLoading(true);
		setLoadError(false);
		fetchMyWorkspaces()
			.then((list) => setWorkspaces(list))
			.catch(() => setLoadError(true))
			.finally(() => setLoading(false));
	}

	async function handleSignOut() {
		await clearSession();
		router.push("/login");
	}

	if (!confirmed || !authed) return <LoadingState />;
	if (loading) return <LoadingState />;
	if (loadError) return <WorkspaceLoadError onRetry={retryLoad} />;
	if (gridView)
		return <WorkspaceGrid workspaces={workspaces} onSignOut={handleSignOut} />;

	return (
		<div className="workspace-page">
			<WorkspaceListSidebar
				workspaces={workspaces}
				onSignOut={handleSignOut}
			/>
			<HubPlaceholder />
		</div>
	);
}