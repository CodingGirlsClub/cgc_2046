import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, fireEvent, cleanup, waitFor } from "@testing-library/react";
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
  window.history.replaceState({}, "", "/");
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

  it("默认展示侧栏 + active 工作区详情", async () => {
    render(<HomePage />);

    expect(await screen.findByRole("heading", { name: "工作区详情" })).toBeInTheDocument();
    expect(screen.getAllByText("CGC 上海分社")).toHaveLength(2);
    expect(screen.getByText("cgc-shanghai")).toBeInTheDocument();
    expect(screen.getAllByText("开放加入").length).toBeGreaterThanOrEqual(1);
    expect(screen.getByText("最近动态")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /进入工作台/ })).toHaveAttribute("href", "/w/cgc-shanghai");
    expect(screen.getByRole("link", { name: /成员与角色/ })).toHaveAttribute("href", "/w/cgc-shanghai/members");
  });

  it("点击侧栏工作区后，详情区跟随切换", async () => {
    render(<HomePage />);
    await screen.findByText("最近动态");

    fireEvent.click(screen.getByRole("button", { name: /CGC 线上学院/ }));
    expect(screen.getAllByText("CGC 线上学院")).toHaveLength(2);
    expect(screen.getAllByText("申请制").length).toBeGreaterThanOrEqual(1);
    expect(screen.getByRole("link", { name: /进入工作台/ })).toHaveAttribute("href", "/w/cgc-academy");
  });

  it("选择 invited workspace：展示待凭据状态，不显示进入入口", async () => {
    render(<HomePage />);
    await screen.findByText("最近动态");

    fireEvent.click(screen.getByRole("button", { name: /赞助商俱乐部/ }));
    expect(screen.getAllByText("待凭据加入").length).toBeGreaterThanOrEqual(2);
    expect(screen.getByText("邀请制")).toBeInTheDocument();
    expect(screen.queryByRole("link", { name: /进入工作台/ })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "输入邀请凭据" })).toBeDisabled();
  });

  it("角色标签复用共享 ROLE_LABEL：tutor/volunteer/learner 渲染规范名（P2-3）", async () => {
    fetchMyWorkspaces.mockResolvedValue([
      {
        id: "ws_roles",
        slug: "roles-demo",
        name: "角色演示工作区",
        joinPolicy: "open",
        sponsorshipEnabled: true,
        myRoleNames: ["tutor", "volunteer", "learner"],
        roles: ["tutor", "volunteer", "learner"],
        membershipStatus: "active",
      },
    ]);
    render(<HomePage />);

    expect(await screen.findByText("Tutor / Volunteer / Learner")).toBeInTheDocument();
    expect(screen.queryByText("tutor")).not.toBeInTheDocument();
    expect(screen.queryByText("volunteer")).not.toBeInTheDocument();
    expect(screen.queryByText("learner")).not.toBeInTheDocument();
  });

  it("真实模式：active / pending 状态跟随侧栏选择", async () => {
    fetchMyWorkspaces.mockResolvedValue([
      {
        id: "ws_real_a",
        slug: "real-a",
        name: "真实工作区 A",
        joinPolicy: "open",
        sponsorshipEnabled: true,
        myRoleNames: ["owner"],
        roles: ["owner"],
        membershipStatus: "active",
      },
      {
        id: "ws_real_b",
        slug: "real-b",
        name: "真实工作区 B",
        joinPolicy: "request",
        sponsorshipEnabled: true,
        myRoleNames: ["member"],
        roles: ["member"],
        membershipStatus: "active",
      },
      {
        id: "ws_real_c",
        slug: "real-c",
        name: "真实工作区 C",
        joinPolicy: "request",
        sponsorshipEnabled: true,
        myRoleNames: [],
        roles: [],
        myMembershipId: "wm_p",
        membershipStatus: "pending",
      },
    ]);

    render(<HomePage />);
    expect(await screen.findByText("你加入了 2 个工作区 · 1 个待处理")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /进入工作台/ })).toHaveAttribute("href", "/w/real-a");

    fireEvent.click(screen.getByRole("button", { name: /真实工作区 C/ }));
    expect(screen.getByText("申请进度")).toBeInTheDocument();
    expect(screen.getAllByText("申请审批中").length).toBeGreaterThanOrEqual(2);
    expect(screen.queryByRole("link", { name: /进入工作台/ })).not.toBeInTheDocument();
  });

  it("view=grid：展示首次登录卡片网格，只有 active 可进入", async () => {
    window.history.replaceState({}, "", "/?view=grid");
    fetchMyWorkspaces.mockResolvedValue([
      { ...MOCK_WORKSPACES[0], name: "上海 Coding Girls Club", slug: "shanghai-cgc", membershipStatus: "active" },
      { ...MOCK_WORKSPACES[1], name: "北京 Women in AI", slug: "beijing-wai", membershipStatus: "pending", myRoleNames: [], roles: [] },
      { ...MOCK_WORKSPACES[2], name: "杭州创客空间", slug: "hangzhou-makers", membershipStatus: "invited" },
    ]);
    render(<HomePage />);

    expect(await screen.findByRole("heading", { name: "选择你的工作区" })).toBeInTheDocument();
    expect(screen.getAllByText("active")).toHaveLength(1);
    expect(screen.getByText("pending")).toBeInTheDocument();
    expect(screen.getByText("invited")).toBeInTheDocument();
    expect(screen.getAllByRole("link", { name: "进入工作台" })).toHaveLength(1);
    expect(screen.getByRole("button", { name: /发现 \/ 申请加入新工作区/ })).toBeInTheDocument();
  });

  it("退出登录：清 token 并跳转 /login", async () => {
    render(<HomePage />);
    const signOut = await screen.findByRole("button", { name: "退出登录" });
    fireEvent.click(signOut);
    expect(clearAuthToken).toHaveBeenCalledTimes(1);
    expect(push).toHaveBeenCalledWith("/login");
  });

  it("提供个人资料入口链接到 /profile (#69)", async () => {
    render(<HomePage />);
    const entry = await screen.findByTestId("profile-entry");
    expect(entry).toHaveAttribute("href", "/profile");
    expect(await screen.findByText("小美")).toBeInTheDocument();
  });
});
