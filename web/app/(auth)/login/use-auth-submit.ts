"use client";

import { useCallback, useState } from "react";
import { useMutation } from "@apollo/client/react";
import { useRouter } from "next/navigation";
import { SIGN_IN, SIGN_UP, signInErrorMessage, signUpErrorMessage } from "@/lib/graphql/auth";
import { setAuthToken } from "@/lib/auth";
import type { AuthSubmitPayload } from "./auth-form";

export interface UseAuthSubmitResult {
  /** 表单提交回调：mode=login 走 signIn，mode=register 走 signUp，成功写 cgc_token 并跳转 */
  onSubmit: (payload: AuthSubmitPayload) => Promise<void>;
  busy: boolean;
  error: string | null;
}

/**
 * #61 登录/注册提交逻辑（页面级 hook）。
 *
 * - token 交付：后端 #60 走「响应体返回 token」（signUp: metadata.token；signIn: 平铺 token 字段），
 *   前端 setAuthToken 写入 cgc_token cookie，现有 apollo authLink 自动附加 Authorization。
 * - 成功跳转：暂跳 "/"（#63 workspace 选择页落地后改为 /workspaces）。
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
          const result = data?.signIn;
          if (result?.token) {
            setAuthToken(result.token);
            // TODO(#63): workspace 选择页就绪后改为 router.push("/workspaces")
            router.push("/");
            return;
          }
          setError("登录失败，请检查邮箱与密码");
        } else {
          // 注意：后端 #60 signUp 仅接收 email/password；资料展示名由个人资料页维护。
          const { data } = await doSignUp({
            variables: { input: { email: payload.email, password: payload.password } },
          });
          const token = data?.signUp?.metadata?.token;
          if (data?.signUp?.result && token) {
            setAuthToken(token);
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
