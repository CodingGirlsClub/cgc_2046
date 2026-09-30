import { beforeEach, describe, expect, it, vi } from "vitest";
import RegisterPage from "./page";
const { redirect } = vi.hoisted(() => ({ redirect: vi.fn(() => { throw new Error("redirect"); }) }));
vi.mock("@/i18n/navigation", () => ({ redirect }));
beforeEach(() => { redirect.mockClear(); });

describe("注册旧地址汇入统一入口", () => {
  it.each(["zh-CN", "en"])("%s 保留单值 next，忽略其他参数", async locale => {
    await expect(RegisterPage({ params: Promise.resolve({ locale }), searchParams: Promise.resolve({ next: "/events/demo?source=invite", bind_ticket: "old", unexpected: "x" }) })).rejects.toThrow("redirect");
    expect(redirect).toHaveBeenCalledWith({ href: { pathname: "/login", query: { next: "/events/demo?source=invite" } }, locale });
  });
  it("没有 next 或 next 重复时回到普通登录入口", async () => {
    for (const searchParams of [{}, { next: ["/first", "/second"] }]) {
      await expect(RegisterPage({ params: Promise.resolve({ locale: "en" }), searchParams: Promise.resolve(searchParams) })).rejects.toThrow("redirect");
      expect(redirect).toHaveBeenLastCalledWith({ href: "/login", locale: "en" });
    }
  });
  it("外部 next 仅作为参数传递，绝不成为 redirect 目标", async () => {
    await expect(RegisterPage({ params: Promise.resolve({ locale: "en" }), searchParams: Promise.resolve({ next: "https://foreign.example" }) })).rejects.toThrow("redirect");
    expect(redirect).toHaveBeenCalledWith({ href: { pathname: "/login", query: { next: "https://foreign.example" } }, locale: "en" });
  });
});
