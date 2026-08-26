import { describe, it, expect, vi, afterEach } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import LoginPage from "./page";

// 数据层 hook 全部 mock 掉（本测试只关心组件树构成，不关心登录提交逻辑）：
// 分发器零改动的结构性保证 = 首公里邀请模态只挂在工作区概览页（plan U3 Test Scenarios）
vi.mock("./use-auth-submit", () => ({
	useAuthSubmit: () => ({ onSubmit: vi.fn(), busy: false, error: null }),
}));
vi.mock("./use-sms-login", () => ({
	useSmsLogin: () => ({
		sendCode: vi.fn(),
		submit: vi.fn(),
		countdown: 0,
		sending: false,
		busy: false,
		error: null,
		setError: vi.fn(),
	}),
	smsErrorMessage: () => null,
}));
vi.mock("@apollo/client/react", () => ({
	useMutation: () => [vi.fn(), { loading: false }],
}));
vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	notFound: vi.fn(),
	useRouter: () => ({ push: vi.fn(), replace: vi.fn(), refresh: vi.fn() }),
	usePathname: () => "/login",
	useSearchParams: () => searchParams.current,
}));

const searchParams = vi.hoisted(() => ({ current: new URLSearchParams() }));

afterEach(cleanup);

describe("LoginPage（plan U3 反向断言：登录链路无首公里模态，F2 不被劫持）", () => {
	afterEach(() => {
		searchParams.current = new URLSearchParams();
	});

	it("登录页组件树无 onboarding 邀请模态（R3：登录分发不因此功能改变）", () => {
		render(<LoginPage />);

		// 非空树锚点：登录表单确实渲染（断言非空转）
		expect(
			screen.getByPlaceholderText("手机号或邮箱"),
		).toBeInTheDocument();
		// 反向断言：无邀请模态、无任何 role=dialog
		expect(
			screen.queryByTestId("onboarding-invite-overlay"),
		).not.toBeInTheDocument();
		expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
	});

	it("bind_ticket 模式：tabs 隐藏，卡片内渲染「验证手机号」绑定表单", () => {
		searchParams.current = new URLSearchParams({ bind_ticket: "s1" });

		render(<LoginPage />);

		expect(
			screen.getByRole("heading", { name: "验证手机号" }),
		).toBeInTheDocument();
		expect(screen.getByText(/首次使用微信登录/)).toBeInTheDocument();
		// tabs 不在（绑定模式独占主列）
		expect(screen.queryByRole("tab", { name: "密码登录" })).not.toBeInTheDocument();
		expect(screen.queryByRole("tab", { name: "验证码登录" })).not.toBeInTheDocument();
		// 登录表单不在
		expect(
			screen.queryByPlaceholderText("手机号或邮箱"),
		).not.toBeInTheDocument();
		// 微信扫码侧栏仍在（重扫换账号自洽）
		expect(screen.getByPlaceholderText("请输入手机号")).toBeInTheDocument();
	});

	it("无 bind_ticket：正常登录 tabs", () => {
		render(<LoginPage />);

		expect(screen.getByRole("tab", { name: "密码登录" })).toBeInTheDocument();
		expect(screen.getByRole("tab", { name: "验证码登录" })).toBeInTheDocument();
	});
});
