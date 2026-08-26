import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { act, fireEvent, screen, cleanup, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import RegisterPhoneForm from "./register-phone-form";

const { push, signUpMock, resetStore, sendCode } = vi.hoisted(() => ({
	push: vi.fn(),
	signUpMock: vi.fn(),
	resetStore: vi.fn().mockResolvedValue(undefined),
	sendCode: vi.fn(),
}));

vi.mock("@/lib/apollo-client", () => ({
	client: { resetStore },
}));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	notFound: vi.fn(),
	useRouter: () => ({ push }),
	usePathname: () => "/register",
	useSearchParams: () => new URLSearchParams(),
}));

vi.mock("@apollo/client/react", async (importOriginal) => {
	const actual = await importOriginal<typeof import("@apollo/client/react")>();
	return {
		...actual,
		useMutation: (doc: unknown) => {
			const name = (
				doc as { definitions?: Array<{ name?: { value?: string } }> }
			)?.definitions?.[0]?.name?.value;
			if (name === "SignUpWithPhone") return [signUpMock, { loading: false }];
			if (name === "RequestPhoneCode") return [sendCode, { loading: false }];
			return [vi.fn(), { loading: false }];
		},
	};
});

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
}));

function fillValidForm() {
	fireEvent.change(screen.getByPlaceholderText("请输入手机号"), {
		target: { value: "13800138000" },
	});
	fireEvent.change(screen.getByPlaceholderText("6 位验证码"), {
		target: { value: "123456" },
	});
	fireEvent.change(screen.getByPlaceholderText("请输入密码"), {
		target: { value: "sup3r-secret-password" },
	});
	fireEvent.change(screen.getByPlaceholderText("再次输入密码"), {
		target: { value: "sup3r-secret-password" },
	});
}

afterEach(cleanup);

describe("RegisterPhoneForm（手机号注册：验证码 + 密码）", () => {
	beforeEach(() => {
		push.mockClear();
		signUpMock.mockReset();
	});

	it("渲染：手机号 + 验证码（+发送）+ 密码 + 确认密码 + 强度条 + CTA，无邮箱字段", () => {
		render(<RegisterPhoneForm />);

		expect(screen.getByPlaceholderText("请输入手机号")).toBeInTheDocument();
		expect(screen.getByPlaceholderText("6 位验证码")).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "发送验证码" })).toBeInTheDocument();
		expect(screen.getByPlaceholderText("请输入密码")).toBeInTheDocument();
		expect(screen.getByPlaceholderText("再次输入密码")).toBeInTheDocument();
		expect(screen.getByLabelText("密码强度未设置")).toBeInTheDocument();
		expect(
			screen.getByRole("button", { name: "创建账号并继续" }),
		).toBeInTheDocument();
		expect(screen.queryByPlaceholderText("you@example.com")).not.toBeInTheDocument();
	});

	it("提交成功：signUpWithPhone 带手机/码/密码，resetStore 后跳转", async () => {
		signUpMock.mockResolvedValue({
			data: {
				signUpWithPhone: {
					result: { id: "u1", email: null, isPlatformAdmin: false },
					errors: [],
				},
			},
		});

		render(<RegisterPhoneForm />);

		await act(async () => {
			fillValidForm();
		});
		fireEvent.click(screen.getByRole("button", { name: "创建账号并继续" }));

		await waitFor(() => {
			expect(signUpMock).toHaveBeenCalledWith({
				variables: {
					input: { phone: "13800138000", code: "123456", password: "sup3r-secret-password" },
				},
			});
		});
		await waitFor(() => {
			expect(resetStore).toHaveBeenCalledTimes(1);
			expect(push).toHaveBeenCalledWith("/");
		});
	});

	it("两次密码不一致：不提交，提示错误", async () => {
		render(<RegisterPhoneForm />);

		await act(async () => {
			fillValidForm();
		});
		fireEvent.change(screen.getByPlaceholderText("再次输入密码"), {
			target: { value: "different-pass" },
		});
		fireEvent.click(screen.getByRole("button", { name: "创建账号并继续" }));

		expect(screen.getByRole("alert")).toHaveTextContent("两次输入的密码不一致");
		expect(signUpMock).not.toHaveBeenCalled();
	});

	it("已注册手机号：phone_already_registered 映射文案", async () => {
		signUpMock.mockRejectedValue({
			errors: [{ extensions: { code: "phone_already_registered" } }],
		});

		render(<RegisterPhoneForm />);

		await act(async () => {
			fillValidForm();
		});
		fireEvent.click(screen.getByRole("button", { name: "创建账号并继续" }));

		await waitFor(() => {
			expect(screen.getByRole("alert")).toHaveTextContent(
				"该手机号已注册，请直接登录",
			);
		});
	});

	it("错码：invalid_or_expired_code 映射文案", async () => {
		signUpMock.mockRejectedValue({
			errors: [{ extensions: { code: "invalid_or_expired_code" } }],
		});

		render(<RegisterPhoneForm />);

		await act(async () => {
			fillValidForm();
		});
		fireEvent.click(screen.getByRole("button", { name: "创建账号并继续" }));

		await waitFor(() => {
			expect(screen.getByRole("alert")).toHaveTextContent("验证码错误或已过期");
		});
	});

	it("result null + errors：通用重试提示", async () => {
		signUpMock.mockResolvedValue({
			data: {
				signUpWithPhone: {
					result: null,
					errors: [{ message: "Registration failed", code: "registration_failed" }],
				},
			},
		});

		render(<RegisterPhoneForm />);

		await act(async () => {
			fillValidForm();
		});
		fireEvent.click(screen.getByRole("button", { name: "创建账号并继续" }));

		await waitFor(() => {
			expect(screen.getByRole("alert")).toHaveTextContent("注册失败，请稍后重试");
		});
	});

	it("短密码：不提交", async () => {
		render(<RegisterPhoneForm />);

		await act(async () => {
			fireEvent.change(screen.getByPlaceholderText("请输入手机号"), {
				target: { value: "13800138000" },
			});
			fireEvent.change(screen.getByPlaceholderText("6 位验证码"), {
				target: { value: "123456" },
			});
			fireEvent.change(screen.getByPlaceholderText("请输入密码"), {
				target: { value: "short" },
			});
			fireEvent.change(screen.getByPlaceholderText("再次输入密码"), {
				target: { value: "short" },
			});
		});
		fireEvent.click(screen.getByRole("button", { name: "创建账号并继续" }));

    expect(screen.getByRole("alert")).toHaveTextContent("密码长度需为 8-72 字节");
		expect(signUpMock).not.toHaveBeenCalled();
	});
});
