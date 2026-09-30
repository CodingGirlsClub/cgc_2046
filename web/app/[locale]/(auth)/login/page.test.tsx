import { describe, it, expect, vi, afterEach } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import LoginPage from "./page";

vi.mock("./use-auth-submit", () => ({
  useAuthSubmit: () => ({ onSubmit: vi.fn(), busy: false, error: null }),
}));
vi.mock("@/lib/use-phone-code", () => ({
  usePhoneCode: () => ({ sendCode: vi.fn(), submit: vi.fn(), countdown: 0, sending: false, busy: false, error: null, setError: vi.fn() }),
  smsErrorMessage: () => null,
}));
vi.mock("./wechat-qr-panel", () => ({
  default: () => <div data-testid="wechat-request">小程序登录请求</div>,
}));
vi.mock("@apollo/client/react", () => ({
  useMutation: () => [vi.fn(), { loading: false }],
}));
vi.mock("next/navigation", () => ({
  redirect: vi.fn(), permanentRedirect: vi.fn(), notFound: vi.fn(),
  useRouter: () => ({ push: vi.fn(), replace: vi.fn(), refresh: vi.fn() }),
  usePathname: () => "/login", useSearchParams: () => searchParams.current,
}));
const searchParams = vi.hoisted(() => ({ current: new URLSearchParams() }));
afterEach(() => { cleanup(); searchParams.current = new URLSearchParams(); });

describe("统一 Web 登录／注册入口", () => {
  it("微信为主入口，密码仅供已有账号；没有短信登录或注册表单", () => {
    render(<LoginPage />);
    const headings = screen.getAllByRole("heading", { level: 2 });
    expect(headings.map(h => h.textContent)).toEqual(["微信快捷登录／注册", "账号密码登录"]);
    expect(screen.getByTestId("wechat-request")).toBeInTheDocument();
    expect(screen.getByPlaceholderText("手机号或邮箱")).toBeInTheDocument();
    expect(screen.getByText("已有账号并设置过密码的用户可使用。")).toBeInTheDocument();
    expect(screen.queryByRole("tab", { name: "验证码登录" })).not.toBeInTheDocument();
    expect(screen.queryByPlaceholderText("6 位验证码")).not.toBeInTheDocument();
    expect(screen.queryByRole("link", { name: "创建账号" })).not.toBeInTheDocument();
    expect(screen.getByRole("link", { name: "忘记密码？" })).toBeInTheDocument();
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("密码输入不会抢走初始焦点，首次使用明确指向微信入口", () => {
    render(<LoginPage />);
    expect(screen.getByPlaceholderText("手机号或邮箱")).not.toHaveFocus();
    expect(screen.getByText("首次使用请通过微信快捷注册。")).toBeInTheDocument();
  });

  it("旧 bind_ticket 会话仍可绑定，但不启动新的小程序登录请求", () => {
    searchParams.current = new URLSearchParams({ bind_ticket: "s1", next: "/join/ws1" });
    render(<LoginPage />);
    expect(screen.getByRole("heading", { name: "验证手机号" })).toBeInTheDocument();
    expect(screen.getByPlaceholderText("请输入手机号")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "完成绑定并登录" })).toBeInTheDocument();
    expect(screen.queryByTestId("wechat-request")).not.toBeInTheDocument();
    expect(screen.queryByPlaceholderText("手机号或邮箱")).not.toBeInTheDocument();
    expect(screen.queryByRole("link", { name: "创建账号" })).not.toBeInTheDocument();
  });
});
