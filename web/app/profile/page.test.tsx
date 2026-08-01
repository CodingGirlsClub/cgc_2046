import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, cleanup, waitFor, fireEvent, within } from "@testing-library/react";
import ProfilePage from "./page";
import { MOCK_CURRENT_PROFILE } from "@/lib/profile";
import { MOCK_WORKSPACES } from "@/lib/workspaces";

/**
 * 个人资料页测试（#69）。
 * mock：useRouter（next/navigation）、isAuthenticated（lib/auth）、
 * fetchCurrentProfile/fetchProfileRoleSummary/updateCurrentProfile（lib/profile）。
 */

const { router } = vi.hoisted(() => ({ router: { push: vi.fn(), replace: vi.fn() } }));
const { replace } = router;
const { isAuthenticated, clearAuthToken } = vi.hoisted(() => ({
  isAuthenticated: vi.fn(),
  clearAuthToken: vi.fn(),
}));
const { fetchProfile, fetchRoles, updateProfile } = vi.hoisted(() => ({
  fetchProfile: vi.fn(),
  fetchRoles: vi.fn(),
  updateProfile: vi.fn(),
}));

vi.mock("next/navigation", () => ({
  useRouter: () => router,
}));

vi.mock("@/lib/auth", () => ({
  isAuthenticated,
  clearAuthToken,
}));

vi.mock("@/lib/profile", async (importOriginal) => {
  const mod = (await importOriginal()) as Record<string, unknown>;
  return {
    ...mod,
    fetchCurrentProfile: fetchProfile,
    fetchProfileRoleSummary: fetchRoles,
    updateCurrentProfile: updateProfile,
  };
});

/** mock 角色汇总（复用 MOCK_WORKSPACES 的 myRoleNames 语义） */
function mockRoleSummary() {
  return MOCK_WORKSPACES.map((w) => ({
    workspaceId: w.id,
    workspaceSlug: w.slug,
    workspaceName: w.name,
    myRoleNames: w.myRoleNames ?? [],
  }));
}

beforeEach(() => {
  vi.clearAllMocks();
  isAuthenticated.mockReturnValue(true);
  fetchProfile.mockResolvedValue({ ...MOCK_CURRENT_PROFILE });
  fetchRoles.mockResolvedValue(mockRoleSummary());
});

afterEach(cleanup);

describe("/profile 个人资料页 (#69)", () => {
  it("未登录重定向到 /login，不加载资料", async () => {
    isAuthenticated.mockReturnValue(false);
    render(<ProfilePage />);
    await waitFor(() => expect(replace).toHaveBeenCalledWith("/login"));
    expect(fetchProfile).not.toHaveBeenCalled();
  });

  it("查看资料：头像首字母 / 展示名 / email / 平台管理员标记", async () => {
    render(<ProfilePage />);
    // 头像首字母（小美 → 小）
    expect(await screen.findByText("小")).toBeInTheDocument();
    expect(screen.getByTestId("profile-display-name")).toHaveTextContent("小美");
    expect(screen.getByText("xiaomei@example.com")).toBeInTheDocument();
    // 非平台管理员
    expect(screen.getByText("普通用户")).toBeInTheDocument();
    expect(screen.getByText("ID u_0202")).toBeInTheDocument();
  });

  it("角色汇总：展示每个进入的 Workspace + 角色并集徽章", async () => {
    render(<ProfilePage />);
    await waitFor(() => {
      expect(screen.getByText("角色汇总")).toBeInTheDocument();
    });
    // 三个 workspace 都展示
    expect(screen.getByText("CGC 上海分社")).toBeInTheDocument();
    expect(screen.getByText("CGC 线上学院")).toBeInTheDocument();
    expect(screen.getByText("赞助商俱乐部")).toBeInTheDocument();
    // 角色徽章：cgc-shanghai=member、cgc-academy=admin、sponsor-hub=受邀无角色
    const rows = screen.getAllByTestId("role-summary-row");
    expect(rows).toHaveLength(3);
    const shanghai = rows.find((r) => within(r).queryByText("cgc-shanghai"));
    expect(within(shanghai as HTMLElement).getByText(/Member · 成员/)).toBeInTheDocument();
    const academy = rows.find((r) => within(r).queryByText("cgc-academy"));
    expect(within(academy as HTMLElement).getByText(/Admin · 管理员/)).toBeInTheDocument();
    const sponsor = rows.find((r) => within(r).queryByText("cgc-sponsor-hub"));
    expect(within(sponsor as HTMLElement).getByText(/无角色 · 受邀/)).toBeInTheDocument();
    // workspace 链接到对应工作区
    const wsLink = within(academy as HTMLElement).getByRole("link");
    expect(wsLink).toHaveAttribute("href", "/w/cgc-academy");
  });

  it("编辑保存：修改展示名 → 保存 → updateCurrentProfile 被调用且 UI 更新", async () => {
    // 模拟保存后的返回：displayName 更新
    updateProfile.mockResolvedValue({ ...MOCK_CURRENT_PROFILE, displayName: "小美酱" });
    render(<ProfilePage />);
    await waitFor(() => {
      expect(screen.getByTestId("profile-display-name")).toHaveTextContent("小美");
    });
    fireEvent.click(screen.getByRole("button", { name: "编辑资料" }));
    const input = screen.getByTestId("display-name-input");
    expect(input).toHaveValue("小美");
    fireEvent.change(input, { target: { value: "小美酱" } });
    fireEvent.click(screen.getByTestId("save-profile-btn"));
    await waitFor(() => {
      expect(updateProfile).toHaveBeenCalledWith({ displayName: "小美酱" });
    });
    // 保存成功：展示新展示名 + 提示
    await waitFor(() => {
      expect(screen.getByTestId("profile-display-name")).toHaveTextContent("小美酱");
    });
    expect(screen.getByText("资料已保存")).toBeInTheDocument();
    // 退出编辑态：输入框消失
    expect(screen.queryByTestId("display-name-input")).not.toBeInTheDocument();
  });

  it("编辑取消：不调用保存，展示名不变", async () => {
    render(<ProfilePage />);
    await waitFor(() => {
      expect(screen.getByTestId("profile-display-name")).toHaveTextContent("小美");
    });
    fireEvent.click(screen.getByRole("button", { name: "编辑资料" }));
    const input = screen.getByTestId("display-name-input");
    fireEvent.change(input, { target: { value: "不应保存" } });
    fireEvent.click(screen.getByTestId("cancel-edit-btn"));
    expect(updateProfile).not.toHaveBeenCalled();
    expect(screen.getByTestId("profile-display-name")).toHaveTextContent("小美");
    expect(screen.queryByTestId("display-name-input")).not.toBeInTheDocument();
  });

  it("空展示名保存：提示错误且不调用 updateCurrentProfile", async () => {
    render(<ProfilePage />);
    await waitFor(() => {
      expect(screen.getByTestId("profile-display-name")).toHaveTextContent("小美");
    });
    fireEvent.click(screen.getByRole("button", { name: "编辑资料" }));
    fireEvent.change(screen.getByTestId("display-name-input"), { target: { value: "   " } });
    fireEvent.click(screen.getByTestId("save-profile-btn"));
    await waitFor(() => {
      expect(screen.getByText("展示名不能为空")).toBeInTheDocument();
    });
    expect(updateProfile).not.toHaveBeenCalled();
  });

  it("双主题：使用 l-* 类 + CSS 变量 token（bg-canvas/bg-card/text-ink 等）", async () => {
    render(<ProfilePage />);
    await waitFor(() => {
      expect(screen.getByTestId("profile-card")).toBeInTheDocument();
    });
    // 页面容器使用主题 token 类
    const page = screen.getByTestId("profile-card").closest(".bg-canvas");
    expect(page).not.toBeNull();
    // 卡片使用 bg-card
    expect(screen.getByTestId("profile-card").className).toContain("bg-card");
    // 展示名使用 l-h3
    expect(screen.getByTestId("profile-display-name").className).toContain("l-h3");
    // 编辑按钮使用 l-btn-outline
    expect(screen.getByRole("button", { name: "编辑资料" }).className).toContain("l-btn-outline");
    // 进入编辑态：保存按钮使用 l-btn-primary、input 使用 l-input
    fireEvent.click(screen.getByRole("button", { name: "编辑资料" }));
    expect(screen.getByTestId("save-profile-btn").className).toContain("l-btn-primary");
    expect(screen.getByTestId("display-name-input").className).toContain("l-input");
  });
});
