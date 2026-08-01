import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { renderHook, act, waitFor } from "@testing-library/react";
import { useAuthSubmit } from "./use-auth-submit";
import { clearAuthToken } from "@/lib/auth";
import { getAuthToken } from "@/lib/apollo-client";
import type { AuthSubmitPayload } from "./auth-form";

// vi.mock 工厂会被提升（hoist），mock 函数必须用 vi.hoisted 定义
const { push, signInMock, signUpMock } = vi.hoisted(() => ({
  push: vi.fn(),
  signInMock: vi.fn(),
  signUpMock: vi.fn(),
}));

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push }),
}));

vi.mock("@apollo/client/react", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@apollo/client/react")>();
  return {
    ...actual,
    useMutation: (doc: unknown) => {
      // TypedDocumentNode 的 String() 是 "[object Object]"，用 definition 名匹配
      const name = (doc as { definitions?: Array<{ name?: { value?: string } }> })?.definitions?.[0]
        ?.name?.value;
      if (name === "SignIn") return [signInMock, { loading: false }];
      if (name === "SignUp") return [signUpMock, { loading: false }];
      return [vi.fn(), { loading: false }];
    },
  };
});

const loginPayload: AuthSubmitPayload = { mode: "login", email: "a@b.c", password: "secret123" };
const registerPayload: AuthSubmitPayload = {
  mode: "register",
  nickname: "阿麦",
  email: "a@b.c",
  password: "secret123",
};

describe("useAuthSubmit（#61 登录/注册提交）", () => {
  beforeEach(() => {
    push.mockClear();
    signInMock.mockReset();
    signUpMock.mockReset();
    clearAuthToken();
  });

  afterEach(clearAuthToken);

  it("登录成功：写 cgc_token cookie 并跳转首页", async () => {
    signInMock.mockResolvedValue({
      data: { signIn: { id: "u1", email: "a@b.c", isPlatformAdmin: false, token: "jwt-login" } },
    });
    const { result } = renderHook(() => useAuthSubmit());
    await act(() => result.current.onSubmit(loginPayload));
    expect(getAuthToken()).toBe("jwt-login");
    expect(push).toHaveBeenCalledWith("/");
    expect(result.current.error).toBeNull();
  });

  it("登录失败（ApolloError）：展示后端 message，不写 cookie 不跳转", async () => {
    signInMock.mockRejectedValue({
      errors: [{ message: "Invalid email or password", code: "authentication_failed" }],
    });
    const { result } = renderHook(() => useAuthSubmit());
    await act(() => result.current.onSubmit(loginPayload));
    await waitFor(() => expect(result.current.error).toBe("Invalid email or password"));
    expect(getAuthToken()).toBeUndefined();
    expect(push).not.toHaveBeenCalled();
  });

  it("注册成功：写 cgc_token cookie（自动登录）并跳转首页", async () => {
    signUpMock.mockResolvedValue({
      data: {
        signUp: {
          result: { id: "u2", email: "a@b.c", isPlatformAdmin: false },
          errors: [],
          metadata: { token: "jwt-register" },
        },
      },
    });
    const { result } = renderHook(() => useAuthSubmit());
    await act(() => result.current.onSubmit(registerPayload));
    expect(getAuthToken()).toBe("jwt-register");
    expect(push).toHaveBeenCalledWith("/");
  });

  it("注册失败（重复邮箱）：展示 result.errors[0].message，不写 cookie", async () => {
    signUpMock.mockResolvedValue({
      data: { signUp: { result: null, errors: [{ message: "has already been taken" }], metadata: null } },
    });
    const { result } = renderHook(() => useAuthSubmit());
    await act(() => result.current.onSubmit(registerPayload));
    await waitFor(() => expect(result.current.error).toBe("has already been taken"));
    expect(getAuthToken()).toBeUndefined();
    expect(push).not.toHaveBeenCalled();
  });

  it("网络异常：展示兜底文案", async () => {
    signInMock.mockRejectedValue(new Error("fetch failed"));
    const { result } = renderHook(() => useAuthSubmit());
    await act(() => result.current.onSubmit(loginPayload));
    await waitFor(() => expect(result.current.error).toBe("网络异常，请稍后重试"));
    expect(push).not.toHaveBeenCalled();
  });
});
