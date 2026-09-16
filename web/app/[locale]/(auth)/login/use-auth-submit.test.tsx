import { describe, it, expect, vi, beforeEach } from "vitest";
import { act, waitFor } from "@testing-library/react";
import { renderHook } from "@/test-utils";
import { useAuthSubmit } from "./use-auth-submit";
import type { AuthSubmitPayload } from "./auth-form";

// vi.mock 工厂会被提升（hoist），mock 函数必须用 vi.hoisted 定义
const { push, signInMock, resetStore, searchRef } = vi.hoisted(() => ({
	push: vi.fn(),
	signInMock: vi.fn(),
	resetStore: vi.fn(),
	searchRef: { value: "" },
}));

vi.mock("@/lib/apollo-client", () => ({
	client: { resetStore },
}));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useRouter: () => ({ push }),
	usePathname: () => "/login",
	useSearchParams: () => new URLSearchParams(searchRef.value),
}));

vi.mock("@apollo/client/react", async (importOriginal) => {
	const actual = await importOriginal<typeof import("@apollo/client/react")>();
	return {
		...actual,
		useMutation: (doc: unknown) => {
			// TypedDocumentNode 的 String() 是 "[object Object]"，用 definition 名匹配
			const name = (
				doc as { definitions?: Array<{ name?: { value?: string } }> }
			)?.definitions?.[0]?.name?.value;
			if (name === "SignIn") return [signInMock, { loading: false }];
			return [vi.fn(), { loading: false }];
		},
	};
});

const loginPayload: AuthSubmitPayload = {
	login: "a@b.c",
	password: "secret123",
};

describe("useAuthSubmit（login 提交；注册已迁 register-phone-form）", () => {
	beforeEach(() => {
		push.mockClear();
		signInMock.mockReset();
		resetStore.mockClear();
	});

	it("登录成功：跳转首页（token 由后端 httpOnly cookie 交付）", async () => {
		signInMock.mockResolvedValue({
			data: {
				signIn: {
					id: "u1",
					email: "a@b.c",
					isPlatformAdmin: false,
					token: "jwt-login",
				},
			},
		});
		const { result } = renderHook(() => useAuthSubmit());
		await act(() => result.current.onSubmit(loginPayload));
		expect(resetStore).toHaveBeenCalledTimes(1);
		expect(resetStore).toHaveBeenCalledBefore(push);
		expect(push).toHaveBeenCalledWith("/");
		expect(result.current.error).toBeNull();
	});

	it("登录成功且带 next：回跳报名现场（UAT 断链修复；软导航下 useSearchParams 订阅态）", async () => {
		searchRef.value = "?next=%2Fevents%2F1024-changsha-01";
		signInMock.mockResolvedValue({
			data: {
				signIn: {
					id: "u1",
					email: "a@b.c",
					isPlatformAdmin: false,
					token: "jwt-login",
				},
			},
		});
		const { result } = renderHook(() => useAuthSubmit());
		await act(() => result.current.onSubmit(loginPayload));
		expect(push).toHaveBeenCalledWith("/events/1024-changsha-01");
	});

	it("next 跨域输入被拒绝并回退首页", async () => {
		searchRef.value = "?next=https%3A%2F%2Fevil.example%2F";
		signInMock.mockResolvedValue({
			data: {
				signIn: {
					id: "u1",
					email: "a@b.c",
					isPlatformAdmin: false,
					token: "jwt-login",
				},
			},
		});
		const { result } = renderHook(() => useAuthSubmit());
		await act(() => result.current.onSubmit(loginPayload));
		expect(push).toHaveBeenCalledWith("/");
	});

	it("登录失败（ApolloError）：展示后端 message，不跳转", async () => {
		signInMock.mockRejectedValue({
			errors: [
				{ message: "Invalid email or password", code: "authentication_failed" },
			],
		});
		const { result } = renderHook(() => useAuthSubmit());
		await act(() => result.current.onSubmit(loginPayload));
		await waitFor(() =>
			expect(result.current.error).toBe("Invalid email or password"),
		);
		expect(push).not.toHaveBeenCalled();
	});


	it("网络异常：展示兜底文案", async () => {
		signInMock.mockRejectedValue(new Error("fetch failed"));
		const { result } = renderHook(() => useAuthSubmit());
		await act(() => result.current.onSubmit(loginPayload));
		await waitFor(() =>
			expect(result.current.error).toBe("网络异常，请稍后重试"),
		);
		expect(push).not.toHaveBeenCalled();
	});
});
