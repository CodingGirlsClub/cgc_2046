import { describe, it, expect, afterEach } from "vitest";
import { setAuthToken, clearAuthToken, isAuthenticated, TOKEN_COOKIE } from "./auth";
import { getAuthToken } from "./apollo-client";

afterEach(clearAuthToken);

describe("auth 登录态工具 (#61)", () => {
  it("TOKEN_COOKIE 与 apollo-client 读取的 cookie 名一致", () => {
    expect(TOKEN_COOKIE).toBe("cgc_token");
  });

  it("setAuthToken 写入 cgc_token cookie 后可被读取", () => {
    setAuthToken("jwt-abc");
    expect(getAuthToken()).toBe("jwt-abc");
    expect(isAuthenticated()).toBe(true);
  });

  it("URL 编码 token 可被正确写回", () => {
    setAuthToken("eyJ+tok");
    expect(getAuthToken()).toBe("eyJ+tok");
  });

  it("clearAuthToken 清除后未登录", () => {
    setAuthToken("jwt-abc");
    clearAuthToken();
    expect(getAuthToken()).toBeUndefined();
    expect(isAuthenticated()).toBe(false);
  });
});
