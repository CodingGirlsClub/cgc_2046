import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { act } from "@testing-library/react";
import { renderHook } from "@/test-utils";
import { usePhoneCode } from "./use-phone-code";

// vi.mock 工厂会被提升（hoist），mock 函数必须用 vi.hoisted 定义
const { push, requestMock, signInMock, resetStore } = vi.hoisted(() => ({
	push: vi.fn(),
	requestMock: vi.fn(),
	signInMock: vi.fn(),
	resetStore: vi.fn().mockResolvedValue(undefined),
}));

vi.mock("@/lib/apollo-client", () => ({
	client: { resetStore },
}));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useRouter: () => ({ push }),
	usePathname: () => "/login",
}));

vi.mock("@apollo/client/react", async (importOriginal) => {
	const actual = await importOriginal<typeof import("@apollo/client/react")>();
	return {
		...actual,
		useMutation: (doc: unknown) => {
			const name = (
				doc as { definitions?: Array<{ name?: { value?: string } }> }
			)?.definitions?.[0]?.name?.value;
			if (name === "RequestPhoneCode") return [requestMock, { loading: false }];
			if (name === "SignInWithPhoneCode") return [signInMock, { loading: false }];
			return [vi.fn(), { loading: false }];
		},
	};
});

describe("usePhoneCode（plan U5.8 / advisor02 M6）", () => {
	beforeEach(() => {
		vi.useFakeTimers();
		push.mockClear();
		requestMock.mockReset();
		signInMock.mockReset();
		resetStore.mockClear();
	});

	afterEach(() => {
		vi.useRealTimers();
	});

	it("sendCode 成功：倒计时从 retryAfterSeconds 递减", async () => {
		requestMock.mockResolvedValue({
			data: { requestPhoneCode: { sent: true, retryAfterSeconds: 60 } },
		});

		const { result } = renderHook(() => usePhoneCode());
		await act(async () => {
			await result.current.sendCode("+8613800138000", "CHANGE_PHONE");
		});

		expect(requestMock).toHaveBeenCalledWith({ variables: { phone: "+8613800138000", purpose: "CHANGE_PHONE" } });
		expect(signInMock).not.toHaveBeenCalled();
		expect(result.current.countdown).toBe(60);
		expect(result.current.error).toBeNull();

		act(() => {
			vi.advanceTimersByTime(1000);
		});
		expect(result.current.countdown).toBe(59);
	});

	it("sendCode 失败（sms_send_failed code）：错误映射 i18n 键", async () => {
		requestMock.mockRejectedValue({
			errors: [{ extensions: { code: "sms_send_failed" } }],
		});

		const { result } = renderHook(() => usePhoneCode());
		await act(async () => {
			await result.current.sendCode("+8613800138000", "CHANGE_PHONE");
		});

		expect(result.current.error).toBe("验证码发送失败，请稍后重试");
		expect(result.current.countdown).toBe(0);
	});

	it("sent:false（SendCloud 投递失败，M4）：不进入倒计时，错误映射", async () => {
		requestMock.mockResolvedValue({
			data: { requestPhoneCode: { sent: false, retryAfterSeconds: 60 } },
		});

		const { result } = renderHook(() => usePhoneCode());
		await act(async () => {
			await result.current.sendCode("+8613800138000", "CHANGE_PHONE");
		});

		expect(result.current.countdown).toBe(0);
		expect(result.current.error).toBe("验证码发送失败，请稍后重试");
	});
});


it("旧微信绑定显式使用 WECHAT_BIND，卸载清理倒计时", async () => {
 vi.useFakeTimers(); requestMock.mockResolvedValue({ data: { requestPhoneCode: { sent: true, retryAfterSeconds: 60 } } });
 const { result, unmount } = renderHook(() => usePhoneCode());
 await act(async () => { await result.current.sendCode("+8613800138000", "WECHAT_BIND"); });
 expect(requestMock).toHaveBeenLastCalledWith({ variables: { phone: "+8613800138000", purpose: "WECHAT_BIND" } });
 expect(vi.getTimerCount()).toBe(1); unmount(); expect(vi.getTimerCount()).toBe(0); vi.useRealTimers();
});
