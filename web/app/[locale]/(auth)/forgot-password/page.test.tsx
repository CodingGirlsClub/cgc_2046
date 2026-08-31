import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import ForgotPasswordPage from "./page";

const { requestMock, mutationState } = vi.hoisted(() => ({
  requestMock: vi.fn(),
  mutationState: { loading: false },
}));

vi.mock("@apollo/client/react", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@apollo/client/react")>();
  return {
    ...actual,
    useMutation: () => [requestMock, mutationState],
  };
});

// 套 AuthShell 后引入 app router 依赖（useAuthSubmit 的 useRouter、壳的
// useSearchParams 与语言切换器）：mock 掉，表单行为不受影响
vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: vi.fn(), replace: vi.fn(), refresh: vi.fn() }),
  useSearchParams: () => null,
  usePathname: () => "/forgot-password",
  redirect: vi.fn(),
  permanentRedirect: vi.fn(),
}));

vi.mock("@/components/language-switcher", () => ({
  default: () => null,
}));

afterEach(cleanup);

beforeEach(() => {
  requestMock.mockReset();
  mutationState.loading = false;
});

describe("ForgotPasswordPage", () => {
  it("提交后显示不区分邮箱是否注册的成功文案，并只提交一次", async () => {
    requestMock.mockResolvedValue({
      data: { requestPasswordReset: { sent: true } },
    });

    render(<ForgotPasswordPage />);
    fireEvent.change(screen.getByLabelText("注册邮箱"), {
      target: { value: " member@example.com " },
    });
    fireEvent.click(screen.getByRole("button", { name: "发送重置邮件" }));

    await waitFor(() => {
      expect(screen.getByRole("status")).toHaveTextContent("如果该邮箱已注册，重置链接已发送");
    });
    expect(requestMock).toHaveBeenCalledWith({
      variables: { email: "member@example.com" },
    });
    expect(screen.queryByLabelText("注册邮箱")).not.toBeInTheDocument();
    expect(screen.getByRole("link", { name: "返回登录" })).toHaveAttribute("href", "/login");
  });

  it("rate_limited 显示限流错误而不是伪装成成功", async () => {
    requestMock.mockRejectedValue({
      errors: [{ message: "请求过于频繁", code: "rate_limited" }],
    });

    render(<ForgotPasswordPage />);
    fireEvent.change(screen.getByLabelText("注册邮箱"), {
      target: { value: "member@example.com" },
    });
    fireEvent.click(screen.getByRole("button", { name: "发送重置邮件" }));

    await waitFor(() => {
      expect(screen.getByRole("alert")).toHaveTextContent("请求过于频繁，请稍后再试");
    });
    expect(screen.queryByText("如果该邮箱已注册，重置链接已发送")).not.toBeInTheDocument();
  });

  it("提交中禁用按钮并暴露 aria-busy", () => {
    mutationState.loading = true;

    render(<ForgotPasswordPage />);

    const button = screen.getByRole("button", { name: "发送中…" });
    expect(button).toBeDisabled();
    expect(button).toHaveAttribute("aria-busy", "true");
  });
});
