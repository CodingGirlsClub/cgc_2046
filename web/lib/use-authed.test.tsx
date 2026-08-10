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
			// #101：只推进到重试窗口内（第 1 次退避 1s）——重试窗口内网络错误
			// 不踢已登录用户；持续 >7s 故障的兜底行为由「#101 重试耗尽兜底」describe 覆盖
			await vi.advanceTimersByTimeAsync(1000);
		});

		// 核心断言：重试窗口内网络错误不应改变已确认的登录态
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

		// DB 故障：后端返回 auth_uncertain（HTTP 200 + GraphQL errors）——Apollo
		// refetch 会 resolve 而非 reject（errorPolicy:"all" 下 res.error 携带
		// CombinedGraphQLErrors）。真实 Apollo 行为，见 #101。
		const failingRefetch = vi.fn().mockResolvedValue({
			data: { me: null },
			error: authUncertainError(),
		});
		useQueryMock.mockReturnValue({
			data: { me: null },
			loading: false,
			error: authUncertainError(),
			refetch: failingRefetch,
		});
		rerender();
		await act(async () => {
			// #101：只推进到重试窗口内（第 1 次退避 1s）；持续故障兜底见「#101 重试耗尽兜底」
			await vi.advanceTimersByTimeAsync(1000);
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

describe("#017 Bug A 回归：me 重试链不再被 refetch 的 loading 翻转取消", () => {
	it("网络错误：1s/2s/4s 指数退避重试共 3 次，期间保持 confirmed:false", async () => {
		vi.useFakeTimers();
		const refetchMock = vi.fn().mockRejectedValue(new Error("still down"));
		useQueryMock.mockReturnValue({
			data: undefined,
			loading: false,
			error: networkError(),
			refetch: refetchMock,
		});
		const { result } = renderHook(() => useAuthed(), { wrapper });

		await act(async () => {
			await vi.advanceTimersByTimeAsync(1000); // 第 1 次（1s 退避）
		});
		expect(refetchMock).toHaveBeenCalledTimes(1);
		await act(async () => {
			await vi.advanceTimersByTimeAsync(2000); // 第 2 次（2s 退避）
		});
		expect(refetchMock).toHaveBeenCalledTimes(2);
		await act(async () => {
			await vi.advanceTimersByTimeAsync(4000); // 第 3 次（4s 退避）
		});
		expect(refetchMock).toHaveBeenCalledTimes(3);

		// #101：重试用尽（持续故障 1s+2s+4s）兜底判未登录（confirmed:true + authed:false），
		// 走既有 /login 守卫，避免受保护页永久卡「正在确认登录状态」
		expect(result.current).toEqual({
			authed: false,
			confirmed: true,
			userId: null,
		});
	});

	it("重试中成功：第 2 次 refetch resolve → confirmed:true，不再发起第 3 次", async () => {
		vi.useFakeTimers();
		const refetchMock = vi
			.fn()
			.mockRejectedValueOnce(new Error("still down"))
			.mockImplementationOnce(() => {
				// 模拟 Apollo：refetch 成功后 data 到位，effect 据 data?.me 确认登录态
				useQueryMock.mockReturnValue({
					data: { me: { id: "u1" } },
					loading: false,
					error: undefined,
					refetch: refetchMock,
				});
				rerender();
				return Promise.resolve({ data: { me: { id: "u1" } } });
			});
		useQueryMock.mockReturnValue({
			data: undefined,
			loading: false,
			error: networkError(),
			refetch: refetchMock,
		});
		const { result, rerender } = renderHook(() => useAuthed(), { wrapper });

		await act(async () => {
			await vi.advanceTimersByTimeAsync(1000); // 第 1 次失败
		});
		expect(refetchMock).toHaveBeenCalledTimes(1);
		await act(async () => {
			await vi.advanceTimersByTimeAsync(2000); // 第 2 次成功
		});
		expect(refetchMock).toHaveBeenCalledTimes(2);
		expect(result.current).toEqual({
			authed: true,
			confirmed: true,
			userId: "u1",
		});

		// 成功后不再安排第 3 次重试
		await act(async () => {
			await vi.advanceTimersByTimeAsync(10000);
		});
		expect(refetchMock).toHaveBeenCalledTimes(2);
	});

	it("refetch 期间 loading 翻转（Apollo 默认 notifyOnNetworkStatusChange:true）不取消重试链", async () => {
		vi.useFakeTimers();
		let rerenderFn: () => void = () => {};
		const refetchMock = vi.fn(() => {
			// 模拟 Apollo：refetch 开始 loading 翻 true（触发 effect 重跑），
			// 失败后再回 false + error —— 旧实现里 cleanup 在此杀死重试链（#017 Bug A）
			useQueryMock.mockReturnValue({
				data: undefined,
				loading: true,
				error: undefined,
				refetch: refetchMock,
			});
			rerenderFn();
			useQueryMock.mockReturnValue({
				data: undefined,
				loading: false,
				error: networkError(),
				refetch: refetchMock,
			});
			rerenderFn();
			return Promise.reject(new Error("still down"));
		});
		useQueryMock.mockReturnValue({
			data: undefined,
			loading: false,
			error: networkError(),
			refetch: refetchMock,
		});
		const { rerender } = renderHook(() => useAuthed(), { wrapper });
		rerenderFn = rerender;

		await act(async () => {
			await vi.advanceTimersByTimeAsync(1000);
		});
		expect(refetchMock).toHaveBeenCalledTimes(1);
		await act(async () => {
			await vi.advanceTimersByTimeAsync(2000);
		});
		expect(refetchMock).toHaveBeenCalledTimes(2);
		await act(async () => {
			await vi.advanceTimersByTimeAsync(4000);
		});
		// 重试链跑满 3 次（旧实现第 1 次就被 loading 翻转取消，这里只会有 1 次）
		expect(refetchMock).toHaveBeenCalledTimes(3);
	});
});

describe("#101 重试耗尽兜底：持续网络故障不永久卡「正在确认登录状态」", () => {
	it("未登录 + auth_uncertain 重试耗尽 → 兜底判未登录（confirmed:true），走 /login 守卫", async () => {
		vi.useFakeTimers();
		// auth_uncertain 是 HTTP 200 + GraphQL errors：Apollo refetch resolve（真实
		// 行为，非 reject），res.error 持续携带 CombinedGraphQLErrors。
		const refetchMock = vi.fn().mockResolvedValue({
			data: { me: null },
			error: authUncertainError(),
		});
		useQueryMock.mockReturnValue({
			data: { me: null },
			loading: false,
			error: authUncertainError(),
			refetch: refetchMock,
		});
		const { result } = renderHook(() => useAuthed(), { wrapper });

		await act(async () => {
			// 推进覆盖 1s/2s/4s 三次退避 + 耗尽
			await vi.advanceTimersByTimeAsync(10000);
		});

		// 3 次重试全部失败后兜底判未登录，而非永久卡 confirmed:false
		expect(refetchMock).toHaveBeenCalledTimes(3);
		expect(result.current).toEqual({
			authed: false,
			confirmed: true,
			userId: null,
		});
	});

	it("已确认登录态 + 持续网络故障耗尽 → 保持原登录态，不兜底误踢（#13）", async () => {
		vi.useFakeTimers();
		// 先已登录（服务端实锤 me.id）
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

		// 持续网络故障：refetch 全部失败
		const refetchMock = vi.fn().mockRejectedValue(new Error("still down"));
		useQueryMock.mockReturnValue({
			data: undefined,
			loading: false,
			error: networkError(),
			refetch: refetchMock,
		});
		rerender();
		await act(async () => {
			await vi.advanceTimersByTimeAsync(10000);
		});

		// 重试 3 次耗尽：已确认的登录态是服务端实锤（me.id 曾返回），兜底仅针对
		// 首帧未确认（#101 分流语义），已登录用户不被误踢 /login
		expect(refetchMock).toHaveBeenCalledTimes(3);
		expect(result.current).toEqual({
			authed: true,
			confirmed: true,
			userId: "u1",
		});
	});

	it("已确认登录态 + auth_uncertain（resolve）持续 3 次耗尽 → 保持登录态，不兜底误踢（#13）", async () => {
		vi.useFakeTimers();
		// 先已登录（服务端实锤 me.id）
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

		// DB 故障持续：auth_uncertain（HTTP 200 + errors）→ Apollo refetch resolve、
		// res.error 仍 auth_uncertain → 走 .then() 继续退避分支（#101 新增路径）。
		// 此前该路径在 .then() 里归零 attemptRef → 无限退避循环。
		const refetchMock = vi.fn().mockResolvedValue({
			data: { me: null },
			error: authUncertainError(),
		});
		useQueryMock.mockReturnValue({
			data: { me: null },
			loading: false,
			error: authUncertainError(),
			refetch: refetchMock,
		});
		rerender();
		await act(async () => {
			await vi.advanceTimersByTimeAsync(10000);
		});

		// 3 次 resolve 退避耗尽：已确认登录态保持，不被误踢 /login
		expect(refetchMock).toHaveBeenCalledTimes(3);
		expect(result.current).toEqual({
			authed: true,
			confirmed: true,
			userId: "u1",
		});
	});
});
