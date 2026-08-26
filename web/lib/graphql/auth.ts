import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import type { MutationResult } from "./shared";

/**
 * #61 登录/注册 GraphQL mutation（已按后端 #60 实际 schema 对齐，commit d73b578）。
 *
 * 关键约定（已迁移 httpOnly cookie —— 路径 B）：
 * - signUpWithPhone（手机号注册）是 create mutation：input 嵌套，result/errors 两段式；
 *   token 由后端 before_send 写 httpOnly cookie（旧邮箱 signUp 已下线）。
 * - signIn 是 read_one as_mutation：参数平铺，返回平铺字段（无 token）；
 *   失败时 signIn 为 null
 *   且顶层 errors 含 [{ message, code: "authentication_failed" }]（Apollo 抛 ApolloError）。
 */

/* ---------------- 类型（对齐 backend/priv/graphql/schema.graphql） ---------------- */

export interface UserLite {
  id: string;
  email: string;
  isPlatformAdmin: boolean;
}

export interface SignInResultData {
  id: string;
  email: string;
  isPlatformAdmin: boolean;
}

export interface RequestPasswordResetResult {
  sent: boolean;
}

export interface ResetPasswordResult {
  ok: boolean;
}

export interface PasswordResetGraphqlError {
  message?: string;
  code?: string;
  fields?: string[];
}

/* ---------------- 真实 mutation ---------------- */

/* ---------------- 手机号注册（/register 邮箱 → 手机号） ---------------- */

export interface SignUpWithPhoneInput {
  /** 手机号（后端归一化 +86 形） */
  phone: string;
  /** 短信验证码（purpose REGISTER） */
  code: string;
  /** 明文密码（后端 min 8 位） */
  password: string;
}

export interface PhoneUserLite {
  id: string;
  /** 手机号用户 email 可空 */
  email: string | null;
  isPlatformAdmin: boolean;
}

export type SignUpWithPhoneResultData = MutationResult<PhoneUserLite>;

export const SIGN_UP_WITH_PHONE: TypedDocumentNode<
  { signUpWithPhone: SignUpWithPhoneResultData },
  { input: SignUpWithPhoneInput }
> = gql`
  mutation SignUpWithPhone($input: SignUpWithPhoneInput!) {
    signUpWithPhone(input: $input) {
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
  { login: string; password: string }
> = gql`
  mutation SignIn($login: String!, $password: String!) {
    signIn(login: $login, password: $password) {
      id
      email
      isPlatformAdmin
    }
  }
`;

/* ---------------- 手机验证码登录（plan 002 U3/U5） ---------------- */

export type PhoneCodePurpose = "LOGIN" | "WECHAT_BIND" | "REGISTER";

export interface RequestPhoneCodeResult {
  sent: boolean;
  retryAfterSeconds: number;
}

export interface SignInWithPhoneCodeResultData {
  id: string;
  email: string | null;
  isPlatformAdmin: boolean;
}

export const REQUEST_PHONE_CODE: TypedDocumentNode<
  { requestPhoneCode: RequestPhoneCodeResult | null },
  { phone: string; purpose: PhoneCodePurpose }
> = gql`
  mutation RequestPhoneCode($phone: String!, $purpose: PhoneCodePurpose!) {
    requestPhoneCode(phone: $phone, purpose: $purpose) {
      sent
      retryAfterSeconds
    }
  }
`;

export const SIGN_IN_WITH_PHONE_CODE: TypedDocumentNode<
  { signInWithPhoneCode: SignInWithPhoneCodeResultData | null },
  { phone: string; code: string }
> = gql`
  mutation SignInWithPhoneCode($phone: String!, $code: String!) {
    signInWithPhoneCode(phone: $phone, code: $code) {
      id
      email
      isPlatformAdmin
    }
  }
`;

/* ---------------- 微信扫码登录（plan 002 U4/U5） ---------------- */

export interface WechatLoginStartResult {
  qrUrl: string;
  state: string;
  expiresInSeconds: number;
}

export type WechatSignInStatus = "SIGNED_IN" | "NEEDS_BINDING";

export interface SignInWithWechatResultData {
  status: WechatSignInStatus;
  bindTicket: string | null;
}

export const WECHAT_LOGIN_START: TypedDocumentNode<
  { wechatLoginStart: WechatLoginStartResult | null },
  { next?: string | null }
> = gql`
  mutation WechatLoginStart($next: String) {
    wechatLoginStart(next: $next) {
      qrUrl
      state
      expiresInSeconds
    }
  }
`;

export const SIGN_IN_WITH_WECHAT: TypedDocumentNode<
  { signInWithWechat: SignInWithWechatResultData | null },
  { code: string; state: string }
> = gql`
  mutation SignInWithWechat($code: String!, $state: String!) {
    signInWithWechat(code: $code, state: $state) {
      status
      bindTicket
    }
  }
`;

export const BIND_WECHAT_WITH_PHONE: TypedDocumentNode<
  { bindWechatWithPhone: SignInWithPhoneCodeResultData | null },
  { bindTicket: string; phone: string; code: string }
> = gql`
  mutation BindWechatWithPhone($bindTicket: String!, $phone: String!, $code: String!) {
    bindWechatWithPhone(bindTicket: $bindTicket, phone: $phone, code: $code) {
      id
      email
      isPlatformAdmin
    }
  }
`;

export const REQUEST_PASSWORD_RESET: TypedDocumentNode<
  { requestPasswordReset: RequestPasswordResetResult | null },
  { email: string }
> = gql`
  mutation RequestPasswordReset($email: String!) {
    requestPasswordReset(email: $email) {
      sent
    }
  }
`;

export const RESET_PASSWORD: TypedDocumentNode<
  { resetPassword: ResetPasswordResult | null },
  { resetToken: string; password: string }
> = gql`
  mutation ResetPassword($resetToken: String!, $password: String!) {
    resetPassword(resetToken: $resetToken, password: $password) {
      ok
    }
  }
`;

/* ---------------- 错误提取（两端结构不对称，统一转成前端可读 message） ---------------- */


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
/**
 * 从 Apollo v4/v3 的 top-level GraphQL error 提取 code、fields 和 message。
 * 后端 AshGraphql 错误在不同 Apollo 版本中可能把扩展字段放在顶层或
 * `extensions`，找回密码页面只依赖这三个稳定语义。
 */
export function graphqlErrorDetails(e: unknown): PasswordResetGraphqlError | null {
  if (!e || typeof e !== "object") return null;

  const err = e as {
    errors?: unknown[];
    graphQLErrors?: unknown[];
  };
  const first = Array.isArray(err.errors)
    ? err.errors[0]
    : Array.isArray(err.graphQLErrors)
      ? err.graphQLErrors[0]
      : null;

  if (!first || typeof first !== "object") return null;

  const raw = first as {
    message?: unknown;
    code?: unknown;
    fields?: unknown;
    extensions?: { code?: unknown; fields?: unknown };
  };
  const fields = raw.fields ?? raw.extensions?.fields;

  return {
    message: typeof raw.message === "string" ? raw.message : undefined,
    code:
      typeof raw.code === "string"
        ? raw.code
        : typeof raw.extensions?.code === "string"
          ? raw.extensions.code
          : undefined,
    fields: Array.isArray(fields)
      ? fields.filter((field): field is string => typeof field === "string")
      : undefined,
  };
}

/**
 * 通用版 signInErrorMessage：从 Apollo 抛出的 top-level GraphQL error 提取首条 message，
 * 非 GraphQL 错误（网络异常等）回退 fallback。用于 generic action mutation（如 joinWorkspace）
 * ——后端无 result/errors 包装，失败时错误走 top-level GraphQL error 而非 data.xxx.errors。
 */
export function graphqlErrorMessage(e: unknown, fallback: string): string {
  return signInErrorMessage(e) ?? fallback;
}
