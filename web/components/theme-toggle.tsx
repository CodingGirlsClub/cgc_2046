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
 * 放在 WorkspaceShell footer，挨着「退出登录」（个人偏好，归 account actions 区）。
 * 按钮文案 = 点击后切换到的目标主题（深色态显示「浅色」入口，反之亦然）。
 */
export default function ThemeToggle() {
  const { theme, setTheme } = useTheme();

  function handleToggle() {
    const next = theme === "dark" ? "light" : "dark";
    setTheme(next);
    // fire-and-forget：失败静默，localStorage 已是 single-source 兜底
    client
      .mutate({ mutation: SET_UI_THEME, variables: { input: { uiThemePreference: next } } })
      .catch(() => {});
  }

  const isDark = theme === "dark";

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
