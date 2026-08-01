import { describe, it, expect, afterEach } from "vitest";
import { getAuthToken, buildAuthHeaders } from "./apollo-client";

function clearTokenCookie() {
  document.cookie = "cgc_token=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/";
}

describe("getAuthToken", () => {
  afterEach(clearTokenCookie);

  it("returns undefined when no token cookie is present", () => {
    expect(getAuthToken()).toBeUndefined();
  });

  it("reads the token from the cgc_token cookie", () => {
    document.cookie = "cgc_token=abc123; path=/";
    expect(getAuthToken()).toBe("abc123");
  });

  it("decodes URL-encoded tokens", () => {
    document.cookie = "cgc_token=eyJ%2Btoken; path=/";
    expect(getAuthToken()).toBe("eyJ+token");
  });
});

describe("buildAuthHeaders", () => {
  it("keeps existing headers when no token is given", () => {
    expect(buildAuthHeaders(undefined, { "content-type": "application/json" })).toEqual({
      "content-type": "application/json",
    });
  });

  it("attaches Authorization: Bearer when a token is given", () => {
    expect(buildAuthHeaders("secret")).toEqual({ authorization: "Bearer secret" });
  });

  it("merges the Authorization header with existing headers", () => {
    expect(buildAuthHeaders("secret", { "x-custom": "1" })).toEqual({
      "x-custom": "1",
      authorization: "Bearer secret",
    });
  });
});
