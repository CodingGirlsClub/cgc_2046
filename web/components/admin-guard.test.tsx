import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import AdminGuard from "./admin-guard";

const { router } = vi.hoisted(() => ({
  router: { push: vi.fn(), replace: vi.fn() },
}));
const { fetchCurrentProfile } = vi.hoisted(() => ({
  fetchCurrentProfile: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
  useRouter: () => router,
  // ThemeProvider 依赖 usePathname 解析 workspace slug（ADR-0004）
  usePathname: () => "/admin",
}));

vi.mock("@/lib/profile", () => ({ fetchCurrentProfile }));

beforeEach(() => {
  vi.clearAllMocks();
});

afterEach(cleanup);

describe("AdminGuard（/admin 前端门控，D6 方案 A：ME_PROFILE 查 isPlatformAdmin）", () => {
  it("isPlatformAdmin=true → 放行渲染 children", async () => {
    fetchCurrentProfile.mockResolvedValue({
      id: "u1",
      email: "admin@example.com",
      displayName: "Admin",
      isPlatformAdmin: true,
    });

    render(
      <AdminGuard>
        <div>admin content</div>
      </AdminGuard>,
    );

    expect(await screen.findByText("admin content")).toBeInTheDocument();
    expect(router.replace).not.toHaveBeenCalled();
  });

  it("isPlatformAdmin=false → redirect 到主页（不渲染 children）", async () => {
    fetchCurrentProfile.mockResolvedValue({
      id: "u2",
      email: "user@example.com",
      displayName: "User",
      isPlatformAdmin: false,
    });

    render(
      <AdminGuard>
        <div>admin content</div>
      </AdminGuard>,
    );

    await vi.waitFor(() => {
      expect(router.replace).toHaveBeenCalledWith("/");
    });
    expect(screen.queryByText("admin content")).not.toBeInTheDocument();
  });

  it("未登录（me 为 null → isPlatformAdmin=false）→ redirect 到主页", async () => {
    fetchCurrentProfile.mockResolvedValue({
      id: "",
      email: "",
      displayName: null,
      isPlatformAdmin: false,
    });

    render(
      <AdminGuard>
        <div>admin content</div>
      </AdminGuard>,
    );

    await vi.waitFor(() => {
      expect(router.replace).toHaveBeenCalledWith("/");
    });
  });

  it("查询进行中 → 显示 loading，不渲染 children 也不 redirect", () => {
    const { promise } = Promise.withResolvers();
    fetchCurrentProfile.mockReturnValue(promise);

    render(
      <AdminGuard>
        <div>admin content</div>
      </AdminGuard>,
    );

    expect(screen.getByText(/正在确认权限/)).toBeInTheDocument();
    expect(screen.queryByText("admin content")).not.toBeInTheDocument();
    expect(router.replace).not.toHaveBeenCalled();
  });

  it("查询失败 → 保守判非 admin，redirect 到主页", async () => {
    fetchCurrentProfile.mockRejectedValue(new Error("network"));

    render(
      <AdminGuard>
        <div>admin content</div>
      </AdminGuard>,
    );

    await vi.waitFor(() => {
      expect(router.replace).toHaveBeenCalledWith("/");
    });
    expect(screen.queryByText("admin content")).not.toBeInTheDocument();
  });
});
