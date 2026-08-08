"use client";

import { useTheme } from "@/lib/theme-provider";
import { client } from "@/lib/apollo-client";
import { SET_UI_THEME } from "@/lib/graphql/profile";

/**
 * 主题切换按钮（U3）：toggle 本地主题（state + localStorage + class，即时生效），
 * 同时 fire-and-forget 持久化到服务端（跨设备同步）。失败静默——localStorage 已是 single-source 兜底。
 *
 * 用命令式 `client.mutate`（singleton）而非 `useMutation` hook：渲染时不依赖 Apollo context，
 * 使 WorkspaceShell 在无 ApolloProvider 的测试里也能渲染（只需 ThemeProvider）。
 *
 * 两种形态（variant）：
 * - "button"（默认）：独立小按钮，挂在 preferences 页设置行（settings-preference-row）；
 * - "menuitem"：品牌下拉菜单项（WorkspaceSwitcherMenu），点击不触发 onNavigate（不收菜单，
 *   切主题不是导航，用户可连续切换；菜单由点外部/路由变化收起逻辑处理）。
 *
 * 按钮文案 = 点击后切换到的目标主题（深色态显示「浅色」入口，反之亦然）。
 */
export default function ThemeToggle({
	variant = "button",
}: {
	variant?: "button" | "menuitem";
}) {
	const { theme, setTheme } = useTheme();

	function handleToggle() {
		const next = theme === "dark" ? "light" : "dark";
		setTheme(next);
		// fire-and-forget：失败静默，localStorage 已是 single-source 兜底
		client
			.mutate({
				mutation: SET_UI_THEME,
				variables: { input: { uiThemePreference: next } },
			})
			.catch(() => {});
	}

	const isDark = theme === "dark";

	if (variant === "menuitem") {
		return (
			<button
				type="button"
				className="ws-shell-brand-menu__item"
				role="menuitem"
				onClick={handleToggle}
				aria-label={`切换为${isDark ? "浅色" : "深色"}主题`}
			>
				<span className="ws-shell-brand-menu__name">
					{isDark ? "浅色主题" : "深色主题"}
				</span>
			</button>
		);
	}

	return (
		<button
			type="button"
			className="ws-shell-theme"
			onClick={handleToggle}
			aria-label={`切换为${isDark ? "浅色" : "深色"}主题`}
			title={`当前主题：${isDark ? "深色" : "浅色"}`}
		>
			<span aria-hidden>{isDark ? "☀" : "☾"}</span>
			<span>{isDark ? "浅色" : "深色"}</span>
		</button>
	);
}
