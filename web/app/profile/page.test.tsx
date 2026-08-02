import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import ProfilePage from "./page";
import { MOCK_PROFILE_PORTFOLIO } from "@/lib/profile";

const { router } = vi.hoisted(() => ({ router: { push: vi.fn(), replace: vi.fn() } }));
const { isAuthenticated, clearAuthToken } = vi.hoisted(() => ({
  isAuthenticated: vi.fn(),
  clearAuthToken: vi.fn(),
}));
const { fetchProfile, fetchRoles, updateProfile } = vi.hoisted(() => ({
  fetchProfile: vi.fn(),
  fetchRoles: vi.fn(),
  updateProfile: vi.fn(),
}));
const { fetchPortfolio, createPortfolio, updatePortfolio, deletePortfolio } = vi.hoisted(() => ({
  fetchPortfolio: vi.fn(),
  createPortfolio: vi.fn(),
  updatePortfolio: vi.fn(),
  deletePortfolio: vi.fn(),
}));

vi.mock("next/navigation", () => ({ useRouter: () => router }));
vi.mock("@/lib/auth", () => ({ isAuthenticated, clearAuthToken }));
vi.mock("@/lib/profile", async (importOriginal) => {
  const mod = (await importOriginal()) as Record<string, unknown>;
  return {
    ...mod,
    fetchCurrentProfile: fetchProfile,
    fetchProfileRoleSummary: fetchRoles,
    updateCurrentProfile: updateProfile,
    fetchPortfolioItems: fetchPortfolio,
    createPortfolioItem: createPortfolio,
    updatePortfolioItem: updatePortfolio,
    deletePortfolioItem: deletePortfolio,
  };
});

const designProfile = () => ({
  id: "u_0201",
  email: "linxi@cgc2046.org",
  displayName: "林溪",
  avatarUrl: null,
  isPlatformAdmin: false,
  location: "上海",
  about: "关注社区学习、AI 教育与开放协作。喜欢把复杂的问题整理成清晰、可执行的课程与活动。",
  skills: ["AI 教育", "课程设计", "社区运营", "Elixir"],
  joinedAt: "2024 年 3 月",
  visibility: "workspace_members" as const,
  memberNumber: "CGC-SH-0018",
  workspaceName: "上海 Coding Girls Club",
  workspaceSlug: "cgc-shanghai",
  workspaceRoles: ["owner", "tutor"] as const,
  portfolio: MOCK_PROFILE_PORTFOLIO.map((item) => ({ ...item })),
});

beforeEach(() => {
  vi.clearAllMocks();
  isAuthenticated.mockReturnValue(true);
  fetchProfile.mockResolvedValue(designProfile());
  fetchPortfolio.mockResolvedValue(designProfile().portfolio);
  fetchRoles.mockResolvedValue([{
    workspaceId: "ws_01",
    workspaceSlug: "cgc-shanghai",
    workspaceName: "上海 Coding Girls Club",
    myRoleNames: ["owner", "tutor"],
  }]);
});

afterEach(() => cleanup());

async function renderReadyProfile() {
  render(<ProfilePage />);
  await screen.findByRole("heading", { name: "我的个人资料" });
  await waitFor(() => expect(screen.queryByTestId("profile-loading")).not.toBeInTheDocument());
}

describe("/profile 个人资料查看与编辑（#69）", () => {
  it("未登录重定向到 /login，且不加载资料", async () => {
    isAuthenticated.mockReturnValue(false);
    render(<ProfilePage />);
    await waitFor(() => expect(router.replace).toHaveBeenCalledWith("/login"));
    expect(fetchProfile).not.toHaveBeenCalled();
  });

  it("查看态按 v3 设计稿渲染摘要、关于我、技能、作品集和 Workspace 身份", async () => {
    await renderReadyProfile();

    expect(screen.getByText("上海 Coding Girls Club")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "我的个人资料" })).toBeInTheDocument();
    expect(screen.getByTestId("profile-display-name")).toHaveTextContent("林溪");
    expect(screen.getAllByText("Owner").length).toBeGreaterThanOrEqual(2);
    expect(screen.getAllByText("Tutor").length).toBeGreaterThanOrEqual(2);
    expect(screen.getByText("上海", { selector: ".profile-summary__meta span" })).toBeInTheDocument();
    expect(screen.getByText("加入于 2024 年 3 月")).toBeInTheDocument();
    expect(screen.getByText("仅当前 Workspace 成员可见")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "关于我" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "技能标签" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "工作区身份" })).toBeInTheDocument();
    expect(screen.getByText("角色并集")).toBeInTheDocument();
    expect(screen.getByText("权限按所有角色并集合并")).toBeInTheDocument();
    expect(screen.getByText("CGC-SH-0018")).toBeInTheDocument();
  });

  it("作品集支持任意数量：首页只预览前三条并显示全量入口", async () => {
    await renderReadyProfile();

    expect(screen.getByTestId("portfolio-card")).toBeInTheDocument();
    expect(screen.getByText("作品集")).toBeInTheDocument();
    expect(screen.getByText("10", { selector: ".profile-count" })).toBeInTheDocument();
    expect(screen.getAllByTestId("portfolio-preview-item")).toHaveLength(3);
    expect(screen.getByTestId("portfolio-all-link")).toHaveTextContent("查看全部 10 个作品");
    expect(screen.getByTestId("portfolio-all-link")).toHaveAttribute("href", "/profile/portfolio");
  });

  it("个人资料导航选中，编辑按钮进入暗色编辑信息架构", async () => {
    await renderReadyProfile();

    const profileNav = screen.getAllByRole("link", { name: "个人资料" }).find((link) => link.getAttribute("aria-current") === "page");
    expect(profileNav).toBeDefined();
    fireEvent.click(screen.getByRole("button", { name: "编辑资料" }));
    expect(screen.getByRole("heading", { name: "编辑个人资料" })).toBeInTheDocument();
    expect(screen.getByTestId("edit-basic-card")).toBeInTheDocument();
    expect(screen.getByTestId("edit-visibility-card")).toBeInTheDocument();
    expect(screen.getByTestId("edit-portfolio-card")).toBeInTheDocument();
    expect(screen.getByTestId("profile-name-input")).toHaveValue("林溪");
    expect(screen.getByTestId("profile-location-input")).toHaveValue("上海");
    expect(screen.getByTestId("profile-about-input")).toHaveValue("关注社区学习、AI 教育与开放协作。喜欢把复杂的问题整理成清晰、可执行的课程与活动。");
    expect(within(screen.getByTestId("edit-visibility-card")).getByText("Owner")).toBeInTheDocument();
    expect(within(screen.getByTestId("edit-visibility-card")).getByText("Tutor")).toBeInTheDocument();
    expect(screen.getByDisplayValue("CGC-SH-0018")).toHaveAttribute("readonly");
    expect(screen.getAllByTestId("portfolio-edit-row")).toHaveLength(2);
    expect(screen.getByRole("button", { name: "展开其余 8 个作品" })).toBeInTheDocument();
  });

  it("编辑态展开全部作品、修改资料并保存，角色仍保持只读（P1 保存全部扩展字段）", async () => {
    updateProfile.mockImplementation(async (input: { displayName: string; avatarUrl?: string | null; location?: string; about?: string; skills?: string[]; visibility?: string }) => ({
      ...designProfile(),
      displayName: input.displayName,
      avatarUrl: input.avatarUrl ?? null,
      location: input.location,
      about: input.about,
      skills: input.skills,
      visibility: input.visibility,
    }));
    await renderReadyProfile();
    fireEvent.click(screen.getByRole("button", { name: "编辑资料" }));
    fireEvent.click(screen.getByRole("button", { name: "展开其余 8 个作品" }));
    expect(screen.getAllByTestId("portfolio-edit-row")).toHaveLength(10);
    fireEvent.change(screen.getByTestId("profile-name-input"), { target: { value: "林溪新" } });
    fireEvent.change(screen.getByTestId("profile-location-input"), { target: { value: "杭州" } });
    fireEvent.change(screen.getByTestId("profile-about-input"), { target: { value: "新的个人简介" } });
    fireEvent.change(screen.getByTestId("profile-visibility-input"), { target: { value: "workspace_public" } });
    fireEvent.click(screen.getByRole("button", { name: "保存更改" }));

    await waitFor(() => expect(updateProfile).toHaveBeenCalledWith({
      displayName: "林溪新",
      avatarUrl: null,
      location: "杭州",
      about: "新的个人简介",
      skills: ["AI 教育", "课程设计", "社区运营", "Elixir"],
      visibility: "workspace_public",
    }));
    expect(await screen.findByRole("heading", { name: "我的个人资料" })).toBeInTheDocument();
    expect(screen.getByTestId("profile-display-name")).toHaveTextContent("林溪新");
    expect(screen.getByText("杭州", { selector: ".profile-summary__meta span" })).toBeInTheDocument();
    expect(screen.getByText("新的个人简介")).toBeInTheDocument();
    expect(screen.getByText("Workspace 内公开")).toBeInTheDocument();
    expect(screen.getByText("资料已保存")).toBeInTheDocument();
    // 作品集未变更：不触发 CRUD，但保存成功后重新拉取
    expect(createPortfolio).not.toHaveBeenCalled();
    expect(updatePortfolio).not.toHaveBeenCalled();
    expect(deletePortfolio).not.toHaveBeenCalled();
    expect(fetchPortfolio).toHaveBeenCalledTimes(2);
    expect(screen.getAllByText("Owner").length).toBeGreaterThanOrEqual(2);
    expect(screen.getAllByText("Tutor").length).toBeGreaterThanOrEqual(2);
  });

  it("编辑态修改/新增/删除作品并保存 → 触发 Portfolio CRUD（P1 真实接线）", async () => {
    updateProfile.mockImplementation(async (input: { displayName: string; avatarUrl?: string | null }) => ({
      ...designProfile(),
      displayName: input.displayName,
      avatarUrl: input.avatarUrl ?? null,
    }));
    await renderReadyProfile();
    fireEvent.click(screen.getByRole("button", { name: "编辑资料" }));
    fireEvent.click(screen.getByRole("button", { name: "展开其余 8 个作品" }));

    // 修改第一行标题
    const firstRow = screen.getAllByTestId("portfolio-edit-row")[0];
    const titleInput = within(firstRow).getAllByRole("textbox")[0];
    fireEvent.change(titleInput, { target: { value: "改名作品" } });
    // 删除第二行
    const secondRow = screen.getAllByTestId("portfolio-edit-row")[1];
    fireEvent.click(within(secondRow).getByRole("button", { name: /删除/ }));
    // 新增一行（展开后新增行可见）
    fireEvent.click(screen.getByRole("button", { name: "添加作品" }));
    const newRow = screen.getAllByTestId("portfolio-edit-row").at(-1) as HTMLElement;
    fireEvent.change(within(newRow).getAllByRole("textbox")[0], { target: { value: "新作品" } });

    fireEvent.click(screen.getByRole("button", { name: "保存更改" }));
    await waitFor(() => expect(updatePortfolio).toHaveBeenCalledTimes(1));
    expect(updatePortfolio).toHaveBeenCalledWith("portfolio-ai-course", expect.objectContaining({ title: "改名作品" }));
    expect(deletePortfolio).toHaveBeenCalledWith("portfolio-mentor-guide");
    expect(createPortfolio).toHaveBeenCalledWith(expect.objectContaining({ title: "新作品" }));
    expect(await screen.findByRole("heading", { name: "我的个人资料" })).toBeInTheDocument();
  });

  it("取消编辑恢复原值，不调用保存", async () => {
    await renderReadyProfile();
    fireEvent.click(screen.getByRole("button", { name: "编辑资料" }));
    fireEvent.change(screen.getByTestId("profile-name-input"), { target: { value: "不应保存" } });
    fireEvent.click(screen.getByRole("button", { name: "取消" }));
    expect(updateProfile).not.toHaveBeenCalled();
    expect(screen.getByRole("heading", { name: "我的个人资料" })).toBeInTheDocument();
    expect(screen.getByTestId("profile-display-name")).toHaveTextContent("林溪");
  });

  it("空姓名保存失败并保留编辑态", async () => {
    await renderReadyProfile();
    fireEvent.click(screen.getByRole("button", { name: "编辑资料" }));
    fireEvent.change(screen.getByTestId("profile-name-input"), { target: { value: "   " } });
    fireEvent.click(screen.getByRole("button", { name: "保存更改" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("姓名不能为空");
    expect(updateProfile).not.toHaveBeenCalled();
    expect(screen.getByRole("heading", { name: "编辑个人资料" })).toBeInTheDocument();
  });

  it("退出登录清理 token 并跳转 /login", async () => {
    await renderReadyProfile();
    fireEvent.click(screen.getByRole("button", { name: "退出登录" }));
    expect(clearAuthToken).toHaveBeenCalledTimes(1);
    expect(router.push).toHaveBeenCalledWith("/login");
  });

  it("真实模式缺字段不回退 mock 样例，展示空态（P1-2 QA 复验 FAIL 修复）", async () => {
    fetchProfile.mockResolvedValue({
      id: "u_empty",
      email: "empty@example.com",
      displayName: null,
      avatarUrl: null,
      isPlatformAdmin: false,
      location: null,
      about: null,
      skills: null,
      joinedAt: null,
      visibility: null,
      memberNumber: null,
    });
    fetchPortfolio.mockResolvedValue([]);
    fetchRoles.mockResolvedValue([]);
    await renderReadyProfile();

    expect(screen.getByText("未设置", { selector: ".profile-summary__meta span" })).toBeInTheDocument();
    expect(screen.getByText("暂无简介")).toBeInTheDocument();
    expect(screen.getByText("加入于 —")).toBeInTheDocument();
    expect(within(screen.getByTestId("identity-card")).getByText("—")).toBeInTheDocument();
    expect(screen.getByTestId("skills-card")).toBeInTheDocument();
    expect(screen.getByText("还没有添加作品集。")).toBeInTheDocument();
    // mock 样例不得出现（profile 主内容区；侧栏品牌名是静态导航 UI，不属于用户资料数据）
    expect(screen.queryByText("上海", { selector: ".profile-summary__meta span" })).not.toBeInTheDocument();
    expect(screen.queryByText("关注社区学习、AI 教育与开放协作。喜欢把复杂的问题整理成清晰、可执行的课程与活动。")).not.toBeInTheDocument();
    expect(screen.queryByText("AI 教育")).not.toBeInTheDocument();
    expect(screen.queryByText("CGC-SH-0018")).not.toBeInTheDocument();
    const mainArea = screen.getByRole("main");
    expect(within(mainArea).queryByText("上海 Coding Girls Club")).not.toBeInTheDocument();
  });

  it("可见范围 workspace_public 时底部文案联动（P2-1）", async () => {
    fetchProfile.mockResolvedValue({ ...designProfile(), visibility: "workspace_public" as const });
    await renderReadyProfile();

    expect(screen.getByText("Workspace 内公开")).toBeInTheDocument();
    expect(screen.getByText("资料在 Workspace 内公开可见。")).toBeInTheDocument();

    // 进入编辑态切换为 workspace_members → 文案即时联动
    fireEvent.click(screen.getByRole("button", { name: "编辑资料" }));
    fireEvent.change(screen.getByTestId("profile-visibility-input"), { target: { value: "workspace_members" } });
    expect(screen.getByText("资料仅在当前 Workspace 内可见。")).toBeInTheDocument();
  });

  it("进入编辑态时 visibility select 以真实值初始化（P2-2）", async () => {
    fetchProfile.mockResolvedValue({ ...designProfile(), visibility: "workspace_public" as const });
    await renderReadyProfile();

    fireEvent.click(screen.getByRole("button", { name: "编辑资料" }));
    expect(screen.getByTestId("profile-visibility-input")).toHaveValue("workspace_public");
  });

  it("删除作品按钮 aria-label 精确化，不与技能标签删除混淆（P2-4）", async () => {
    await renderReadyProfile();
    fireEvent.click(screen.getByRole("button", { name: "编辑资料" }));

    const firstRow = screen.getAllByTestId("portfolio-edit-row")[0];
    const deleteBtn = within(firstRow).getByRole("button", { name: /删除作品/ });
    expect(deleteBtn).toHaveAttribute("aria-label", "删除作品：AI 入门工作坊课程大纲");
  });
});
