import { describe, it, expect, vi, afterEach } from "vitest";
import { screen, fireEvent, cleanup } from "@testing-library/react";
import { render } from "@/test-utils";
import AuthForm, { type AuthSubmitPayload } from "./auth-form";

afterEach(cleanup);

describe("AuthForm（login-only：注册已迁 register-phone-form 手机号验证码路径）", () => {
  it("展示手机号/邮箱、密码和进入工作台的 CTA（无注册字段残留）", () => {
    render(<AuthForm onSubmit={vi.fn()} />);

    expect(screen.getByPlaceholderText("手机号或邮箱")).toBeInTheDocument();
    expect(screen.getByPlaceholderText("请输入密码")).toBeInTheDocument();
    expect(screen.queryByPlaceholderText("再次输入密码")).not.toBeInTheDocument();
    expect(screen.queryByPlaceholderText("you@example.com")).not.toBeInTheDocument();
    expect(screen.queryByLabelText("密码强度未设置")).not.toBeInTheDocument();
  });

  it("提交 login 与 password", async () => {
    const onSubmit = vi.fn().mockResolvedValue(undefined);
    render(<AuthForm onSubmit={onSubmit} />);

    fireEvent.change(screen.getByPlaceholderText("手机号或邮箱"), { target: { value: "a@b.c" } });
    fireEvent.change(screen.getByPlaceholderText("请输入密码"), { target: { value: "password" } });
    fireEvent.click(screen.getByRole("button", { name: "登录并进入工作台" }));

    await vi.waitFor(() => expect(onSubmit).toHaveBeenCalledTimes(1));
    const payload = onSubmit.mock.calls[0][0] as AuthSubmitPayload;
    expect(payload).toEqual({ login: "a@b.c", password: "password" });
  });

  it("后端错误时展示错误提示（role=alert）", () => {
    render(
      <AuthForm onSubmit={vi.fn()} error="Invalid email or password" />,
    );
    expect(screen.getByRole("alert")).toHaveTextContent("Invalid email or password");
  });
});
