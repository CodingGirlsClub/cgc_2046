"use client";

import { useTranslations } from "next-intl";
import { useTheme } from "@/lib/theme-provider";
import { client } from "@/lib/apollo-client";
import { SET_WORKSPACE_THEME } from "@/lib/graphql/profile";

/**
 * 主题切换按钮（U3，ADR-0004 per-workspace）：toggle 本地主题（state +
 * localStorage + class，即时生效），同时 fire-and-forget 持久化到服务端
 * （setWorkspaceTheme，跨设备同步）。失败静默——localStorage 已是 single-source 兜底。
 *
 * `workspaceId` 必传（per-workspace 主题持久化目标）；缺失时仅本地切换不持久化。
 *
 * 两种形态（variant）：
 * - "button"（默认）：独立小按钮，挂在 preferences 页设置行（settings-preference-row）；
 * - "menuitem"：品牌下拉菜单项（WorkspaceSwitcherMenu），点击不触发 onNavigate。
 */
export default function ThemeToggle({
	variant = "button",
	workspaceId,
}: {
	variant?: "button" | "menuitem";
	workspaceId?: string;
}) {
	const { theme, setTheme } = useTheme();
	const t = useTranslations("themeToggle");

	function handleToggle() {
		const next = theme === "dark" ? "light" : "dark";
		setTheme(next);
		// fire-and-forget：失败静默，localStorage 已是 single-source 兜底
		if (workspaceId) {
			client
				.mutate({
					mutation: SET_WORKSPACE_THEME,
					variables: {
						workspaceId,
						input: { uiThemePreference: next },
					},
				})
				.catch(() => {});
		}
	}

	const isDark = theme === "dark";

	if (variant === "menuitem") {
		return (
			<button
				type="button"
				className="ws-shell-brand-menu__item"
				role="menuitem"
				onClick={handleToggle}
				aria-label={isDark ? t("toggleLight") : t("toggleDark")}
			>
				<span className="ws-shell-brand-menu__name">
					{isDark ? t("lightTheme") : t("darkTheme")}
				</span>
			</button>
		);
	}

	return (
		<button
			type="button"
			className="ws-shell-theme"
			onClick={handleToggle}
			aria-label={isDark ? t("toggleLight") : t("toggleDark")}
			title={isDark ? t("currentDark") : t("currentLight")}
		>
			<span aria-hidden>{isDark ? "☀" : "☾"}</span>
			<span>{isDark ? t("light") : t("dark")}</span>
		</button>
	);
}
