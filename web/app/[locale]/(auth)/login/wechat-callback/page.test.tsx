import { describe, it, expect, vi, beforeEach } from "vitest";
import { act, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import WechatCallbackPage from "./page";

// vi.mock 工厂会被提升（hoist），mock 函数必须用 vi.hoisted 定义
const { push, signInMock, bindMock, resetStore, sendCode } = vi.hoisted(() => ({
	push: vi.fn(),
	signInMock: vi.fn(),
	bindMock: vi.fn(),
	resetStore: vi.fn().mockResolvedValue(undefined),
	sendCode: vi.fn(),
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
	const actual = await importOriginal<typeof import("@apollo/client/react")>();
	return {
		...actual,
		useMutation: (doc: unknown) => {
			const name = (
				doc as { definitions?: Array<{ name?: { value?: string } }> }
			)?.definitions?.[0]?.name?.value;
			if (name === "SignInWithWechat") return [signInMock, { loading: false }];
			if (name === "BindWechatWithPhone") return [bindMock, { loading: false }];
			if (name === "RequestPhoneCode") return [sendCode, { loading: false }];
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
		bindMock.mockReset();
		sendCode.mockReset();
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

	it("NEEDS_BINDING：渲染手机验证码绑定表单", async () => {
		signInMock.mockResolvedValue({
			data: {
				signInWithWechat: { status: "NEEDS_BINDING", bindTicket: "s1" },
			},
		});

		render(<WechatCallbackPage />);

		await waitFor(() => {
			expect(screen.getByLabelText("手机号")).toBeInTheDocument();
			expect(screen.getByLabelText("验证码")).toBeInTheDocument();
			expect(
				screen.getByRole("button", { name: "完成绑定并登录" }),
			).toBeInTheDocument();
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

	it("绑定提交成功：跳转 next", async () => {
		signInMock.mockResolvedValue({
			data: {
				signInWithWechat: { status: "NEEDS_BINDING", bindTicket: "s1" },
			},
		});
		bindMock.mockResolvedValue({
			data: {
				bindWechatWithPhone: { id: "u9", email: null, isPlatformAdmin: false },
			},
		});

		render(<WechatCallbackPage />);

		await waitFor(() => {
			expect(screen.getByLabelText("手机号")).toBeInTheDocument();
		});

		await act(async () => {
			screen.getByLabelText("手机号").focus();
		});
		fireEvent.change(screen.getByLabelText("手机号"), {
			target: { value: "13800137000" },
		});
		fireEvent.change(screen.getByLabelText("验证码"), {
			target: { value: "123456" },
		});
		fireEvent.submit(screen.getByLabelText("手机号").closest("form")!);

		await waitFor(() => {
			expect(bindMock).toHaveBeenCalledWith({
				variables: { bindTicket: "s1", phone: "13800137000", code: "123456" },
			});
		});
	});
});

