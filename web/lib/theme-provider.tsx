"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
} from "react";

export type ThemeMode = "dark" | "light";

const STORAGE_KEY = "cgc_theme";

interface ThemeContextValue {
  theme: ThemeMode;
  setTheme: (t: ThemeMode) => void;
  toggleTheme: () => void;
}

const ThemeContext = createContext<ThemeContextValue | null>(null);

/** 开发期调试参数：?theme=light|dark（U3 决策保留为 dev 工具，正式版改用户偏好）。 */
function readUrlTheme(): ThemeMode | null {
  if (typeof window === "undefined") return null;
  const params = new URLSearchParams(window.location.search);
  const t = params.get("theme");
  return t === "light" || t === "dark" ? t : null;
}

function readStoredTheme(): ThemeMode | null {
  if (typeof window === "undefined") return null;
  try {
    const t = localStorage.getItem(STORAGE_KEY);
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
 * 优先级：?theme= URL 参数（开发调试，U3）> localStorage（静态骨架占位）> dark（默认）。
 * 正式版（依赖 #68/#69 用户偏好持久化）改为服务端用户偏好驱动，本 Provider 保留
 * 作为本地回退 + 开发调试入口。
 */
export default function ThemeProvider({ children }: { children: React.ReactNode }) {
  // SSR 与客户端 hydration 首帧固定 dark：localStorage/URL 偏好仅在客户端挂载后
  // 异步应用，保证服务端输出与客户端首帧一致，杜绝 hydration mismatch。
  const [theme, setThemeState] = useState<ThemeMode>("dark");

  useEffect(() => {
    // 客户端挂载后应用偏好（微任务提交，避免 react-hooks/set-state-in-effect 同步 setState）
    queueMicrotask(() => {
      const t = readUrlTheme() ?? readStoredTheme() ?? "dark";
      setThemeState(t);
    });
  }, []);

  useEffect(() => {
    applyThemeClass(theme);
  }, [theme]);

  const setTheme = useCallback((t: ThemeMode) => {
    setThemeState(t);
    try {
      localStorage.setItem(STORAGE_KEY, t);
    } catch {
      // ignore private-mode write errors
    }
  }, []);

  const toggleTheme = useCallback(() => {
    setThemeState((prev) => {
      const next = prev === "light" ? "dark" : "light";
      try {
        localStorage.setItem(STORAGE_KEY, next);
      } catch {
        // ignore private-mode write errors
      }
      return next;
    });
  }, []);

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
