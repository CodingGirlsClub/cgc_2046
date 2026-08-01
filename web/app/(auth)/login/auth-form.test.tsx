import { describe, it, expect, vi, afterEach } from "vitest";
import { render, screen, fireEvent, cleanup } from "@testing-library/react";
import AuthForm, { type AuthSubmitPayload } from "./auth-form";

afterEach(cleanup);

describe("AuthForm (#61 静态骨架)", () => {
  it("默认登录模式：显示邮箱/密码，不显示昵称", () => {
    render(<AuthForm mode="login" setMode={() => {}} />);
    expect(screen.getByLabelText("邮箱")).toBeInTheDocument();
    expect(screen.getByLabelText("密码")).toBeInTheDocument();
    expect(screen.queryByLabelText("昵称")).not.toBeInTheDocument();
    // 「登录」tab 与「登录」提交按钮各一个
    expect(screen.getAllByRole("button", { name: "登录" })).toHaveLength(2);
  });

  it("切换到注册模式：出现昵称字段与创建账号按钮", () => {
    render(<AuthForm mode="register" setMode={() => {}} />);
    expect(screen.getByLabelText("昵称")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "创建账号" })).toBeInTheDocument();
  });

  it("底部链接可在登录/注册间切换（触发 setMode）", () => {
    const setMode = vi.fn();
    render(<AuthForm mode="login" setMode={setMode} />);
    fireEvent.click(screen.getByRole("button", { name: "立即注册" }));
    expect(setMode).toHaveBeenCalledWith("register");
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

  it("提供 onSubmit 时提交调用回调并携带表单数据", async () => {
    const onSubmit = vi.fn().mockResolvedValue(undefined);
    render(<AuthForm mode="register" setMode={() => {}} onSubmit={onSubmit} />);
    fireEvent.change(screen.getByLabelText("昵称"), { target: { value: "阿麦" } });
    fireEvent.change(screen.getByLabelText("邮箱"), { target: { value: "a@b.c" } });
    fireEvent.change(screen.getByLabelText("密码"), { target: { value: "secret" } });
    fireEvent.click(screen.getByRole("button", { name: "创建账号" }));
    await vi.waitFor(() => expect(onSubmit).toHaveBeenCalledTimes(1));
    const payload = onSubmit.mock.calls[0][0] as AuthSubmitPayload;
    expect(payload).toMatchObject({
      mode: "register",
      nickname: "阿麦",
      email: "a@b.c",
      password: "secret",
    });
  });

  it("后端错误时展示错误提示（role=alert）", () => {
    render(
      <AuthForm
        mode="login"
        setMode={() => {}}
        onSubmit={vi.fn()}
        error="Invalid email or password"
      />,
    );
    expect(screen.getByRole("alert")).toHaveTextContent("Invalid email or password");
  });
});
