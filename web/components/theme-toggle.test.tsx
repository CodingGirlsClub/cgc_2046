import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { screen, fireEvent, cleanup } from "@testing-library/react";
import { render } from "@/test-utils";
import ThemeToggle from "@/components/theme-toggle";

// mock Apollo singleton：仅校验 fire-and-forget 持久化被调用，不打真实网络。
// localStorage 写入是 ThemeProvider.setTheme 的职责（已由 theme-provider.test 覆盖），
// 本测试聚焦 ThemeToggle 自身逻辑：toggle 切换 class + 触发 setWorkspaceTheme。
vi.mock("@/lib/apollo-client", () => ({
  client: {
    mutate: vi.fn().mockResolvedValue({
      data: { setWorkspaceTheme: { id: "u1", uiThemePreference: "light" } },
    }),
  },
}));

import { client } from "@/lib/apollo-client";

describe("ThemeToggle（U3 主题持久化，ADR-0004 per-workspace）", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    document.documentElement.classList.remove("light");
  });
  afterEach(() => cleanup());

  it("点击 dark→light：挂 .light class 并 fire setWorkspaceTheme(light, workspaceId)", () => {
    render(<ThemeToggle workspaceId="ws_1" />);

    // 初始 dark → 按钮入口指向「浅色」
    const btn = screen.getByRole("button", { name: /切换为浅色主题/ });
    fireEvent.click(btn);

    // 本地主题已切（ThemeProvider 把 .light class 挂到 <html>）
    expect(document.documentElement.classList.contains("light")).toBe(true);
    // fire-and-forget 持久化到服务端（per-workspace）
    expect(client.mutate).toHaveBeenCalledWith({
      mutation: expect.anything(),
      variables: {
        workspaceId: "ws_1",
        input: { uiThemePreference: "light" },
      },
    });
  });

  it("再次点击切回 dark 并以 dark 持久化", () => {
    render(<ThemeToggle workspaceId="ws_1" />);
    const btn = screen.getByRole("button");

    fireEvent.click(btn); // dark → light
    fireEvent.click(btn); // light → dark

    expect(document.documentElement.classList.contains("light")).toBe(false);
    expect(client.mutate).toHaveBeenLastCalledWith({
      mutation: expect.anything(),
      variables: {
        workspaceId: "ws_1",
        input: { uiThemePreference: "dark" },
      },
    });
  });

  it("无 workspaceId：仅本地切换，不持久化到服务端", () => {
    render(<ThemeToggle />);

    const btn = screen.getByRole("button", { name: /切换为浅色主题/ });
    fireEvent.click(btn);

    expect(document.documentElement.classList.contains("light")).toBe(true);
    expect(client.mutate).not.toHaveBeenCalled();
  });

  it("menuitem 形态：渲染菜单项并切换主题（带 workspaceId）", () => {
    render(<ThemeToggle variant="menuitem" workspaceId="ws_1" />);

    const item = screen.getByRole("menuitem", { name: /切换为浅色主题/ });
    expect(item.className).toContain("ws-shell-brand-menu__item");
    fireEvent.click(item);

    expect(document.documentElement.classList.contains("light")).toBe(true);
    expect(client.mutate).toHaveBeenCalledWith({
      mutation: expect.anything(),
      variables: {
        workspaceId: "ws_1",
        input: { uiThemePreference: "light" },
      },
    });
  });
});
