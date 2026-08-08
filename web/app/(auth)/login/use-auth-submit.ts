"use client";

import { useCallback, useState } from "react";
import { useMutation } from "@apollo/client/react";
import { useRouter } from "next/navigation";
import { client } from "@/lib/apollo-client";
import {
	SIGN_IN,
	SIGN_UP,
	signInErrorMessage,
	signUpErrorMessage,
} from "@/lib/graphql/auth";
import type { AuthSubmitPayload } from "./auth-form";

export interface UseAuthSubmitResult {
	/** 表单提交回调：mode=login 走 signIn，mode=register 走 signUp，成功跳转首页 */
	onSubmit: (payload: AuthSubmitPayload) => Promise<void>;
	busy: boolean;
	error: string | null;
}

/**
 * #61 登录/注册提交逻辑（页面级 hook）。
 *
 * - token 交付：后端 #60 路径 B（httpOnly cookie），signIn/signUp 响应体暂仍返回 token
 *   （Phase 1 向后兼容），但前端不再 setAuthToken——token 由后端 before_send 写 httpOnly cookie。
 * - 成功跳转：跳 "/"——首页按 workspace 列表分发：有可进入工作区 → 重定向默认
 *   workspace（最近记忆 > 第一个 active）；无 → 极简空态引导去 /join。
 * - 失败提示：signUp 取 result.errors[0].message；signIn 取 ApolloError.graphQLErrors[0].message。
 */
export function useAuthSubmit(): UseAuthSubmitResult {
	const router = useRouter();
	const [error, setError] = useState<string | null>(null);
	const [doSignIn, signInState] = useMutation(SIGN_IN);
	const [doSignUp, signUpState] = useMutation(SIGN_UP);

	const onSubmit = useCallback(
		async (payload: AuthSubmitPayload) => {
			setError(null);
			try {
				if (payload.mode === "login") {
					const { data } = await doSignIn({
						variables: { email: payload.email, password: payload.password },
					});
					if (data?.signIn?.id) {
						// ponytail: 同 SPA 会话换用户时 refetch me/ME_PROFILE。
						// logout 用 clearStore（不 refetch，cookie 将失效避免 401 风暴）；
						// login 时 cookie 新鲜，resetStore 用 B 的有效 cookie 重发所有活动查询。
						await client.resetStore();
						// token 由后端 before_send 写 httpOnly cookie
						router.push("/");
						return;
					}
					setError("登录失败，请检查邮箱与密码");
				} else {
					const { data } = await doSignUp({
						variables: {
							input: { email: payload.email, password: payload.password },
						},
					});
					if (data?.signUp?.result) {
						// ponytail: 同 SPA 会话换用户时 refetch me/ME_PROFILE。
						// logout 用 clearStore（不 refetch，cookie 将失效避免 401 风暴）；
						// login 时 cookie 新鲜，resetStore 用 B 的有效 cookie 重发所有活动查询。
						await client.resetStore();
						// token 由后端 before_send 写 httpOnly cookie
						router.push("/");
						return;
					}
					setError(signUpErrorMessage(data) ?? "注册失败，请稍后重试");
				}
			} catch (e) {
				setError(signInErrorMessage(e) ?? "网络异常，请稍后重试");
			}
		},
		[doSignIn, doSignUp, router],
	);

	return { onSubmit, busy: signInState.loading || signUpState.loading, error };
}
