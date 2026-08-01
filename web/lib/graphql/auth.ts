import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";

/**
 * #61 登录/注册 GraphQL mutation（已按后端 #60 实际 schema 对齐，commit d73b578）。
 *
 * 关键约定（与后端工程师 worker_c5ca4e44 确认）：
 * - signUp 是 create mutation：参数 input 嵌套，返回 result/errors/metadata 三段式；
 *   token 在 metadata.token（响应体交付，前端写 cgc_token cookie —— 路径 A）。
 * - signIn 是 read_one as_mutation：参数平铺，返回平铺字段；失败时 signIn 为 null
 *   且顶层 errors 含 [{ message, code: "authentication_failed" }]（Apollo 抛 ApolloError）。
 */

/* ---------------- 类型（对齐 backend/priv/graphql/schema.graphql） ---------------- */

export interface SignUpInput {
  /** 用户邮箱（全局唯一，登录身份标识） */
  email: string;
  /** 明文密码（后端 min 8 位） */
  password: string;
}

export interface MutationError {
  message?: string | null;
  code?: string | null;
}

export interface UserLite {
  id: string;
  email: string;
  isPlatformAdmin: boolean;
}

export interface SignUpResultData {
  result: UserLite | null;
  errors: MutationError[];
  metadata: { token: string } | null;
}

export interface SignInResultData {
  id: string;
  email: string;
  isPlatformAdmin: boolean;
  token: string;
}

/* ---------------- 真实 mutation ---------------- */

export const SIGN_UP: TypedDocumentNode<
  { signUp: SignUpResultData },
  { input: SignUpInput }
> = gql`
  mutation SignUp($input: SignUpInput!) {
    signUp(input: $input) {
      result {
        id
        email
        isPlatformAdmin
      }
      errors {
        message
        code
      }
      metadata {
        token
      }
    }
  }
`;

export const SIGN_IN: TypedDocumentNode<
  { signIn: SignInResultData | null },
  { email: string; password: string }
> = gql`
  mutation SignIn($email: String!, $password: String!) {
    signIn(email: $email, password: $password) {
      id
      email
      isPlatformAdmin
      token
    }
  }
`;

/* ---------------- 错误提取（两端结构不对称，统一转成前端可读 message） ---------------- */

/**
 * signUp 失败：mutation 不抛错，result 为 null、errors 数组含 message
 * （如 "has already been taken"）。返回首条 message；成功则返回 null。
 */
export function signUpErrorMessage(data: { signUp: SignUpResultData } | null | undefined): string | null {
  const errors = data?.signUp?.errors;
  if (data?.signUp?.result || !errors || errors.length === 0) return null;
  return errors[0]?.message ?? "注册失败，请稍后重试";
}

/**
 * signIn 失败：signIn 为 null 且顶层 errors 抛 ApolloError，
 * graphQLErrors[0] 形如 { message: "Invalid email or password", code: "authentication_failed" }。
 * 提取首条 message；非认证类错误返回 null（由调用方给兜底文案）。
 */
export function signInErrorMessage(e: unknown): string | null {
  const graphQLErrors = (e as { graphQLErrors?: Array<{ message?: string }> })?.graphQLErrors;
  const first = graphQLErrors?.[0];
  return first?.message ?? null;
}
