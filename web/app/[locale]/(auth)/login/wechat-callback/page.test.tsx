import { describe, it, expect, vi, beforeEach } from "vitest";
import { screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import type * as ApolloReact from "@apollo/client/react";
import WechatCallbackPage from "./page";

// vi.mock 工厂会被提升（hoist），mock 函数必须用 vi.hoisted 定义
const { push, signInMock, resetStore } = vi.hoisted(() => ({
	push: vi.fn(),
	signInMock: vi.fn(),
	resetStore: vi.fn().mockResolvedValue(undefined),
}));

const searchParams = vi.hoisted(() => ({ current: new URLSearchParams() }));

vi.mock("@/lib/apollo-client", () => ({
	client: { resetStore },
}));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useRouter: () => ({ push }),
	usePathname: () => "/login/wechat-callback",
	useSearchParams: () => searchParams.current,
}));

vi.mock("@apollo/client/react", async (importOriginal) => {
	const actual = await importOriginal<typeof ApolloReact>();
	return {
		...actual,
		useMutation: (doc: unknown) => {
			const name = (
				doc as { definitions?: Array<{ name?: { value?: string } }> }
			)?.definitions?.[0]?.name?.value;
			if (name === "SignInWithWechat") return [signInMock, { loading: false }];
			return [vi.fn(), { loading: false }];
		},
	};
});

function setParams(params: Record<string, string>) {
	searchParams.current = new URLSearchParams(params);
}

describe("wechat-callback（plan U5.8 / advisor02 M6）", () => {
	beforeEach(() => {
		push.mockClear();
		signInMock.mockReset();
		setParams({ code: "c1", state: "s1" });
	});

	it("SIGNED_IN：resetStore 后跳转（?next= 同源透传）", async () => {
		setParams({ code: "c1", state: "s1", next: "/orders/9" });
		signInMock.mockResolvedValue({
			data: { signInWithWechat: { status: "SIGNED_IN", bindTicket: null } },
		});

		render(<WechatCallbackPage />);

		await waitFor(() => {
			expect(resetStore).toHaveBeenCalledTimes(1);
			expect(push).toHaveBeenCalledWith("/orders/9");
		});
	});

	it("NEEDS_BINDING：跳转登录页绑定模式（bind_ticket/next 透传）", async () => {
		setParams({ code: "c1", state: "s1", next: "/orders/9" });
		signInMock.mockResolvedValue({
			data: {
				signInWithWechat: { status: "NEEDS_BINDING", bindTicket: "s1" },
			},
		});

		render(<WechatCallbackPage />);

		await waitFor(() => {
			expect(push).toHaveBeenCalledWith(
				"/login?bind_ticket=s1&next=%2Forders%2F9",
			);
		});
	});

	it("NEEDS_BINDING 无 next：跳转仅带 bind_ticket", async () => {
		signInMock.mockResolvedValue({
			data: {
				signInWithWechat: { status: "NEEDS_BINDING", bindTicket: "s1" },
			},
		});

		render(<WechatCallbackPage />);

		await waitFor(() => {
			expect(push).toHaveBeenCalledWith("/login?bind_ticket=s1");
		});
	});

	it("失败：错误提示 + 返回登录链接", async () => {
		signInMock.mockResolvedValue({
			data: { signInWithWechat: null },
		});

		render(<WechatCallbackPage />);

		await waitFor(() => {
			expect(screen.getByText("微信登录失败，请重试")).toBeInTheDocument();
			expect(screen.getByRole("link", { name: "返回登录" })).toHaveAttribute(
				"href",
				"/login",
			);
		});
	});

	it("缺 code/state 参数：missingParams 错误", async () => {
		setParams({});

		render(<WechatCallbackPage />);

		await waitFor(() => {
			expect(
				screen.getByText("缺少微信回调参数，请重新扫码"),
			).toBeInTheDocument();
		});
		expect(signInMock).not.toHaveBeenCalled();
	});
});
