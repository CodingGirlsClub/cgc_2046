import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import type * as ApolloReact from "@apollo/client/react";
import ResetPasswordPage from "./page";

const { resetMock, mutationState } = vi.hoisted(() => ({
  resetMock: vi.fn(),
  mutationState: { loading: false },
}));

vi.mock("@apollo/client/react", async (importOriginal) => {
  const actual = await importOriginal<typeof ApolloReact>();
  return {
    ...actual,
    useMutation: () => [resetMock, mutationState],
  };
});

// 套 AuthShell 后引入 app router 依赖（useAuthSubmit 的 useRouter、壳的
// useSearchParams 与语言切换器）：mock 掉，表单行为不受影响
vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: vi.fn(), replace: vi.fn(), refresh: vi.fn() }),
  useSearchParams: () => null,
  usePathname: () => "/reset-password",
  redirect: vi.fn(),
  permanentRedirect: vi.fn(),
}));

vi.mock("@/components/language-switcher", () => ({
  default: () => null,
}));

afterEach(() => {
  cleanup();
  window.history.replaceState({}, "", "/reset-password");
});

beforeEach(() => {
  resetMock.mockReset();
  mutationState.loading = false;
  window.history.replaceState({}, "", "/reset-password");
});

async function renderWithToken(token = "reset-token-123") {
  window.history.replaceState({}, "", `/reset-password?token=${token}`);
  render(<ResetPasswordPage />);
  await waitFor(() => expect(screen.getByLabelText("新密码")).toBeInTheDocument());
}

describe("ResetPasswordPage", () => {
  it("无 token 显示无效链接态、两个出口且不调用 mutation", async () => {
    render(<ResetPasswordPage />);

    await waitFor(() => {
      expect(screen.getByRole("status")).toHaveTextContent("链接无效或已过期");
    });
    expect(resetMock).not.toHaveBeenCalled();
    expect(screen.getByRole("link", { name: "重新发送重置邮件" })).toHaveAttribute(
      "href",
      "/forgot-password",
    );
    expect(screen.getByRole("link", { name: "返回登录" })).toHaveAttribute("href", "/login");
  });

  it("读取 token 后立即从 URL 清除 token，并设置 no-referrer", async () => {
    await renderWithToken();

    expect(window.location.search).toBe("");
    expect(document.querySelector('meta[name="referrer"]')).toHaveAttribute(
      "content",
      "no-referrer",
    );
  });

  it("有效密码提交成功后显示全端登出告知和登录出口", async () => {
    resetMock.mockResolvedValue({ data: { resetPassword: { ok: true } } });
    await renderWithToken();

    fireEvent.change(screen.getByLabelText("新密码"), {
      target: { value: "brand-new-password" },
    });
    fireEvent.change(screen.getByLabelText("确认新密码"), {
      target: { value: "brand-new-password" },
    });
    fireEvent.click(screen.getByRole("button", { name: "保存新密码" }));

    await waitFor(() => {
      expect(screen.getByRole("status")).toHaveTextContent("所有设备（含小程序）退出登录");
    });
    expect(resetMock).toHaveBeenCalledWith({
      variables: { resetToken: "reset-token-123", password: "brand-new-password" },
    });
    expect(screen.getByRole("link", { name: "去登录" })).toHaveAttribute("href", "/login");
  });

  it("密码不一致或短于 8 位时前端拦截，不消耗 token", async () => {
    await renderWithToken();

    fireEvent.change(screen.getByLabelText("新密码"), {
      target: { value: "short" },
    });
    fireEvent.change(screen.getByLabelText("确认新密码"), {
      target: { value: "different" },
    });
    fireEvent.click(screen.getByRole("button", { name: "保存新密码" }));

    expect(screen.getByRole("alert")).toHaveTextContent("密码至少需要 8 个字符");
    expect(resetMock).not.toHaveBeenCalled();
  });

  it("invalid_reset_token 切换到无效链接态，密码字段错误仍留在表单", async () => {
    resetMock.mockRejectedValue({
      errors: [{ message: "链接无效或已过期", code: "invalid_reset_token" }],
    });
    await renderWithToken();

    fireEvent.change(screen.getByLabelText("新密码"), {
      target: { value: "brand-new-password" },
    });
    fireEvent.change(screen.getByLabelText("确认新密码"), {
      target: { value: "brand-new-password" },
    });
    fireEvent.click(screen.getByRole("button", { name: "保存新密码" }));

    await waitFor(() => {
      expect(screen.getByRole("status")).toHaveTextContent("链接无效或已过期");
    });
    expect(screen.getByRole("link", { name: "重新发送重置邮件" })).toBeInTheDocument();
  });

  it("后端 password 字段错误显示在密码字段附近并保留表单", async () => {
    resetMock.mockRejectedValue({
      errors: [
        {
          message: "密码至少需要 8 个字符",
          code: "invalid_attribute",
          fields: ["password"],
        },
      ],
    });
    await renderWithToken();

    fireEvent.change(screen.getByLabelText("新密码"), {
      target: { value: "brand-new-password" },
    });
    fireEvent.change(screen.getByLabelText("确认新密码"), {
      target: { value: "brand-new-password" },
    });
    fireEvent.click(screen.getByRole("button", { name: "保存新密码" }));

    await waitFor(() => {
      expect(screen.getByRole("alert")).toHaveTextContent("密码至少需要 8 个字符");
    });
    expect(screen.getByLabelText("新密码")).toHaveAttribute(
      "aria-describedby",
      "reset-password-error",
    );
    expect(screen.getByLabelText("新密码")).toHaveAttribute("aria-invalid", "true");
  });
});
