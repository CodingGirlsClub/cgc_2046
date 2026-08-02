import { render as rtlRender } from "@testing-library/react";
import ThemeProvider from "@/lib/theme-provider";

/**
 * 测试专用 render：自动包裹 ThemeProvider。
 *
 * 背景：WorkspaceShell footer 的 ThemeToggle（U3）依赖 useTheme，故渲染含 shell 的页面
 * 时需 ThemeProvider context。本 helper 让页面测试一处接入、无需逐个 render 调用包裹。
 * 其余 RTL 工具（screen / fireEvent / waitFor 等）仍从 @testing-library/react 直接 import。
 */
export function render(ui: React.ReactElement) {
  return rtlRender(<ThemeProvider>{ui}</ThemeProvider>);
}
