"use client";

import { useCallback, useState } from "react";
import { useMutation } from "@apollo/client/react";
import { useRouter } from "next/navigation";
import { useTranslations } from "next-intl";
import { client } from "@/lib/apollo-client";
import {
	SIGN_IN,
	signInErrorMessage,
} from "@/lib/graphql/auth";
import type { AuthSubmitPayload } from "./auth-form";

/**
 * 解析登录后跳转目标（同源校验；任意写法——含 /\evil.example 反斜杠绕过——
 * 经 URL 解析后 origin 必须等于本站 origin）。非法/跨域输入回退 "/"。
 */
export function resolveNextTarget(raw: string | null, origin: string): string {
	if (!raw) return "/";
	try {
		const target = new URL(raw, origin);
		const path = target.pathname + target.search + target.hash;
		// 同源但 pathname 以 // 开头（http://本域//evil.example）会被 Next 路由
		// 解析为协议相对跳转 → 一并拒绝。
		if (target.origin !== origin || path.startsWith("//")) return "/";
		return path;
	} catch {
		return "/";
	}
}

/**
 * 登录后导航：iframe 内（D2 QR 面板）时接管顶层（同源才可写，跨源兜底本窗口）。
 * wechat-callback（SIGNED_IN / NEEDS_BINDING→绑定页）与 wechat-bind（绑定成功）共用。
 */
export function navigateAfterLogin(
	router: { push: (path: string) => void },
	nextRaw: string | null,
) {
	const path = resolveNextTarget(nextRaw, window.location.origin);
	if (window.self !== window.top) {
		try {
			window.top!.location.assign(path);
			return;
		} catch {
			// 跨源顶层（理论不可达，防御）：退回本窗口
		}
	}
	router.push(path);
}

export interface UseAuthSubmitResult {
	/** 表单提交回调：login 走 signIn（注册已迁 register-phone-form 手机号验证码路径） */
	onSubmit: (payload: AuthSubmitPayload) => Promise<void>;
	busy: boolean;
	error: string | null;
}

/**
 * #61 登录/注册提交逻辑（页面级 hook）。
 *
 * - token 交付：后端 #60 路径 B（httpOnly cookie）
 *   （Phase 1 向后兼容），但前端不再 setAuthToken——token 由后端 before_send 写 httpOnly cookie。
 * - 成功跳转：跳 "/"——首页按 workspace 列表分发：有可进入工作区 → 重定向默认
 *   workspace（最近记忆 > 第一个 active）；无 → 极简空态引导去 /join。
 * - 失败提示：signIn 取 ApolloError.graphQLErrors[0].message。
 */
export function useAuthSubmit(): UseAuthSubmitResult {
	const router = useRouter();
	const t = useTranslations("auth.errors");
	const searchParams = new URLSearchParams(
		typeof window !== "undefined" ? window.location.search : "",
	);
	// 登录前来源（公开面报名引导：/login?next=...）。同源校验逻辑收敛在
	// resolveNextTarget（纯函数，单测覆盖反斜杠绕过等恶意输入）。
	const nextRaw = searchParams.get("next");
	const next =
		typeof window !== "undefined"
			? resolveNextTarget(nextRaw, window.location.origin)
			: "/";
	const [error, setError] = useState<string | null>(null);
	const [doSignIn, signInState] = useMutation(SIGN_IN);

	const onSubmit = useCallback(
		async (payload: AuthSubmitPayload) => {
			setError(null);
			try {
					const { data } = await doSignIn({
						variables: { login: payload.login, password: payload.password },
					});

					if (data?.signIn?.id) {
						// ponytail: 同 SPA 会话换用户时 refetch me/ME_PROFILE。
						// logout 用 clearStore（不 refetch，cookie 将失效避免 401 风暴）；
						// login 时 cookie 新鲜，resetStore 用 B 的有效 cookie 重发所有活动查询。
						await client.resetStore();
						// token 由后端 before_send 写 httpOnly cookie
						router.push(next);
						return;
					}

					setError(t("loginFailed"));
			} catch (e) {
				setError(signInErrorMessage(e) ?? t("networkFailed"));
			}
		},
		[doSignIn, router, next, t],
	);

	return { onSubmit, busy: signInState.loading, error };
}
