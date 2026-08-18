"use client";

/**
 * 工作区设置 → Preferences（对齐 Linear Personal > Preferences）。
 *
 * 主题偏好（U3）从侧栏 footer 迁入此处：Linear 的 Preferences 有
 * "Interface theme" 设置项，我们以同样的设置行呈现 ThemeToggle。
 */

import Link from "next/link";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import WorkspaceShell from "@/components/workspace-shell";
import ThemeToggle from "@/components/theme-toggle";

export default function WorkspaceAccountPreferencesPage() {
	const t = useTranslations("workspacePreferences");
	const tCommon = useTranslations("common");
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const { ws, loading } = useWorkspaceBySlug(slug);

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label={tCommon("breadcrumbAria")}>
					<Link href="/">{t("breadcrumbHome")}</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<Link href={`/w/${slug}/settings/join-policy`}>{t("breadcrumbSettings")}</Link>
					<span>›</span>
					<strong>{t("breadcrumbTitle")}</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>{t("title")}</h1>
						<p>{t("subtitle")}</p>
					</div>
				</header>

				{loading || !ws ? (
					<div
						className="settings-loading"
						data-testid="settings-loading"
						aria-label={t("loadingAria")}
					>
						<div className="settings-skeleton settings-skeleton--title" />
						<div className="settings-skeleton" />
					</div>
				) : (
					<section className="settings-policy-card" aria-label="Preferences">
						<div className="settings-policy-card__header">
							<div>
								<strong>{t("themeLabel")}</strong>
								<p>{t("themeDesc")}</p>
							</div>
						</div>
						<div className="settings-preference-row">
							<ThemeToggle workspaceId={ws.id} />
						</div>
					</section>
				)}
			</div>
		</WorkspaceShell>
	);
}
