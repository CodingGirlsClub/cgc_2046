import { describe, it, expect, vi, beforeEach } from "vitest";
import { renderHook, act } from "@testing-library/react";
import { useAuthed } from "./use-authed";

/**
 * useAuthed（#70 hydration-safe 登录态确认）单测。
 *
 * 首帧固定 { authed: false, confirmed: false }（与 SSR 空壳一致），挂载后
 * 异步读 cookie 确认；confirmed=true 前调用方不得重定向，避免已登录用户
 * 被先跳 /login。
 */

const { isAuthenticated } = vi.hoisted(() => ({ isAuthenticated: vi.fn() }));

vi.mock("@/lib/auth", () => ({
  isAuthenticated,
}));

beforeEach(() => {
  vi.clearAllMocks();
});

describe("useAuthed (#70 hydration-safe 登录态确认)", () => {
  it("首帧 {authed:false, confirmed:false}（SSR 与 hydration 首帧一致）", () => {
    isAuthenticated.mockReturnValue(true);
    const { result } = renderHook(() => useAuthed());

    expect(result.current).toEqual({ authed: false, confirmed: false });
    expect(isAuthenticated).not.toHaveBeenCalled();
  });

  it("已登录：挂载后确认 {authed:true, confirmed:true}", async () => {
    isAuthenticated.mockReturnValue(true);
    const { result } = renderHook(() => useAuthed());

    await act(async () => {});
    expect(result.current).toEqual({ authed: true, confirmed: true });
    expect(isAuthenticated).toHaveBeenCalledTimes(1);
  });

  it("未登录：挂载后 {authed:false, confirmed:true}（调用方据此重定向 /login）", async () => {
    isAuthenticated.mockReturnValue(false);
    const { result } = renderHook(() => useAuthed());

    await act(async () => {});
    expect(result.current).toEqual({ authed: false, confirmed: true });
    expect(isAuthenticated).toHaveBeenCalledTimes(1);
  });
});
