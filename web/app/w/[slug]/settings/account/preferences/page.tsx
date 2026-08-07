"use client";

/**
 * 工作区设置 → Preferences（对齐 Linear Personal > Preferences）。
 *
 * 主题偏好（U3）从侧栏 footer 迁入此处：Linear 的 Preferences 有
 * "Interface theme" 设置项，我们以同样的设置行呈现 ThemeToggle。
 */

import Link from "next/link";
import { useParams } from "next/navigation";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import WorkspaceShell from "@/components/workspace-shell";
import ThemeToggle from "@/components/theme-toggle";

export default function WorkspaceAccountPreferencesPage() {
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const { ws, loading } = useWorkspaceBySlug(slug);

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label="页面路径">
					<Link href="/">工作台</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<Link href={`/w/${slug}/settings`}>设置</Link>
					<span>›</span>
					<strong>Preferences</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>Preferences</h1>
						<p>管理你的界面偏好</p>
					</div>
				</header>

				{loading || !ws ? (
					<div
						className="settings-loading"
						data-testid="settings-loading"
						aria-label="加载中"
					>
						<div className="settings-skeleton settings-skeleton--title" />
						<div className="settings-skeleton" />
					</div>
				) : (
					<section className="settings-policy-card" aria-label="Preferences">
						<div className="settings-policy-card__header">
							<div>
								<strong>界面主题</strong>
								<p>选择深色或浅色主题，跨设备同步</p>
							</div>
						</div>
						<div className="settings-preference-row">
							<ThemeToggle />
						</div>
					</section>
				)}
			</div>
		</WorkspaceShell>
	);
}
