import { describe, it, expect, vi, beforeEach } from "vitest";
import { renderHook, act } from "@testing-library/react";
import { useAuthed } from "./use-authed";

/**
 * useAuthed（#70 hydration-safe 登录态确认）单测。
 *
 * 首帧固定 { authed: false, confirmed: false }（与 SSR 空壳一致），挂载后
 * 通过 GraphQL `me` 查询确认登录态；confirmed=true 前调用方不得重定向。
 */

const { useQueryMock } = vi.hoisted(() => ({ useQueryMock: vi.fn() }));

vi.mock("@apollo/client/react", () => ({
  useQuery: useQueryMock,
}));

beforeEach(() => {
  vi.clearAllMocks();
});

describe("useAuthed (#70 hydration-safe 登录态确认)", () => {
  it("首帧 {authed:false, confirmed:false}（SSR 与 hydration 首帧一致）", () => {
    useQueryMock.mockReturnValue({ data: undefined, loading: true });
    const { result } = renderHook(() => useAuthed());

    expect(result.current).toEqual({ authed: false, confirmed: false });
  });

  it("已登录：me 查询返回后 {authed:true, confirmed:true}", async () => {
    useQueryMock.mockReturnValue({ data: { me: { id: "u1" } }, loading: false });
    const { result } = renderHook(() => useAuthed());

    await act(async () => {});
    expect(result.current).toEqual({ authed: true, confirmed: true });
  });

  it("未登录：me 查询报错后 {authed:false, confirmed:true}", async () => {
    useQueryMock.mockReturnValue({ data: undefined, loading: false });
    const { result } = renderHook(() => useAuthed());

    await act(async () => {});
    expect(result.current).toEqual({ authed: false, confirmed: true });
  });
});
