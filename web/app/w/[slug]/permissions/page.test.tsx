import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, render, screen, waitFor, within } from "@testing-library/react";
import PermissionsPage from "./page";
import {
  MOCK_PERMISSION_MATRIX,
  PERMISSION_ABILITIES,
  PERMISSION_ROLE_ORDER,
} from "@/lib/permissions";

const { router } = vi.hoisted(() => ({
  router: { push: vi.fn(), replace: vi.fn() },
}));
const { isAuthenticated, clearAuthToken } = vi.hoisted(() => ({
  isAuthenticated: vi.fn(),
  clearAuthToken: vi.fn(),
}));
const { fetchMatrix } = vi.hoisted(() => ({ fetchMatrix: vi.fn() }));
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

vi.mock("@/lib/permissions", async (importOriginal) => {
  const mod = (await importOriginal()) as Record<string, unknown>;
  return { ...mod, fetchPermissionsMatrix: fetchMatrix };
});

vi.mock("@/lib/workspaces", async (importOriginal) => {
  const mod = (await importOriginal()) as Record<string, unknown>;
  return { ...mod, fetchMyWorkspaces };
});

beforeEach(() => {
  vi.clearAllMocks();
  isAuthenticated.mockReturnValue(true);
  params.value = { slug: "cgc-academy" };
  fetchMyWorkspaces.mockResolvedValue([
    {
      id: "ws_02",
      slug: "cgc-academy",
      name: "CGC 线上学院",
      joinPolicy: "request",
      sponsorshipEnabled: true,
      myRoleNames: ["admin"],
      roles: ["admin"],
      membershipStatus: "active",
    },
  ]);
  fetchCurrentProfile.mockResolvedValue({
    id: "u_0202",
    email: "chenyu@cgc2046.org",
    displayName: "陈雨",
    avatarUrl: null,
    isPlatformAdmin: false,
  });
  fetchMatrix.mockResolvedValue(MOCK_PERMISSION_MATRIX);
});

afterEach(() => cleanup());

async function renderReadyPage() {
  render(<PermissionsPage />);
  await screen.findByRole("heading", { name: "查看角色到能力的映射与 can? 判定" });
  await waitFor(() => expect(screen.queryByTestId("permissions-loading")).not.toBeInTheDocument());
}

describe("/w/[slug]/permissions 权限映射页", () => {
  it("未登录重定向到 /login，且不请求权限矩阵", async () => {
    isAuthenticated.mockReturnValue(false);
    render(<PermissionsPage />);

    await waitFor(() => expect(router.replace).toHaveBeenCalledWith("/login"));
    expect(fetchMatrix).not.toHaveBeenCalled();
  });

  it("按设计稿渲染 Workspace 设置壳、页签、规则提示和标题", async () => {
    await renderReadyPage();

    expect(screen.getByText("上海 Coding Girls Club")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "查看角色到能力的映射与 can? 判定" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "成员" })).toHaveAttribute("href", "/w/cgc-academy/members");
    expect(screen.getByRole("link", { name: "权限映射" })).toHaveAttribute("aria-current", "page");
    expect(screen.getByText("多角色取并集")).toBeInTheDocument();
    expect(screen.getByText("租户边界优先")).toBeInTheDocument();
    expect(screen.getByText("Owner 专门指派")).toBeInTheDocument();
  });

  it("展示五个设计角色和七项能力", async () => {
    await renderReadyPage();

    expect(screen.getByRole("heading", { name: "权限矩阵" })).toBeInTheDocument();
    for (const role of ["Owner", "Admin", "Tutor", "Volunteer", "Learner"]) {
      expect(screen.getByText(role, { selector: ".permissions-role-header" })).toBeInTheDocument();
    }
    for (const ability of PERMISSION_ABILITIES) {
      expect(screen.getByTestId(`permission-row-${ability.id}`)).toBeInTheDocument();
      expect(screen.getByText(ability.label, { selector: ".permissions-ability-label strong" })).toBeInTheDocument();
    }
    expect(screen.getAllByTestId("permission-ability-status")).toHaveLength(PERMISSION_ABILITIES.length);
  });

  it("矩阵语义符合设计：Owner/Admin 可管理，其他角色只读，跨 Workspace 全拒绝", async () => {
    await renderReadyPage();

    expect(screen.getByTestId("cell-owner-manage_members")).toHaveTextContent("✓");
    expect(screen.getByTestId("cell-admin-manage_members")).toHaveTextContent("✓");
    for (const role of ["tutor", "volunteer", "learner"]) {
      expect(screen.getByTestId(`cell-${role}-manage_members`)).toHaveTextContent("—");
      expect(screen.getByTestId(`cell-${role}-assign_roles`)).toHaveTextContent("—");
    }
    expect(screen.getByTestId("cell-owner-change_join_policy")).toHaveTextContent("✓");
    expect(screen.getByTestId("cell-admin-change_join_policy")).toHaveTextContent("—");
    for (const role of PERMISSION_ROLE_ORDER) {
      expect(screen.getByTestId(`cell-${role}-cross_workspace_access`)).toHaveTextContent("⊘");
    }
    expect(screen.getByText("不含 Owner 角色授予")).toBeInTheDocument();
  });

  it("判定示例展示林溪的 Owner + Tutor 并集，跨 Workspace 仍拒绝", async () => {
    await renderReadyPage();

    const example = screen.getByTestId("permission-example");
    expect(within(example).getByText("林溪")).toBeInTheDocument();
    expect(within(example).getByText("Owner")).toBeInTheDocument();
    expect(within(example).getByText("Tutor")).toBeInTheDocument();
    expect(within(example).getByText("can? = true")).toBeInTheDocument();
    expect(within(example).getByText("允许", { selector: ".permissions-example__result span" })).toBeInTheDocument();

    const statuses = within(example).getAllByTestId("permission-ability-status");
    expect(statuses).toHaveLength(7);
    expect(statuses.slice(0, 6).every((item) => item.textContent?.includes("允许"))).toBe(true);
    expect(statuses[6]).toHaveTextContent("跨 Workspace 访问");
    expect(statuses[6]).toHaveTextContent("拒绝");
  });

  it("未知 slug 显示不可访问状态，不请求权限矩阵", async () => {
    params.value = { slug: "no-such-ws" };
    render(<PermissionsPage />);

    expect(await screen.findByRole("heading", { name: "工作区不可访问" })).toBeInTheDocument();
    expect(screen.getByText("no-such-ws", { exact: false })).toBeInTheDocument();
    expect(fetchMatrix).not.toHaveBeenCalled();
  });

  it("按当前 slug 解析真实 workspace，并在切换 slug 时重新请求矩阵", async () => {
    await renderReadyPage();
    expect(fetchMatrix).toHaveBeenCalledTimes(1);

    params.value = { slug: "be-verify-ws-456" };
    fetchMyWorkspaces.mockResolvedValueOnce([
      {
        id: "ws_real_perm",
        slug: "be-verify-ws-456",
        name: "BE 验证权限工作区",
        joinPolicy: "request",
        sponsorshipEnabled: true,
        myRoleNames: ["admin", "member"],
        roles: ["admin", "member"],
        membershipStatus: "active",
      },
    ]);
    cleanup();
    fetchMatrix.mockClear();
    await renderReadyPage();
    expect(fetchMatrix).toHaveBeenCalledTimes(1);
  });

  it("工作区列表没有匹配 slug 时不渲染矩阵", async () => {
    params.value = { slug: "not-in-any-list" };
    render(<PermissionsPage />);

    expect(await screen.findByRole("heading", { name: "工作区不可访问" })).toBeInTheDocument();
    expect(fetchMatrix).not.toHaveBeenCalled();
  });

  it("mock 数据源完整性：五角色 × 七能力，每个能力都有 boolean", () => {
    expect(MOCK_PERMISSION_MATRIX).toHaveLength(5);
    expect(MOCK_PERMISSION_MATRIX.map((row) => row.role)).toEqual(PERMISSION_ROLE_ORDER);
    for (const row of MOCK_PERMISSION_MATRIX) {
      for (const ability of PERMISSION_ABILITIES) {
        expect(typeof row.abilities[ability.id]).toBe("boolean");
      }
    }
  });

  it("提供个人资料入口并支持退出登录", async () => {
    await renderReadyPage();

    expect(screen.getByTestId("profile-entry")).toHaveAttribute("href", "/profile");
    screen.getByRole("button", { name: "退出登录" }).click();
    expect(clearAuthToken).toHaveBeenCalledTimes(1);
    expect(router.push).toHaveBeenCalledWith("/login");
  });
});
