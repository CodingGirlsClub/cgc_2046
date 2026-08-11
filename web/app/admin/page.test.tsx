import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import AdminHomePage from "./page";

const { router } = vi.hoisted(() => ({
	router: { push: vi.fn(), replace: vi.fn() },
}));
const { fetchWorkspaces, fetchUsers, fetchApplications } = vi.hoisted(() => ({
	fetchWorkspaces: vi.fn(),
	fetchUsers: vi.fn(),
	fetchApplications: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	useRouter: () => router,
	// ThemeProvider 依赖 usePathname
	usePathname: () => "/admin",
}));

vi.mock("@/lib/admin", () => ({
	fetchWorkspaces,
	fetchUsers,
	fetchApplications,
}));

beforeEach(() => {
	vi.clearAllMocks();
});

afterEach(cleanup);

describe("/admin 首页仪表盘概览", () => {
	it("渲染统计卡片与子页链接", async () => {
		fetchWorkspaces.mockResolvedValue([{ id: "ws1" }, { id: "ws2" }]);
		fetchUsers.mockResolvedValue([{ id: "u1" }]);
		fetchApplications.mockResolvedValue([{ id: "app1" }, { id: "app2" }]);

		render(<AdminHomePage />);

		expect(await screen.findByLabelText("工作台总数")).toHaveTextContent("2");
		expect(screen.getByLabelText("用户总数")).toHaveTextContent("1");
		expect(screen.getByLabelText("待审批申请数")).toHaveTextContent("2");
		expect(
			screen.getByRole("link", { name: "工作台管理" }),
		).toHaveAttribute("href", "/admin/workspaces");
		expect(screen.getByRole("link", { name: "用户管理" })).toHaveAttribute(
			"href",
			"/admin/users",
		);
		expect(screen.getByRole("link", { name: "申请审批" })).toHaveAttribute(
			"href",
			"/admin/applications",
		);
	});

	it("统计加载失败时仍渲染链接（不抛错）", async () => {
		fetchWorkspaces.mockRejectedValue(new Error("network"));
		fetchUsers.mockRejectedValue(new Error("network"));
		fetchApplications.mockRejectedValue(new Error("network"));

		render(<AdminHomePage />);

		expect(
			await screen.findByRole("link", { name: "工作台管理" }),
		).toBeInTheDocument();
	});
});
