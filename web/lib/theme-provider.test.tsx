import { describe, it, expect, beforeEach } from "vitest";
import { act, renderHook } from "@testing-library/react";
import ThemeProvider, { useTheme } from "./theme-provider";

/**
 * ThemeProvider hydration 一致性测试（#70 P3 主题按钮文案回归修复）。
 *
 * 核心修复：SSR 与客户端 hydration 首帧固定 dark（useState 初始值不再读 localStorage），
 * 偏好仅在客户端挂载后异步（queueMicrotask）应用 → 首帧文案一致，杜绝 hydration mismatch。
 */

// jsdom 环境不提供 localStorage，用 in-memory 实现替代
const store = new Map<string, string>();
const localStorageMock: Storage = {
  get length() {
    return store.size;
  },
  clear: () => store.clear(),
  getItem: (key: string) => store.get(key) ?? null,
  key: (index: number) => Array.from(store.keys())[index] ?? null,
  removeItem: (key: string) => void store.delete(key),
  setItem: (key: string, value: string) => void store.set(key, String(value)),
};
Object.defineProperty(window, "localStorage", {
  value: localStorageMock,
  configurable: true,
});

const wrapper = ({ children }: { children: React.ReactNode }) => (
  <ThemeProvider>{children}</ThemeProvider>
);

/** flush queueMicrotask（挂载后偏好应用 effect） */
async function flushMicrotasks() {
  await act(async () => {
    await Promise.resolve();
  });
}

describe("ThemeProvider（hydration 一致性）", () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it("默认 dark", () => {
    const { result } = renderHook(() => useTheme(), { wrapper });
    expect(result.current.theme).toBe("dark");
  });

  it("localStorage 有 light 时，首帧仍为 dark（SSR/客户端首帧一致）", async () => {
    localStorage.setItem("cgc_theme", "light");
    const { result } = renderHook(() => useTheme(), { wrapper });
    // 首帧（hydration 对账时）必须与 SSR 输出一致
    expect(result.current.theme).toBe("dark");
    // 收尾：等挂载后偏好应用 effect 完成，避免 act 警告
    await flushMicrotasks();
  });

  it("挂载后应用 localStorage 偏好 → light", async () => {
    localStorage.setItem("cgc_theme", "light");
    const { result } = renderHook(() => useTheme(), { wrapper });
    await flushMicrotasks();
    expect(result.current.theme).toBe("light");
  });

  it("无偏好时挂载后保持 dark", async () => {
    const { result } = renderHook(() => useTheme(), { wrapper });
    await flushMicrotasks();
    expect(result.current.theme).toBe("dark");
  });

  it("toggleTheme 切换主题并写入 localStorage", async () => {
    const { result } = renderHook(() => useTheme(), { wrapper });
    await flushMicrotasks();
    expect(result.current.theme).toBe("dark");

    act(() => result.current.toggleTheme());
    expect(result.current.theme).toBe("light");
    expect(localStorage.getItem("cgc_theme")).toBe("light");

    act(() => result.current.toggleTheme());
    expect(result.current.theme).toBe("dark");
    expect(localStorage.getItem("cgc_theme")).toBe("dark");
  });

  it("setTheme 设置主题并写入 localStorage", async () => {
    const { result } = renderHook(() => useTheme(), { wrapper });
    await flushMicrotasks();
    act(() => result.current.setTheme("light"));
    expect(result.current.theme).toBe("light");
    expect(localStorage.getItem("cgc_theme")).toBe("light");
  });
});
