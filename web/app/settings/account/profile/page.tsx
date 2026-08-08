"use client";

/**
 * 全局设置 → 个人资料（ADR-0004：全局入口下线）。
 *
 * profile 为 per-workspace 资源（WorkspaceProfile），不再有全局个人资料页。
 * 本页作为旧入口兜底：访问时重定向到默认社区 workspace 2046 的个人资料页
 * （新用户注册自动加入 2046，保证可访问）。
 */

import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { DEFAULT_WORKSPACE_SLUG } from "@/lib/profile";

export default function AccountProfilePageRedirect() {
	const router = useRouter();

	useEffect(() => {
		router.replace(`/w/${DEFAULT_WORKSPACE_SLUG}/settings/account/profile`);
	}, [router]);

	return (
		<main className="ws-shell-loading">
			<span>正在跳转到默认工作区个人资料…</span>
		</main>
	);
}
