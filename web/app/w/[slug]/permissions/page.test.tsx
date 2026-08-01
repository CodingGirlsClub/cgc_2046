import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, cleanup, waitFor, within } from "@testing-library/react";
import PermissionsPage from "./page";
import { MOCK_PERMISSION_MATRIX, PERMISSION_ABILITIES } from "@/lib/permissions";

/**
 * 权限表可视化页测试（#67）。
 * mock：useRouter/useParams（next/navigation）、isAuthenticated（lib/auth）、
 * fetchPermissionsMatrix（lib/permissions，保留 MOCK 矩阵供校验）。
 */

// 稳定 router 引用：避免每次 render 生成新对象导致 useEffect 无限循环
const { router } = vi.hoisted(() => ({ router: { push: vi.fn(), replace: vi.fn() } }));
const { replace } = router;
const { isAuthenticated, clearAuthToken } = vi.hoisted(() => ({
  isAuthenticated: vi.fn(),
  clearAuthToken: vi.fn(),
}));
const { fetchMatrix } = vi.hoisted(() => ({ fetchMatrix: vi.fn() }));
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
  return {
    ...mod,
    fetchPermissionsMatrix: fetchMatrix,
  };
});

beforeEach(() => {
  vi.clearAllMocks();
  isAuthenticated.mockReturnValue(true);
  params.value = { slug: "cgc-academy" };
  fetchCurrentProfile.mockResolvedValue({
    id: "u_0202",
    email: "xiaomei@example.com",
    displayName: "小美",
    avatarUrl: null,
    isPlatformAdmin: false,
  });
  fetchMatrix.mockResolvedValue(MOCK_PERMISSION_MATRIX);
});

afterEach(() => {
  cleanup();
});

describe("/w/[slug]/permissions 权限表可视化页", () => {
  it("未登录重定向到 /login", async () => {
    isAuthenticated.mockReturnValue(false);
    render(<PermissionsPage />);
    await waitFor(() => expect(replace).toHaveBeenCalledWith("/login"));
    expect(fetchMatrix).not.toHaveBeenCalled();
  });

  it("渲染角色行（Owner/Admin/Member 三角色）与能力列", async () => {
    render(<PermissionsPage />);
    await waitFor(() => {
      expect(screen.getByText("CGC 线上学院 / 权限表")).toBeInTheDocument();
    });
    // 行数 = 三角色
    const rows = screen.getAllByTestId("permission-row");
    expect(rows).toHaveLength(3);
    // 每行包含角色徽章
    expect(within(rows[0]).getByText(/Owner · 所有者/)).toBeInTheDocument();
    expect(within(rows[1]).getByText(/Admin · 管理员/)).toBeInTheDocument();
    expect(within(rows[2]).getByText(/Member · 成员/)).toBeInTheDocument();
    // 能力列表头（表头 + 说明卡片各出现一次 → 至少表头存在）
    for (const a of PERMISSION_ABILITIES) {
      expect(screen.getAllByText(a.label).length).toBeGreaterThanOrEqual(1);
    }
  });

  it("矩阵语义：member 不支持成员管理/角色分配，owner/admin 支持", async () => {
    render(<PermissionsPage />);
    await waitFor(() => {
      expect(screen.getAllByTestId("permission-row")).toHaveLength(3);
    });
    // member × list_members / manage_members / assign_roles → ✗
    for (const ability of ["list_members", "manage_members", "assign_roles"] as const) {
      const cell = screen.getByTestId(`cell-member-${ability}`);
      expect(cell.textContent).toContain("✗");
    }
    // owner/admin × assign_roles → ✓
    expect(screen.getByTestId("cell-owner-assign_roles").textContent).toContain("✓");
    expect(screen.getByTestId("cell-admin-assign_roles").textContent).toContain("✓");
    // member × view_workspace → ✓（基础访问）
    expect(screen.getByTestId("cell-member-view_workspace").textContent).toContain("✓");
    // create_workspace 三角色均 ✗（平台管理员专属）
    expect(screen.getByTestId("cell-owner-create_workspace").textContent).toContain("✗");
    expect(screen.getByTestId("cell-admin-create_workspace").textContent).toContain("✗");
    expect(screen.getByTestId("cell-member-create_workspace").textContent).toContain("✗");
  });

  it("当前用户（cgc-academy=admin）角色行高亮并展示「我的角色」标记", async () => {
    render(<PermissionsPage />);
    await waitFor(() => {
      expect(screen.getAllByTestId("permission-row")).toHaveLength(3);
    });
    // admin 是 cgc-academy 当前用户的角色
    expect(screen.getAllByText("我的角色").length).toBeGreaterThanOrEqual(1);
  });

  it("能力说明区展示每项能力 + 我的角色支持状态（admin 支持角色分配）", async () => {
    render(<PermissionsPage />);
    await waitFor(() => {
      expect(screen.getByText("能力说明")).toBeInTheDocument();
    });
    // 「分配成员角色」出现在表头 + 能力说明卡片（≥1）
    expect(screen.getAllByText("分配成员角色").length).toBeGreaterThanOrEqual(1);
    // admin 角色支持 assign_roles → 说明卡片显示「我的角色支持」（≥1，view/access/list/manage/assign 共 5 项）
    const assignCards = screen.getAllByText("我的角色支持");
    expect(assignCards.length).toBe(5);
  });

  it("未知 slug 显示不存在提示", async () => {
    params.value = { slug: "no-such-ws" };
    render(<PermissionsPage />);
    await waitFor(() => {
      expect(screen.getByText(/工作区「no-such-ws」不存在或不可访问/)).toBeInTheDocument();
    });
    expect(fetchMatrix).not.toHaveBeenCalled();
  });

  it("数据经 fetchPermissionsMatrix 获取（切换 slug 重新加载）", async () => {
    render(<PermissionsPage />);
    await waitFor(() => expect(fetchMatrix).toHaveBeenCalledTimes(1));
    // 切到 cgc-shanghai 再次渲染（模拟导航）
    params.value = { slug: "cgc-shanghai" };
    cleanup();
    fetchMatrix.mockClear();
    render(<PermissionsPage />);
    await waitFor(() => expect(fetchMatrix).toHaveBeenCalledTimes(1));
  });

  it("mock 数据源完整性：三角色 + 6 能力 + 每角色 abilities 齐全", () => {
    expect(MOCK_PERMISSION_MATRIX).toHaveLength(3);
    for (const row of MOCK_PERMISSION_MATRIX) {
      expect(PERMISSION_ABILITIES.map((a) => a.id).every((id) => id in row.abilities)).toBe(true);
    }
  });

  it("#69 入口：header 提供个人资料入口链接到 /profile", async () => {
    render(<PermissionsPage />);
    const entry = await screen.findByTestId("profile-entry");
    expect(entry).toHaveAttribute("href", "/profile");
  });
});
