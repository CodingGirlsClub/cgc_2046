import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { screen, fireEvent, cleanup } from "@testing-library/react";
import { render } from "@/test-utils";
import ThemeToggle from "@/components/theme-toggle";

// mock Apollo singleton：仅校验 fire-and-forget 持久化被调用，不打真实网络。
// localStorage 写入是 ThemeProvider.setTheme 的职责（已由 theme-provider.test 覆盖），
// 本测试聚焦 ThemeToggle 自身逻辑：toggle 切换 class + 触发 setUiTheme。
vi.mock("@/lib/apollo-client", () => ({
  client: {
    mutate: vi.fn().mockResolvedValue({
      data: { setUiTheme: { id: "u1", uiThemePreference: "light" } },
    }),
  },
}));

import { client } from "@/lib/apollo-client";

describe("ThemeToggle（U3 主题持久化）", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    document.documentElement.classList.remove("light");
  });
  afterEach(() => cleanup());

  it("点击 dark→light：挂 .light class 并 fire setUiTheme(light)", () => {
    render(<ThemeToggle />);

    // 初始 dark → 按钮入口指向「浅色」
    const btn = screen.getByRole("button", { name: /切换为浅色主题/ });
    fireEvent.click(btn);

    // 本地主题已切（ThemeProvider 把 .light class 挂到 <html>）
    expect(document.documentElement.classList.contains("light")).toBe(true);
    // fire-and-forget 持久化到服务端
    expect(client.mutate).toHaveBeenCalledWith({
      mutation: expect.anything(),
      variables: { input: { uiThemePreference: "light" } },
    });
  });

  it("再次点击切回 dark 并以 dark 持久化", () => {
    render(<ThemeToggle />);
    const btn = screen.getByRole("button");

    fireEvent.click(btn); // dark → light
    fireEvent.click(btn); // light → dark

    expect(document.documentElement.classList.contains("light")).toBe(false);
    expect(client.mutate).toHaveBeenLastCalledWith({
      mutation: expect.anything(),
      variables: { input: { uiThemePreference: "dark" } },
    });
  });
});
