import { describe, it, expect, vi, beforeEach } from "vitest";
import { act, renderHook } from "@testing-library/react";
import ThemeProvider, { useTheme } from "./theme-provider";

/**
 * ThemeProvider hydration 一致性 + per-workspace 隔离测试（ADR-0004）。
 *
 * 核心修复：SSR 与客户端 hydration 首帧固定 dark（useState 初始值不再读 localStorage），
 * 偏好仅在客户端挂载后异步（queueMicrotask）应用 → 首帧文案一致，杜绝 hydration mismatch。
 * ADR-0004：主题按 workspace 隔离——localStorage key 为 `cgc_theme_<slug>`，
 * pathname 变化时重新读取对应 key。
 */

// mock next/navigation 的 usePathname（provider 依赖它解析 workspace slug）
const pathnameMock = vi.fn(() => "/w/cgc-camp/settings/account/preferences");
vi.mock("next/navigation", () => ({
  usePathname: () => pathnameMock(),
}));

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

describe("ThemeProvider（hydration 一致性，ADR-0004 per-workspace）", () => {
  beforeEach(() => {
    localStorage.clear();
    pathnameMock.mockReturnValue("/w/cgc-camp/settings/account/preferences");
  });

  it("默认 dark", () => {
    const { result } = renderHook(() => useTheme(), { wrapper });
    expect(result.current.theme).toBe("dark");
  });

  it("localStorage 有全局 cgc_theme 时，首帧仍为 dark（SSR/客户端首帧一致）", async () => {
    localStorage.setItem("cgc_theme", "light");
    const { result } = renderHook(() => useTheme(), { wrapper });
    // 首帧（hydration 对账时）必须与 SSR 输出一致
    expect(result.current.theme).toBe("dark");
    // 收尾：等挂载后偏好应用 effect 完成，避免 act 警告
    await flushMicrotasks();
  });

  it("挂载后应用 workspace 对应 key 的偏好（cgc_theme_cgc-camp）→ light", async () => {
    localStorage.setItem("cgc_theme_cgc-camp", "light");
    const { result } = renderHook(() => useTheme(), { wrapper });
    await flushMicrotasks();
    expect(result.current.theme).toBe("light");
  });

  it("workspace key 与全局 key 隔离：全局 light 不影响 workspace（无 ws key 时默认 dark）", async () => {
    localStorage.setItem("cgc_theme", "light");
    const { result } = renderHook(() => useTheme(), { wrapper });
    await flushMicrotasks();
    // 有 workspace 上下文（/w/cgc-camp/...）→ 读 cgc_theme_cgc-camp，不存在 → dark
    expect(result.current.theme).toBe("dark");
  });

  it("无 workspace 上下文页面（登录页）→ 回退全局 cgc_theme", async () => {
    pathnameMock.mockReturnValue("/login");
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

  it("toggleTheme 切换主题并写入 workspace key", async () => {
    const { result } = renderHook(() => useTheme(), { wrapper });
    await flushMicrotasks();
    expect(result.current.theme).toBe("dark");

    act(() => result.current.toggleTheme());
    expect(result.current.theme).toBe("light");
    expect(localStorage.getItem("cgc_theme_cgc-camp")).toBe("light");
    // 全局 key 不受影响
    expect(localStorage.getItem("cgc_theme")).toBeNull();

    act(() => result.current.toggleTheme());
    expect(result.current.theme).toBe("dark");
    expect(localStorage.getItem("cgc_theme_cgc-camp")).toBe("dark");
  });

  it("setTheme 设置主题并写入 workspace key", async () => {
    const { result } = renderHook(() => useTheme(), { wrapper });
    await flushMicrotasks();
    act(() => result.current.setTheme("light"));
    expect(result.current.theme).toBe("light");
    expect(localStorage.getItem("cgc_theme_cgc-camp")).toBe("light");
  });
});
