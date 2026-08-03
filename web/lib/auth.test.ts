import { describe, it, expect, vi } from "vitest";

const { mutate, clearStore } = vi.hoisted(() => ({
  mutate: vi.fn().mockResolvedValue({ data: { signOut: "signed_out" } }),
  clearStore: vi.fn().mockResolvedValue(undefined),
}));

vi.mock("./apollo-client", () => ({
  client: { mutate, clearStore },
}));

describe("auth 登录态工具 (#61)", () => {
  it("clearSession 调 signOut mutation 并清 Apollo 缓存", async () => {
    const { clearSession } = await import("./auth");
    await clearSession();

    expect(mutate).toHaveBeenCalled();
    expect(clearStore).toHaveBeenCalled();
  });
});
