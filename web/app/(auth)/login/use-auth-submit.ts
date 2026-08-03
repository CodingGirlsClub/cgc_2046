"use client";

import { useCallback, useState } from "react";
import { useMutation } from "@apollo/client/react";
import { useRouter } from "next/navigation";
import { SIGN_IN, SIGN_UP, signInErrorMessage, signUpErrorMessage } from "@/lib/graphql/auth";
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
          if (data?.signIn?.id) {
            // token 由后端 before_send 写 httpOnly cookie
            router.push("/");
            return;
          }
          setError("登录失败，请检查邮箱与密码");
        } else {
          const { data } = await doSignUp({
            variables: { input: { email: payload.email, password: payload.password } },
          });
          if (data?.signUp?.result) {
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
