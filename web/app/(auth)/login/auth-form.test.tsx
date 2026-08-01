import { describe, it, expect, vi, afterEach } from "vitest";
import { render, screen, fireEvent, cleanup } from "@testing-library/react";
import AuthForm, { type AuthSubmitPayload } from "./auth-form";

afterEach(cleanup);

describe("AuthForm (#61 登录与注册设计)", () => {
  it("登录模式展示邮箱、密码和进入工作台的 CTA", () => {
    render(<AuthForm mode="login" setMode={() => {}} />);

    expect(screen.getByLabelText("邮箱")).toBeInTheDocument();
    expect(screen.getByLabelText("密码")).toBeInTheDocument();
    expect(screen.queryByLabelText("确认密码")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "登录并进入工作台" })).toBeInTheDocument();
    expect(screen.queryByText("昵称")).not.toBeInTheDocument();
  });

  it("注册模式展示确认密码和密码提示", () => {
    render(<AuthForm mode="register" setMode={() => {}} />);

    expect(screen.getByLabelText("邮箱")).toBeInTheDocument();
    expect(screen.getByLabelText("密码")).toBeInTheDocument();
    expect(screen.getByLabelText("确认密码")).toBeInTheDocument();
    expect(screen.getByPlaceholderText("至少 8 个字符")).toBeInTheDocument();
    expect(screen.getByLabelText("密码强度未设置")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "创建账号并继续" })).toBeInTheDocument();
  });

  it("底部链接可在登录/注册间切换（触发 setMode）", () => {
    const setMode = vi.fn();
    const { rerender } = render(<AuthForm mode="login" setMode={setMode} />);

    fireEvent.click(screen.getByRole("button", { name: "创建账号" }));
    expect(setMode).toHaveBeenCalledWith("register");

    rerender(<AuthForm mode="register" setMode={setMode} />);
    fireEvent.click(screen.getByRole("button", { name: "返回登录" }));
    expect(setMode).toHaveBeenCalledWith("login");
  });

  it("静态阶段（无 onSubmit）提交显示 mock 提示", () => {
    render(<AuthForm mode="login" setMode={() => {}} />);
    fireEvent.change(screen.getByLabelText("邮箱"), { target: { value: "a@b.c" } });
    fireEvent.change(screen.getByLabelText("密码"), { target: { value: "secret" } });
    const form = screen.getByLabelText("密码").closest("form");
    expect(form).not.toBeNull();
    fireEvent.submit(form!);
    expect(screen.getByText(/mock/)).toBeInTheDocument();
  });

  it("提供 onSubmit 时提交邮箱和密码，不再要求昵称", async () => {
    const onSubmit = vi.fn().mockResolvedValue(undefined);
    render(<AuthForm mode="register" onSubmit={onSubmit} />);

    fireEvent.change(screen.getByLabelText("邮箱"), { target: { value: "a@b.c" } });
    fireEvent.change(screen.getByLabelText("密码"), { target: { value: "password" } });
    fireEvent.change(screen.getByLabelText("确认密码"), { target: { value: "password" } });
    fireEvent.click(screen.getByRole("button", { name: "创建账号并继续" }));

    await vi.waitFor(() => expect(onSubmit).toHaveBeenCalledTimes(1));
    const payload = onSubmit.mock.calls[0][0] as AuthSubmitPayload;
    expect(payload).toEqual({ mode: "register", email: "a@b.c", password: "password" });
  });

  it("注册时两次密码不一致不会提交", () => {
    const onSubmit = vi.fn().mockResolvedValue(undefined);
    render(<AuthForm mode="register" onSubmit={onSubmit} />);

    fireEvent.change(screen.getByLabelText("邮箱"), { target: { value: "a@b.c" } });
    fireEvent.change(screen.getByLabelText("密码"), { target: { value: "password" } });
    fireEvent.change(screen.getByLabelText("确认密码"), { target: { value: "different" } });
    fireEvent.click(screen.getByRole("button", { name: "创建账号并继续" }));

    expect(screen.getByRole("alert")).toHaveTextContent("两次输入的密码不一致");
    expect(onSubmit).not.toHaveBeenCalled();
  });

  it("后端错误时展示错误提示（role=alert）", () => {
    render(
      <AuthForm
        mode="login"
        onSubmit={vi.fn()}
        error="Invalid email or password"
      />,
    );
    expect(screen.getByRole("alert")).toHaveTextContent("Invalid email or password");
  });
});
