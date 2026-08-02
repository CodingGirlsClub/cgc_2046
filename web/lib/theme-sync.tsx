"use client";

import { useEffect, useRef } from "react";
import { useQuery } from "@apollo/client/react";
import { useAuthed } from "@/lib/use-authed";
import { useTheme } from "@/lib/theme-provider";
import { ME_PROFILE } from "@/lib/graphql/profile";

/**
 * 主题服务端同步（U3）：登录后拉取服务端 uiThemePreference 并应用，实现跨设备同步。
 *
 * 优先级：?theme= URL 参数（dev 调试，跳过服务端同步）> 服务端偏好 > localStorage > dark。
 * 仅在本会话首次拿到服务端值时应用一次（ref 守卫，避免导航重挂时覆盖会话内 toggle）；
 * 应用时 setTheme 同步写 localStorage（保证下次首帧一致）。
 *
 * 无 UI——纯副作用组件，挂在 ApolloProvider 内（layout 经 ApolloWrapper）。
 */
export default function ThemeSync(): null {
  const { authed } = useAuthed();
  const { setTheme } = useTheme();
  const { data } = useQuery(ME_PROFILE, { skip: !authed });
  const applied = useRef(false);

  useEffect(() => {
    if (applied.current) return;
    const pref = data?.me?.uiThemePreference;
    // 防御：后端契约 dark|light，但 TS 类型是 string，显式收窄
    if (pref !== "dark" && pref !== "light") return;
    // ?theme= dev 调试参数优先——若设置则不覆盖
    if (typeof window !== "undefined") {
      const override = new URLSearchParams(window.location.search).get("theme");
      if (override === "dark" || override === "light") return;
    }
    setTheme(pref);
    applied.current = true;
  }, [data, setTheme]);

  return null;
}
