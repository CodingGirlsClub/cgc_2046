"use client";

/**
 * 平台管理员门控（Phase 7 / R1 前端守卫，D6 方案 A）。
 *
 * /admin/* layout 内单独用 ME_PROFILE（含 isPlatformAdmin）查询确认——
 * 不改全局 AuthProvider 的 ME_QUERY（影响面小，非 admin 用户也不多查该字段）。
 * `fetchCurrentProfile` 底层即 ME_PROFILE，Apollo cache 命中零网络。
 *
 * 判定：isPlatformAdmin === true → 放行渲染 children；
 * 其余（false / 未登录 me=null / 查询失败）→ 保守判非 admin，redirect 主页。
 * 查询返回前显示 loading（R8 风险缓解：confirmed 前不渲染 children，防闪烁/越权闪现）。
 */
import { useEffect, useState, type ReactNode } from "react";
import { useRouter } from "next/navigation";
import { useTranslations } from "next-intl";
import { fetchCurrentProfile } from "@/lib/profile";

type GuardState = "loading" | "allowed" | "denied";

export default function AdminGuard({ children }: { children: ReactNode }) {
	const router = useRouter();
	const t = useTranslations("admin");
	const [state, setState] = useState<GuardState>("loading");

	useEffect(() => {
		let cancelled = false;
		fetchCurrentProfile()
			.then((profile) => {
				if (cancelled) return;
				setState(profile.isPlatformAdmin ? "allowed" : "denied");
			})
			.catch(() => {
				// 查询失败（网络错误等）→ fail-closed：判非 admin，不渲染 admin 内容
				if (!cancelled) setState("denied");
			});
		return () => {
			cancelled = true;
		};
	}, []);

	useEffect(() => {
		if (state === "denied") {
			router.replace("/");
		}
	}, [state, router]);

	if (state !== "allowed") {
		return (
			<div className="admin-guard-loading">
				{t("confirming")}
			</div>
		);
	}

	return <>{children}</>;
}
