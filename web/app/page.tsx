"use client";

/**
 * 已登录首页（IA 收敛：路由分发器）。
 *
 * 登录后落点统一为 /（use-auth-submit 的 push("/")），本页按 workspace 列表分发：
 * - 有可进入（active）工作区 → 重定向到默认 workspace（最近记忆 > 第一个 active）；
 * - 无任何工作区 → 渲染极简全屏空态，引导去 /join 发现/申请。
 *
 * 不再有「工作台 Hub」中间层：工作区切换 / 发现加入 / 账号 / 主题全部收敛到
 * WorkspaceShell 的品牌下拉菜单；/?view=grid onboarding 卡片网格一并删除。
 */

import Link from "next/link";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { useAuthed } from "@/lib/use-authed";
import { fetchMyWorkspaces, type WorkspaceListItem } from "@/lib/workspaces";
import { getWorkspaceStatus } from "@/components/workspace-ui";
import { readLastWorkspace } from "@/lib/use-last-workspace";

function FullPageSpinner({ text }: { text: string }) {
	return (
		<main className="ws-shell-loading">
			<span>{text}</span>
		</main>
	);
}

function FullPageRetry({ onRetry }: { onRetry: () => void }) {
	return (
		<main className="ws-shell-loading">
			<div className="join-card" role="alert">
				<h1>工作区加载失败</h1>
				<p>暂时无法获取你的工作区列表，请稍后重试。</p>
				<div>
					<button
						type="button"
						className="join-button join-button--primary"
						onClick={onRetry}
					>
						重试
					</button>
				</div>
			</div>
		</main>
	);
}

function EmptyHubState() {
	return (
		<main className="ws-shell-loading">
			<div className="join-card">
				<h1>你还没有加入任何工作区</h1>
				<p>加入一个工作区，开始与团队协作。</p>
				<div>
					<Link href="/join" className="join-button join-button--primary">
						发现 / 申请加入工作区
					</Link>
				</div>
			</div>
		</main>
	);
}

export default function HomePage() {
	const router = useRouter();
	const { authed, confirmed } = useAuthed();
	const [workspaces, setWorkspaces] = useState<WorkspaceListItem[] | null>(null);
	const [loadError, setLoadError] = useState(false);

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
			});
		return () => {
			cancelled = true;
		};
	}, [authed, confirmed, router]);

	function retryLoad() {
		setWorkspaces(null);
		setLoadError(false);
		fetchMyWorkspaces()
			.then((list) => setWorkspaces(list))
			.catch(() => setLoadError(true));
	}

	// 默认 workspace：最近记忆 > 第一个 active > 无（空态）。记忆失效自然回退。
	// 渲染期只做纯计算（readLastWorkspace 是 localStorage 只读，无副作用）。
	const last = readLastWorkspace();
	const target =
		workspaces === null
			? null
			: (workspaces.find(
					(w) => w.slug === last && getWorkspaceStatus(w) === "active",
				) ?? workspaces.find((w) => getWorkspaceStatus(w) === "active"));

	// 分发必须在 effect 中执行：渲染期间调用 router.replace 会触发
	// "Cannot update a component (Router) while rendering"（setState-in-render）。
	// target 引用随 workspaces 只 set 一次而稳定，effect 只跑一次。
	useEffect(() => {
		if (target) router.replace(`/w/${target.slug}`);
	}, [target, router]);

	if (!confirmed || !authed) return <FullPageSpinner text="正在确认登录状态…" />;
	if (loadError) return <FullPageRetry onRetry={retryLoad} />;
	if (workspaces === null) return <FullPageSpinner text="加载工作区…" />;
	// replace 不进历史：浏览器后退不卡在分发器；重定向期间渲染 spinner 防闪
	if (target) return <FullPageSpinner text="进入工作区…" />;

	return <EmptyHubState />;
}
