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
 * 按用户 id 应用一次，换用户重应用（appliedForUserId ref 守卫，登出清缓存后 userId 变空 → 复位）。
 * 应用时 setTheme 同步写 localStorage（保证下次首帧一致）。
 *
 * 无 UI——纯副作用组件，挂在 ApolloProvider 内（layout 经 ApolloWrapper）。
 */
export default function ThemeSync(): null {
	const { authed } = useAuthed();
	const { setTheme } = useTheme();
	const { data } = useQuery(ME_PROFILE, { skip: !authed });
	// 按用户 id 记忆「已为本用户应用过服务端主题」——换用户（含登出后重登另一用户）会重应用。
	// 依赖 Step 1 的 clearSession：logout 清缓存使 data.me 失效 → userId 变空 → ref 复位。
	const appliedForUserId = useRef<string | null>(null);

	useEffect(() => {
		const userId = data?.me?.id;
		const pref = data?.me?.uiThemePreference;

		// 未登录 / 无数据：复位，等下次有用户数据时重应用
		if (userId == null) {
			appliedForUserId.current = null;
			return;
		}
		// 已为本用户应用过：跳过（避免导航重挂覆盖会话内 toggle）
		if (appliedForUserId.current === userId) return;
		// 防御：后端契约 dark|light，但 TS 类型是 string，显式收窄
		if (pref !== "dark" && pref !== "light") return;
		// ?theme= dev 调试参数优先——若设置则不覆盖
		if (typeof window !== "undefined") {
			const override = new URLSearchParams(window.location.search).get("theme");
			if (override === "dark" || override === "light") return;
		}
		setTheme(pref);
		appliedForUserId.current = userId;
	}, [data, setTheme]);

	return null;
}
