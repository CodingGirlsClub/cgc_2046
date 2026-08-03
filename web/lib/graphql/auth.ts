import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";

/**
 * #61 登录/注册 GraphQL mutation（已按后端 #60 实际 schema 对齐，commit d73b578）。
 *
 * 关键约定（已迁移 httpOnly cookie —— 路径 B）：
 * - signUp 是 create mutation：参数 input 嵌套，返回 result/errors 两段式；
 *   token 由后端 before_send 写 httpOnly cookie，响应体不再返回。
 * - signIn 是 read_one as_mutation：参数平铺，返回平铺字段（无 token）；
 *   失败时 signIn 为 null
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
}

export interface SignInResultData {
  id: string;
  email: string;
  isPlatformAdmin: boolean;
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
 * signIn 失败：signIn 为 null 且顶层 errors 抛异常。
 * 错误对象结构随 @apollo/client 版本变化：
 * - v4（本项目 4.2.9）：CombinedGraphQLErrors，持 `.errors` 数组（原始 GraphQL errors），
 *   `.message` 已 join 各错误 message（QueryManager.js:166 `throw new CombinedGraphQLErrors(...)`）。
 * - v3 及更早：ApolloError，持 `.graphQLErrors` 数组。
 * 提取首条 message；非 GraphQL 错误（网络异常等）返回 null（由调用方给兜底文案）。
 */
export function signInErrorMessage(e: unknown): string | null {
  if (!e || typeof e !== "object") return null;
  const err = e as {
    errors?: Array<{ message?: string }>;
    graphQLErrors?: Array<{ message?: string }>;
    message?: string;
  };

  // Apollo v4 CombinedGraphQLErrors：errors 为原始 GraphQL errors 数组
  const firstV4 = err.errors?.[0];
  if (firstV4?.message) return firstV4.message;

  // 兼容旧 ApolloError.graphQLErrors
  const firstV3 = err.graphQLErrors?.[0];
  if (firstV3?.message) return firstV3.message;

  // 确认为 GraphQL 错误对象时，回退 v4 的 message（已 join 各错误文案，
  // 如 "Invalid email or password"）；纯网络错误没有 errors/graphQLErrors，返回 null。
  if (Array.isArray(err.errors) || Array.isArray(err.graphQLErrors)) {
    if (err.message) return err.message;
  }
  return null;
}
