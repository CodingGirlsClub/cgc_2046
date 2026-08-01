import { describe, it, expect } from "vitest";
import { print } from "graphql";
import {
  SIGN_IN,
  SIGN_UP,
  signUpErrorMessage,
  signInErrorMessage,
  type SignUpResultData,
} from "./auth";

describe("signUp/signIn mutation 文档（对齐 #60 schema）", () => {
  it("SIGN_UP 使用 input 嵌套 + result/errors/metadata 三段式", () => {
    const doc = print(SIGN_UP);
    expect(doc).toContain("mutation SignUp($input: SignUpInput!)");
    expect(doc).toContain("signUp(input: $input)");
    expect(doc).toContain("result {");
    expect(doc).toContain("errors {");
    expect(doc).toContain("metadata {");
    expect(doc).toContain("isPlatformAdmin");
  });

  it("SIGN_IN 使用平铺 email/password 参数 + 平铺返回字段", () => {
    const doc = print(SIGN_IN);
    expect(doc).toContain("signIn(email: $email, password: $password)");
    expect(doc).toContain("id");
    expect(doc).toContain("email");
    expect(doc).toContain("isPlatformAdmin");
    expect(doc).toContain("token");
  });
});

describe("signUpErrorMessage（signUp 失败走 result.errors）", () => {
  const ok: { signUp: SignUpResultData } = {
    signUp: { result: { id: "u1", email: "a@b.c", isPlatformAdmin: false }, errors: [], metadata: { token: "t" } },
  };

  it("成功时返回 null", () => {
    expect(signUpErrorMessage(ok)).toBeNull();
    expect(signUpErrorMessage(undefined)).toBeNull();
  });

  it("失败时返回首条 message（如重复邮箱）", () => {
    const fail: { signUp: SignUpResultData } = {
      signUp: {
        result: null,
        errors: [{ message: "has already been taken", code: "unique" }],
        metadata: null,
      },
    };
    expect(signUpErrorMessage(fail)).toBe("has already been taken");
  });

  it("errors 为空数组时返回 null（视为成功）", () => {
    const empty: { signUp: SignUpResultData } = {
      signUp: { result: null, errors: [], metadata: null },
    };
    expect(signUpErrorMessage(empty)).toBeNull();
  });
});

describe("signInErrorMessage（signIn 失败走 Apollo v4 CombinedGraphQLErrors.errors）", () => {
  it("提取认证失败 message（v4 CombinedGraphQLErrors 结构）", () => {
    const e = { errors: [{ message: "Invalid email or password", code: "authentication_failed" }] };
    expect(signInErrorMessage(e)).toBe("Invalid email or password");
  });

  it("兼容旧版 ApolloError.graphQLErrors 结构", () => {
    const e = { graphQLErrors: [{ message: "Invalid email or password", code: "authentication_failed" }] };
    expect(signInErrorMessage(e)).toBe("Invalid email or password");
  });

  it("v4 错误无数组时回退 message（已 join 各错误文案）", () => {
    const e = { errors: [], message: "Invalid email or password" };
    expect(signInErrorMessage(e)).toBe("Invalid email or password");
  });

  it("非 GraphQL 错误返回 null（由调用方兜底）", () => {
    expect(signInErrorMessage(new Error("network"))).toBeNull();
    expect(signInErrorMessage(undefined)).toBeNull();
    expect(signInErrorMessage(null)).toBeNull();
  });
});
