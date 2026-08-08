"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
} from "react";
import { usePathname } from "next/navigation";

export type ThemeMode = "dark" | "light";

/** 全局主题 key（无 workspace 上下文时用，如登录页/首页） */
const STORAGE_KEY_BASE = "cgc_theme";

interface ThemeContextValue {
  theme: ThemeMode;
  setTheme: (t: ThemeMode) => void;
  toggleTheme: () => void;
}

const ThemeContext = createContext<ThemeContextValue | null>(null);

/** 从 pathname 提取当前 workspace slug（/w/[slug]/... → slug）；无则 null */
function workspaceSlugFromPath(pathname: string): string | null {
  const match = /^\/w\/([^/]+)/.exec(pathname);
  return match?.[1] ?? null;
}

/** per-workspace localStorage key（ADR-0004：主题按 workspace 隔离） */
function storageKey(slug: string | null): string {
  return slug ? `${STORAGE_KEY_BASE}_${slug}` : STORAGE_KEY_BASE;
}

/** 开发期调试参数：?theme=light|dark（U3 决策保留为 dev 工具，正式版改用户偏好）。 */
function readUrlTheme(): ThemeMode | null {
  if (typeof window === "undefined") return null;
  const params = new URLSearchParams(window.location.search);
  const t = params.get("theme");
  return t === "light" || t === "dark" ? t : null;
}

function readStoredTheme(key: string): ThemeMode | null {
  if (typeof window === "undefined") return null;
  try {
    const t = localStorage.getItem(key);
    return t === "light" || t === "dark" ? t : null;
  } catch {
    return null;
  }
}

function applyThemeClass(theme: ThemeMode) {
  if (typeof document === "undefined") return;
  document.documentElement.classList.toggle("light", theme === "light");
}

/**
 * 全局主题 Provider（Dark/Light 双主题，Linear 设计系统）。
 *
 * 优先级：?theme= URL 参数（开发调试，U3）> localStorage（per-workspace）> dark（默认）。
 *
 * ADR-0004：主题按 workspace 隔离——localStorage key 为 `cgc_theme_<slug>`
 * （无 workspace 上下文时回退 `cgc_theme`）；pathname 变化（进入/切换 workspace）
 * 时重新读取对应 key 应用。SSR 与客户端 hydration 首帧固定 dark：
 * localStorage/URL 偏好仅在客户端挂载后异步应用，杜绝 hydration mismatch。
 * 服务端持久化由 ThemeToggle 按 workspace 调 setWorkspaceTheme。
 */
export default function ThemeProvider({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  // 当前 workspace slug（无 ws 上下文页面为 null）
  const slug = workspaceSlugFromPath(pathname);

  const [theme, setThemeState] = useState<ThemeMode>("dark");

  // workspace 上下文变化时应用对应 key 的主题（客户端挂载后与切换时）
  useEffect(() => {
    queueMicrotask(() => {
      const t = readUrlTheme() ?? readStoredTheme(storageKey(slug)) ?? "dark";
      setThemeState(t);
    });
  }, [slug]);

  useEffect(() => {
    applyThemeClass(theme);
  }, [theme]);

  const setTheme = useCallback(
    (t: ThemeMode) => {
      setThemeState(t);
      try {
        localStorage.setItem(storageKey(slug), t);
      } catch {
        // ignore private-mode write errors
      }
    },
    [slug],
  );

  const toggleTheme = useCallback(() => {
    setThemeState((prev) => {
      const next = prev === "light" ? "dark" : "light";
      try {
        localStorage.setItem(storageKey(slug), next);
      } catch {
        // ignore private-mode write errors
      }
      return next;
    });
  }, [slug]);

  const value = useMemo(
    () => ({ theme, setTheme, toggleTheme }),
    [theme, setTheme, toggleTheme],
  );

  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>;
}

export function useTheme(): ThemeContextValue {
  const ctx = useContext(ThemeContext);
  if (!ctx) throw new Error("useTheme must be used within <ThemeProvider>");
  return ctx;
}
