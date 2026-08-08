"use client";

import { useEffect, useRef } from "react";
import { usePathname } from "next/navigation";
import { useQuery } from "@apollo/client/react";
import { useAuthed } from "@/lib/use-authed";
import { useTheme } from "@/lib/theme-provider";
import { WORKSPACE_PROFILE } from "@/lib/graphql/profile";
import { ME_WORKSPACES } from "@/lib/graphql/workspace";

/**
 * 主题服务端同步（U3，ADR-0004 per-workspace）：进入 workspace 后拉取该工作台的
 * 服务端 uiThemePreference（workspaceProfile）并应用，实现跨设备同步。
 *
 * 优先级：?theme= URL 参数（dev 调试，跳过服务端同步）> 服务端偏好 > localStorage > dark。
 * 按 workspace 应用一次（appliedFor ref 守卫），切换 workspace 时重应用。
 * 应用时 setTheme 同步写 localStorage（per-workspace key，保证下次首帧一致）。
 *
 * 无 UI——纯副作用组件，挂在 ApolloProvider 内（layout 经 ApolloWrapper）。
 */
export default function ThemeSync(): null {
	const { authed } = useAuthed();
	const pathname = usePathname();
	const { setTheme } = useTheme();

	// 当前 workspace slug（无 ws 上下文页面为 null）
	const slugMatch = /^\/w\/([^/]+)/.exec(pathname ?? "");
	const slug = slugMatch?.[1] ?? null;

	// meWorkspaces：slug → workspaceId（workspaceProfile query 需要 id）
	const { data: wsData } = useQuery(ME_WORKSPACES, { skip: !authed });
	const workspaceId =
		wsData?.meWorkspaces?.find((w) => w.slug === slug)?.id ?? null;

	// 按 workspace id 记忆「已为本 workspace 应用过服务端主题」
	const appliedFor = useRef<string | null>(null);

	const { data: profileData } = useQuery(WORKSPACE_PROFILE, {
		skip: !authed || !workspaceId,
		variables: { workspaceId: workspaceId ?? "" },
	});
	const pref = profileData?.workspaceProfile?.uiThemePreference ?? null;

	useEffect(() => {
		if (workspaceId == null) {
			appliedFor.current = null;
			return;
		}
		if (appliedFor.current === workspaceId) return;
		// 防御：后端契约 dark|light，显式收窄
		if (pref !== "dark" && pref !== "light") return;
		// ?theme= dev 调试参数优先——若设置则不覆盖
		if (typeof window !== "undefined") {
			const override = new URLSearchParams(window.location.search).get("theme");
			if (override === "dark" || override === "light") return;
		}
		setTheme(pref);
		appliedFor.current = workspaceId;
	}, [workspaceId, pref, setTheme]);

	return null;
}
