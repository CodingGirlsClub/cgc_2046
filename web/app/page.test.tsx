import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, fireEvent, cleanup, waitFor, within } from "@testing-library/react";
import HomePage from "./page";
import { MOCK_WORKSPACES } from "@/lib/workspaces";

/**
 * 工作台页测试（#63）。
 * mock：useRouter（next/navigation）、isAuthenticated（lib/auth）、fetchMyWorkspaces（lib/workspaces）。
 */

const { push, replace } = vi.hoisted(() => ({ push: vi.fn(), replace: vi.fn() }));
const { isAuthenticated, clearAuthToken } = vi.hoisted(() => ({
  isAuthenticated: vi.fn(),
  clearAuthToken: vi.fn(),
}));
const { fetchMyWorkspaces } = vi.hoisted(() => ({ fetchMyWorkspaces: vi.fn() }));
const { fetchCurrentProfile } = vi.hoisted(() => ({ fetchCurrentProfile: vi.fn() }));

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push, replace }),
}));

vi.mock("@/lib/auth", () => ({
  isAuthenticated,
  clearAuthToken,
}));

vi.mock("@/lib/workspaces", async (importOriginal) => {
  const mod = (await importOriginal()) as Record<string, unknown>;
  return { ...mod, fetchMyWorkspaces };
});

vi.mock("@/lib/profile", async (importOriginal) => {
  const mod = (await importOriginal()) as Record<string, unknown>;
  return { ...mod, fetchCurrentProfile };
});

beforeEach(() => {
  vi.clearAllMocks();
  isAuthenticated.mockReturnValue(true);
  fetchMyWorkspaces.mockResolvedValue(MOCK_WORKSPACES);
  fetchCurrentProfile.mockResolvedValue({
    id: "u_0202",
    email: "xiaomei@example.com",
    displayName: "小美",
    avatarUrl: null,
    isPlatformAdmin: false,
  });
});

afterEach(cleanup);

describe("工作台页 (#63)", () => {
  it("未登录：重定向 /login，不渲染列表", async () => {
    isAuthenticated.mockReturnValue(false);
    render(<HomePage />);
    await waitFor(() => expect(replace).toHaveBeenCalledWith("/login"));
    expect(fetchMyWorkspaces).not.toHaveBeenCalled();
  });

  it("登录后：渲染 workspace 列表（名称/slug/join_policy 标识）", async () => {
    render(<HomePage />);
    expect(await screen.findByText("CGC 上海分社")).toBeInTheDocument();
    expect(screen.getByText("cgc-shanghai")).toBeInTheDocument();
    expect(screen.getByText("CGC 线上学院")).toBeInTheDocument();
    expect(screen.getByText("cgc-academy")).toBeInTheDocument();
    // join_policy 标签
    expect(screen.getByText("公开")).toBeInTheDocument();
    expect(screen.getByText("申请审批")).toBeInTheDocument();
    expect(screen.getByText("仅邀请")).toBeInTheDocument();
    // 赞助入口标识（两个 active 均为已开启，一个关闭）
    expect(screen.getAllByText("赞助入口已开启")).toHaveLength(2);
    expect(screen.getByText("赞助入口关闭")).toBeInTheDocument();
  });

  it("active workspace 提供「进入工作台」链接到 /w/[slug]", async () => {
    render(<HomePage />);
    const links = await screen.findAllByRole("link", { name: /进入工作台/ });
    expect(links.map((l) => l.getAttribute("href"))).toEqual([
      "/w/cgc-shanghai",
      "/w/cgc-academy",
    ]);
  });

  it("非 active workspace（invited）显示待加入状态，不提供进入链接", async () => {
    render(<HomePage />);
    expect(await screen.findByText("待凭据加入")).toBeInTheDocument();
    expect(screen.getAllByRole("link", { name: /进入工作台/ })).toHaveLength(2); // 仅两个 active
  });

  it("退出登录：清 token 并跳转 /login", async () => {
    render(<HomePage />);
    const signOut = await screen.findByRole("button", { name: "退出登录" });
    fireEvent.click(signOut);
    expect(clearAuthToken).toHaveBeenCalledTimes(1);
    expect(push).toHaveBeenCalledWith("/login");
  });

  it("header 提供个人资料入口链接到 /profile (#69)", async () => {
    render(<HomePage />);
    const entry = await screen.findByTestId("profile-entry");
    expect(entry).toHaveAttribute("href", "/profile");
    expect(within(entry).getByText("小美")).toBeInTheDocument();
  });
});
