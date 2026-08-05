import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { renderHook, act } from "@testing-library/react";
import { type ReactNode } from "react";
import { CombinedGraphQLErrors } from "@apollo/client/errors";
import { AuthProvider, useAuthed } from "./auth-provider";

/**
 * AuthProvider/useAuthed（#70 hydration-safe 登录态确认，#7 根 layout 共享）单测。
 *
 * me 查询挂在根 layout 的 AuthProvider 单例，通过 context 分发 { authed, confirmed }。
 * 首帧固定 { authed: false, confirmed: false }（与 SSR 空壳一致），me 查询返回后
 * 确认登录态；confirmed=true 前调用方不得重定向。
 *
 * #13：区分网络错误（传输层失败）与认证错误（CombinedGraphQLErrors: unauthorized）。
 * 网络错误保持上次 confirmed 状态并重试；认证错误据 data.me 判定未登录。
 */

const { useQueryMock } = vi.hoisted(() => ({ useQueryMock: vi.fn() }));

vi.mock("@apollo/client/react", () => ({
	useQuery: useQueryMock,
}));

// CombinedGraphQLErrors.is 是 instance 判定，测试里用真实类构造更贴合生产行为。
// 构造一个 unauthorized 形态的 CombinedGraphQLErrors（后端 me resolver 返回 {:error,"unauthorized"}）。
function unauthorizedError(): CombinedGraphQLErrors {
	return new CombinedGraphQLErrors({
		data: { me: null },
		errors: [{ message: "unauthorized" }],
	});
}

// auth_uncertain 形态：后端标记 token 有效但 user 加载失败（DB 故障 / 撤销），
// Absinthe 把 code 放顶层 errors[i].code（与 sign_in 的 authentication_failed 一致）。
// GraphQLFormattedError 类型不含 code，用 as 断言贴合 Absinthe 实际行为。
function authUncertainError(): CombinedGraphQLErrors {
	const error = { message: "Auth state uncertain", code: "auth_uncertain" } as {
		message: string;
		code: string;
	};
	return new CombinedGraphQLErrors({ data: { me: null }, errors: [error] });
}

// 网络错误：非 200，Apollo 包成 Error 的传输层失败形态（非 CombinedGraphQLErrors）。
function networkError(): Error {
	return new Error("Network request failed");
}

const wrapper = ({ children }: { children: ReactNode }) => (
	<AuthProvider>{children}</AuthProvider>
);

beforeEach(() => {
	vi.clearAllMocks();
});

afterEach(() => {
	vi.useRealTimers();
});

describe("useAuthed (#70 hydration-safe，#7 根 layout 共享，#13 网络错误区分)", () => {
	it("首帧 {authed:false, confirmed:false, userId:null}（SSR 与 hydration 首帧一致）", () => {
		useQueryMock.mockReturnValue({
			data: undefined,
			loading: true,
			error: undefined,
			refetch: vi.fn(),
		});
		const { result } = renderHook(() => useAuthed(), { wrapper });

		expect(result.current).toEqual({
			authed: false,
			confirmed: false,
			userId: null,
		});
	});

	it("已登录：me 查询返回后 {authed:true, confirmed:true, userId}", async () => {
		useQueryMock.mockReturnValue({
			data: { me: { id: "u1" } },
			loading: false,
			error: undefined,
			refetch: vi.fn(),
		});
		const { result } = renderHook(() => useAuthed(), { wrapper });

		await act(async () => {});
		expect(result.current).toEqual({
			authed: true,
			confirmed: true,
			userId: "u1",
		});
	});

	it("未登录：me 查询返回 unauthorized(CombinedGraphQLErrors) 后 {authed:false, confirmed:true, userId:null}", async () => {
		useQueryMock.mockReturnValue({
			data: { me: null },
			loading: false,
			error: unauthorizedError(),
			refetch: vi.fn(),
		});
		const { result } = renderHook(() => useAuthed(), { wrapper });

		await act(async () => {});
		expect(result.current).toEqual({
			authed: false,
			confirmed: true,
			userId: null,
		});
	});

	it("#13 网络错误：保持上次 confirmed 状态，不踢已登录用户", async () => {
		vi.useFakeTimers();
		// 先已登录
		useQueryMock.mockReturnValue({
			data: { me: { id: "u1" } },
			loading: false,
			error: undefined,
			refetch: vi.fn(),
		});
		const { result, rerender } = renderHook(() => useAuthed(), { wrapper });
		await act(async () => {});
		expect(result.current).toEqual({
			authed: true,
			confirmed: true,
			userId: "u1",
		});

		// 网络抖动：data:undefined + 传输层 error（refetch 模拟立即失败）
		const failingRefetch = vi.fn().mockRejectedValue(new Error("still down"));
		useQueryMock.mockReturnValue({
			data: undefined,
			loading: false,
			error: networkError(),
			refetch: failingRefetch,
		});
		rerender();
		await act(async () => {
			// 推进 fake timer 让重试 setTimeout 触发并完成
			await vi.advanceTimersByTimeAsync(10000);
		});

		// 核心断言：网络错误不应改变已确认的登录态
		expect(result.current).toEqual({
			authed: true,
			confirmed: true,
			userId: "u1",
		});
		expect(failingRefetch).toHaveBeenCalled();
	});

	it("#13 Finding A auth_uncertain：token 有效但 user 加载失败时保持登录态", async () => {
		vi.useFakeTimers();
		// 先已登录
		useQueryMock.mockReturnValue({
			data: { me: { id: "u1" } },
			loading: false,
			error: undefined,
			refetch: vi.fn(),
		});
		const { result, rerender } = renderHook(() => useAuthed(), { wrapper });
		await act(async () => {});
		expect(result.current).toEqual({
			authed: true,
			confirmed: true,
			userId: "u1",
		});

		// DB 故障：后端返回 auth_uncertain（CombinedGraphQLErrors + code）
		const failingRefetch = vi
			.fn()
			.mockRejectedValue(new Error("db still down"));
		useQueryMock.mockReturnValue({
			data: { me: null },
			loading: false,
			error: authUncertainError(),
			refetch: failingRefetch,
		});
		rerender();
		await act(async () => {
			await vi.advanceTimersByTimeAsync(10000);
		});

		// auth_uncertain 应保持登录态并重试，而非判未登录踢出
		expect(result.current).toEqual({
			authed: true,
			confirmed: true,
			userId: "u1",
		});
		expect(failingRefetch).toHaveBeenCalled();
	});
});
