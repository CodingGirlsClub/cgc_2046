import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, fireEvent, cleanup, waitFor, within } from "@testing-library/react";
import MembersPage from "./page";
import {
  MOCK_WORKSPACES,
  MOCK_MEMBERS,
  type WorkspaceMember,
} from "@/lib/workspaces";

/**
 * 成员角色管理页测试（#65）。
 * mock：useRouter/useParams（next/navigation）、isAuthenticated（lib/auth）、
 * fetchWorkspaceMembers / assignMemberRoles（lib/workspaces，保留 MOCK 数据供校验）。
 */

// 稳定 router 引用：避免每次 render 生成新对象导致 useEffect 无限循环
const { router } = vi.hoisted(() => ({ router: { push: vi.fn(), replace: vi.fn() } }));
const { replace } = router;
const { isAuthenticated, clearAuthToken } = vi.hoisted(() => ({
  isAuthenticated: vi.fn(),
  clearAuthToken: vi.fn(),
}));
const { fetchMembers, assignRoles } = vi.hoisted(() => ({
  fetchMembers: vi.fn(),
  assignRoles: vi.fn(),
}));
const { fetchMyWorkspaces } = vi.hoisted(() => ({ fetchMyWorkspaces: vi.fn() }));
const { params } = vi.hoisted(() => ({ params: { value: { slug: "cgc-academy" } } }));
const { fetchCurrentProfile } = vi.hoisted(() => ({ fetchCurrentProfile: vi.fn() }));

vi.mock("next/navigation", () => ({
  useRouter: () => router,
  useParams: () => params.value,
}));

vi.mock("@/lib/auth", () => ({
  isAuthenticated,
  clearAuthToken,
}));

vi.mock("@/lib/profile", async (importOriginal) => {
  const mod = (await importOriginal()) as Record<string, unknown>;
  return { ...mod, fetchCurrentProfile };
});

vi.mock("@/lib/workspaces", async (importOriginal) => {
  const mod = (await importOriginal()) as Record<string, unknown>;
  return {
    ...mod,
    fetchWorkspaceMembers: fetchMembers,
    assignMemberRoles: assignRoles,
    // #70 QA P1：工作区上下文经 useWorkspaceBySlug → fetchMyWorkspaces 解析
    fetchMyWorkspaces,
  };
});

beforeEach(() => {
  vi.clearAllMocks();
  isAuthenticated.mockReturnValue(true);
  params.value = { slug: "cgc-academy" };
  fetchMyWorkspaces.mockResolvedValue(MOCK_WORKSPACES);
  fetchCurrentProfile.mockResolvedValue({
    id: "u_0202",
    email: "xiaomei@example.com",
    displayName: "小美",
    avatarUrl: null,
    isPlatformAdmin: false,
  });
  fetchMembers.mockResolvedValue(MOCK_MEMBERS.ws_02);
  assignRoles.mockImplementation(
    async (_wsId: string, membershipId: string, roleNames: string[]) => {
      const member = MOCK_MEMBERS.ws_02.find((m) => m.membershipId === membershipId);
      if (!member) throw new Error("member not found");
      return { ...member, roles: roleNames } as WorkspaceMember;
    },
  );
});

afterEach(cleanup);

describe("成员角色管理页 /w/[slug]/members (#65)", () => {
  it("未登录：重定向 /login", async () => {
    isAuthenticated.mockReturnValue(false);
    render(<MembersPage />);
    await waitFor(() => expect(replace).toHaveBeenCalledWith("/login"));
    expect(fetchMembers).not.toHaveBeenCalled();
  });

  it("登录后：渲染成员列表（email/身份信息/角色徽章并集）", async () => {
    render(<MembersPage />);
    expect(await screen.findByText("方伯")).toBeInTheDocument();
    expect(screen.getByText("fangbo@example.com")).toBeInTheDocument();
    // 角色并集：方伯 owner + 小美 admin+member；多个成员持 member（并集）
    expect(screen.getByText("Owner · 所有者")).toBeInTheDocument();
    expect(screen.getByText("Admin · 管理员")).toBeInTheDocument();
    expect(screen.getAllByText("Member · 成员").length).toBeGreaterThan(0);
    // 4 个成员卡片
    expect(screen.getAllByTestId("member-card")).toHaveLength(4);
    // membership/user id 展示
    expect(screen.getByText(/membership wm_0201/)).toBeInTheDocument();
  });

  it("角色并集展示：同一成员多角色同时出现", async () => {
    render(<MembersPage />);
    // header ProfileEntry 也显示当前用户「小美」，限定在成员卡片内查找
    await waitFor(() => {
      expect(screen.getAllByTestId("member-card")).toHaveLength(4);
    });
    const cards = screen.getAllByTestId("member-card");
    const card = cards.find((c) => within(c).queryByText("小美")) as HTMLElement;
    expect(card).toBeDefined();
    // 小美持 admin+member 两个徽章（同卡片内）
    expect(within(card).getAllByTestId("role-badge").length).toBe(2);
  });

  it("权限控制：Owner/Admin（cgc-academy myRoleNames=[admin]）显示分配操作并可保存", async () => {
    render(<MembersPage />);
    expect(await screen.findByText(/你是 Owner\/Admin，可分配角色/)).toBeInTheDocument();
    // 每成员都有保存按钮
    expect(screen.getAllByRole("button", { name: /保存角色/ })).toHaveLength(4);
    // 切换角色并保存：给方伯加 member（owner+member）
    const ownerCheckbox = screen.getAllByRole("checkbox")[0];
    expect(ownerCheckbox).toBeChecked();
    const saveButtons = screen.getAllByRole("button", { name: /保存角色/ });
    fireEvent.click(saveButtons[0]);
    await waitFor(() => expect(assignRoles).toHaveBeenCalled());
    const [wsId, membershipId, roleNames] = assignRoles.mock.calls[0];
    expect(wsId).toBe("ws_02");
    expect(membershipId).toBe("wm_0201");
    expect(roleNames).toEqual(["owner"]);
  });

  it("权限控制：非 Owner/Admin（cgc-shanghai myRoleNames=[member]）隐藏分配操作", async () => {
    params.value = { slug: "cgc-shanghai" };
    fetchMembers.mockResolvedValue(MOCK_MEMBERS.ws_01);
    render(<MembersPage />);
    expect(await screen.findByText(/仅 Owner\/Admin 可分配角色/)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /保存角色/ })).not.toBeInTheDocument();
    expect(screen.queryAllByRole("checkbox")).toHaveLength(0);
    expect(screen.getAllByTestId("member-card")).toHaveLength(4);
    expect(assignRoles).not.toHaveBeenCalled();
  });

  it("#67 入口：提供「权限说明 →」链接到 /w/[slug]/permissions", async () => {
    render(<MembersPage />);
    const entry = await screen.findByRole("link", { name: /权限说明 →/ });
    expect(entry).toHaveAttribute("href", "/w/cgc-academy/permissions");
  });

  it("#69 入口：header 提供个人资料入口链接到 /profile", async () => {
    render(<MembersPage />);
    const entry = await screen.findByTestId("profile-entry");
    expect(entry).toHaveAttribute("href", "/profile");
  });

  it("未知 slug：展示不存在提示 + 返回工作台", async () => {
    params.value = { slug: "not-exist" };
    render(<MembersPage />);
    expect(await screen.findByText(/不存在或不可访问/)).toBeInTheDocument();
    const back = screen.getByRole("link", { name: /← 工作台/ });
    expect(back).toHaveAttribute("href", "/");
  });

  it("数据经 fetchWorkspaceMembers 获取（mock/真实切换由 lib 层 USE_MOCK 开关决定）", async () => {
    // 页面始终通过 fetchWorkspaceMembers 取数；mock/真实由 lib 层 USE_MOCK_WORKSPACES 决定。
    fetchMembers.mockResolvedValue([
      { membershipId: "wm_real1", userId: "u_r1", email: "real@example.com", roles: ["admin"] },
    ]);
    // 切换 slug 触发重新 fetch（新挂载）
    params.value = { slug: "cgc-shanghai" };
    render(<MembersPage />);
    expect(await screen.findAllByText("real@example.com").then((els) => els.length)).toBeGreaterThan(0);
    expect(fetchMembers).toHaveBeenCalledWith("ws_01");
  });

  it("真实模式（#70 QA P1）：fetchMyWorkspaces 返回真实 ws（不在 mock），页面按真实数据渲染", async () => {
    // 复现 QA 场景：真实工作区 slug 不在 MOCK_WORKSPACES 内
    fetchMyWorkspaces.mockResolvedValue([
      {
        id: "ws_real_9",
        slug: "qa70-owner-ws-999",
        name: "QA70 真实工作区",
        joinPolicy: "open",
        sponsorshipEnabled: true,
        myRoleNames: ["owner"],
        roles: ["owner"],
        membershipStatus: "active",
      },
    ]);
    params.value = { slug: "qa70-owner-ws-999" };
    fetchMembers.mockResolvedValue([
      { membershipId: "wm_r9", userId: "u_r9", email: "qa.member@example.com", roles: ["owner"] },
    ]);

    render(<MembersPage />);
    // 真实 ws 解析成功：标题展示真实名称，不再提示「不存在或不可访问」
    expect(await screen.findByText("QA70 真实工作区 / 成员")).toBeInTheDocument();
    expect(screen.queryByText(/不存在或不可访问/)).not.toBeInTheDocument();
    // 真实成员列表渲染 + 角色上下文（owner 可分配）
    expect((await screen.findAllByText("qa.member@example.com")).length).toBeGreaterThan(0);
    expect(screen.getByText(/你是 Owner\/Admin，可分配角色/)).toBeInTheDocument();
    expect(fetchMembers).toHaveBeenCalledWith("ws_real_9");
    // 权限说明入口指向真实 slug
    expect(screen.getByRole("link", { name: /权限说明 →/ })).toHaveAttribute(
      "href",
      "/w/qa70-owner-ws-999/permissions",
    );
  });

  it("真实模式：fetchMyWorkspaces 返回的 ws 无角色（member 视角）隐藏分配操作", async () => {
    fetchMyWorkspaces.mockResolvedValue([
      {
        id: "ws_real_m",
        slug: "dbg5-member-ws-777",
        name: "DBG5 成员工作区",
        joinPolicy: "request",
        sponsorshipEnabled: true,
        myRoleNames: ["member"],
        roles: ["member"],
        membershipStatus: "active",
      },
    ]);
    params.value = { slug: "dbg5-member-ws-777" };
    fetchMembers.mockResolvedValue([
      { membershipId: "wm_rm", userId: "u_rm", email: "me@example.com", roles: ["member"] },
    ]);

    render(<MembersPage />);
    expect(await screen.findByText("DBG5 成员工作区 / 成员")).toBeInTheDocument();
    expect(await screen.findByText(/仅 Owner\/Admin 可分配角色/)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /保存角色/ })).not.toBeInTheDocument();
  });
});

describe("成员角色数据源（lib/workspaces）", () => {
  it("mock 数据：每个 workspace 有成员且角色为并集数组", () => {
    expect(MOCK_MEMBERS.ws_01.length).toBeGreaterThan(0);
    expect(MOCK_MEMBERS.ws_02.length).toBeGreaterThan(0);
    expect(MOCK_WORKSPACES.find((w) => w.slug === "cgc-academy")?.myRoleNames).toEqual(["admin"]);
  });
});
