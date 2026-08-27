import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { act, fireEvent, screen, cleanup, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import { PhoneBindingSection } from "./phone-binding-section";

const mocks = vi.hoisted(() => ({
	updatePhone: vi.fn(),
	refetch: vi.fn().mockResolvedValue(undefined),
	sendCode: vi.fn().mockResolvedValue(true),
	setSendError: vi.fn(),
	state: {
		myPhone: "+86155****3094" as string | null,
		loading: false,
		error: null as Error | null,
		countdown: 0,
		sending: false,
	},
}));

vi.mock("@apollo/client/react", async (importOriginal) => {
	const actual = await importOriginal<typeof import("@apollo/client/react")>();
	const docName = (doc: unknown) =>
		(
			doc as { definitions?: Array<{ name?: { value?: string } }> }
		)?.definitions?.[0]?.name?.value;
	return {
		...actual,
		useQuery: (doc: unknown) => {
			if (docName(doc) === "MyPhone") {
				return {
					data:
						mocks.state.loading || mocks.state.error
							? undefined
							: { myPhone: mocks.state.myPhone },
					loading: mocks.state.loading,
					error: mocks.state.error ?? undefined,
					refetch: mocks.refetch,
				};
			}
			return { data: undefined, loading: false, refetch: vi.fn() };
		},
		useMutation: (doc: unknown) => {
			if (docName(doc) === "UpdateMyPhone") {
				return [mocks.updatePhone, { loading: false }];
			}
			return [vi.fn(), { loading: false }];
		},
	};
});

vi.mock("@/app/[locale]/(auth)/login/use-sms-login", () => ({
	useSmsLogin: () => ({
		sendCode: mocks.sendCode,
		submit: vi.fn(),
		countdown: mocks.state.countdown,
		sending: mocks.state.sending,
		busy: false,
		error: null,
		setError: mocks.setSendError,
	}),
}));

afterEach(cleanup);

function openForm() {
	render(<PhoneBindingSection />);
	fireEvent.click(
		screen.getByRole("button", { name: mocks.state.myPhone ? "修改" : "绑定" }),
	);
}

function fillForm(phone = "15578793094", code = "123456") {
	fireEvent.change(screen.getByPlaceholderText("请输入手机号"), {
		target: { value: phone },
	});
	fireEvent.change(screen.getByPlaceholderText("6 位验证码"), {
		target: { value: code },
	});
}

describe("PhoneBindingSection（设置页绑定/换绑手机号）", () => {
	beforeEach(() => {
		mocks.state.myPhone = "+86155****3094";
		mocks.state.loading = false;
		mocks.state.error = null;
		mocks.state.countdown = 0;
		mocks.state.sending = false;
		mocks.updatePhone.mockReset();
		mocks.refetch.mockClear();
		mocks.sendCode.mockClear();
	});

	it("绑定态：展示掩码手机号 + 修改按钮", () => {
		render(<PhoneBindingSection />);

		expect(screen.getByTestId("phone-binding-section")).toBeInTheDocument();
		expect(screen.getByText("+86155****3094")).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "修改" })).toBeInTheDocument();
	});

	it("未绑定态：展示「未绑定」+ 绑定按钮", () => {
		mocks.state.myPhone = null;
		render(<PhoneBindingSection />);

		expect(screen.getByText("未绑定")).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "绑定" })).toBeInTheDocument();
	});

	it("loading：渲染骨架占位，不显示「未绑定」也不出现绑定/修改按钮", () => {
		mocks.state.loading = true;
		const { container } = render(<PhoneBindingSection />);

		expect(container.querySelector(".settings-skeleton")).toBeInTheDocument();
		expect(screen.queryByText("未绑定")).not.toBeInTheDocument();
		expect(
			screen.queryByRole("button", { name: "绑定" }),
		).not.toBeInTheDocument();
		expect(
			screen.queryByRole("button", { name: "修改" }),
		).not.toBeInTheDocument();
	});

	it("error：错误态 + 重试按钮（点击调 refetch），不显示「未绑定」", async () => {
		mocks.state.error = new Error("network down");
		render(<PhoneBindingSection />);

		expect(screen.getByRole("alert")).toHaveTextContent("加载手机号失败");
		expect(screen.queryByText("未绑定")).not.toBeInTheDocument();
		expect(
			screen.queryByRole("button", { name: "绑定" }),
		).not.toBeInTheDocument();

		fireEvent.click(screen.getByRole("button", { name: "重试" }));

		await waitFor(() => {
			expect(mocks.refetch).toHaveBeenCalledTimes(1);
		});
	});

	it("发码：sendCode 以 CHANGE_PHONE purpose 调用", async () => {
		openForm();

		await act(async () => {
			fireEvent.change(screen.getByPlaceholderText("请输入手机号"), {
				target: { value: "15578793094" },
			});
		});
		fireEvent.click(screen.getByRole("button", { name: "发送验证码" }));

		await waitFor(() => {
			expect(mocks.sendCode).toHaveBeenCalledWith("15578793094", "CHANGE_PHONE");
		});
	});

	it("发码倒计时：按钮展示倒计时且禁用", () => {
		mocks.state.countdown = 60;
		openForm();

		const sendButton = screen.getByRole("button", { name: "60s 后重发" });
		expect(sendButton).toBeDisabled();
	});

	it("成功路径：updateMyPhone 提交后 refetch MY_PHONE 并提示已更新", async () => {
		mocks.updatePhone.mockResolvedValue({
			data: { updateMyPhone: { id: "u1" } },
		});

		openForm();
		await act(async () => {
			fillForm();
		});
		fireEvent.click(screen.getByRole("button", { name: "保存更改" }));

		await waitFor(() => {
			expect(mocks.updatePhone).toHaveBeenCalledWith({
				variables: { phone: "15578793094", code: "123456" },
			});
		});
		await waitFor(() => {
			expect(mocks.refetch).toHaveBeenCalledTimes(1);
			expect(screen.getByRole("status")).toHaveTextContent("手机号已更新");
		});
		// 成功后收起表单回到展示态
		expect(screen.getByRole("button", { name: "修改" })).toBeInTheDocument();
	});

	it("他人占用：phone_already_registered 映射换绑文案（非注册文案）", async () => {
		mocks.updatePhone.mockRejectedValue({
			errors: [{ extensions: { code: "phone_already_registered" } }],
		});

		openForm();
		await act(async () => {
			fillForm();
		});
		fireEvent.click(screen.getByRole("button", { name: "保存更改" }));

		await waitFor(() => {
			expect(screen.getByRole("alert")).toHaveTextContent(
				"该手机号已被其他账号使用",
			);
		});
	});

	it("错码：invalid_or_expired_code 映射文案", async () => {
		mocks.updatePhone.mockRejectedValue({
			errors: [{ extensions: { code: "invalid_or_expired_code" } }],
		});

		openForm();
		await act(async () => {
			fillForm();
		});
		fireEvent.click(screen.getByRole("button", { name: "保存更改" }));

		await waitFor(() => {
			expect(screen.getByRole("alert")).toHaveTextContent("验证码错误或已过期");
		});
	});
});
