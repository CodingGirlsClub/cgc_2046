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
	useSearchParams: () => new URLSearchParams(),
}));

afterEach(cleanup);

describe("LoginPage（plan U3 反向断言：登录链路无首公里模态，F2 不被劫持）", () => {
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
});
