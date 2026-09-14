import { describe, it, expect, vi, afterEach, beforeEach } from "vitest";
import { act, waitFor } from "@testing-library/react";
import { renderHook } from "@/test-utils";
import { useAuthSubmit } from "./use-auth-submit";
import type { AuthSubmitPayload } from "./auth-form";

// vi.mock 工厂会被提升（hoist），mock 函数必须用 vi.hoisted 定义
const { push, signInMock, resetStore } = vi.hoisted(() => ({
	push: vi.fn(),
	signInMock: vi.fn(),
	resetStore: vi.fn(),
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

describe("登录后跳转：OAuth 授权页回跳（后端 return_to）", () => {
	const origin = "http://localhost:3000";
	const originalLocation = window.location;

	// jsdom 的 location.assign 未实现（会打印 Not implemented 且不可断言）：
	// 按 lib/theme-sync.test.tsx 先例替换 location 对象
	function stubLocation(search: string) {
		const assign = vi.fn();
		Object.defineProperty(window, "location", {
			value: { ...window.location, origin, search, assign },
			configurable: true,
		});
		return assign;
	}

	beforeEach(() => {
		push.mockClear();
		signInMock.mockReset();
		signInMock.mockResolvedValue({
			data: { signIn: { id: "u1", email: "a@b.c", isPlatformAdmin: false, token: "jwt" } },
		});
	});

	afterEach(() => {
		Object.defineProperty(window, "location", {
			value: originalLocation,
			configurable: true,
		});
	});

	it("return_to 指向授权页 → 整页跳转（Next 客户端路由不承载 /oauth/*）", async () => {
		const assign = stubLocation(
			"?return_to=%2Foauth%2Fauthorize%3Fclient_id%3Dabc%26state%3Ds1",
		);

		const { result } = renderHook(() => useAuthSubmit());
		await act(() => result.current.onSubmit(loginPayload));

		expect(assign).toHaveBeenCalledWith("/oauth/authorize?client_id=abc&state=s1");
		expect(push).not.toHaveBeenCalled();
	});

	it("站内 next → 客户端路由（既有行为不回归）", async () => {
		const assign = stubLocation("?next=%2Forders%2Fnew");

		const { result } = renderHook(() => useAuthSubmit());
		await act(() => result.current.onSubmit(loginPayload));

		expect(push).toHaveBeenCalledWith("/orders/new");
		expect(assign).not.toHaveBeenCalled();
	});

	it("跨域 return_to → 回退 /（同源校验仍生效）", async () => {
		const assign = stubLocation("?return_to=https%3A%2F%2Fevil.example%2Foauth%2Fauthorize");

		const { result } = renderHook(() => useAuthSubmit());
		await act(() => result.current.onSubmit(loginPayload));

		expect(push).toHaveBeenCalledWith("/");
		expect(assign).not.toHaveBeenCalled();
	});
});
