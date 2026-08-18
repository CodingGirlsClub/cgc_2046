import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent } from "@testing-library/react";
import { render } from "@/test-utils";
import AdminWorkspacesPage from "./page";

const { router } = vi.hoisted(() => ({
	router: { push: vi.fn(), replace: vi.fn() },
}));
const { fetchWorkspaces } = vi.hoisted(() => ({
	fetchWorkspaces: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	useRouter: () => router,
	usePathname: () => "/admin/workspaces",
}));

vi.mock("@/lib/admin", () => ({ fetchWorkspaces }));

const wsShape = [
	{
		id: "ws1",
		slug: "cgc-academy",
		name: "CGC 学院",
		joinPolicy: "request",
		sponsorshipEnabled: true,
		insertedAt: "2026-08-01T00:00:00Z",
		memberCount: 12,
	},
];

beforeEach(() => {
	vi.clearAllMocks();
});

afterEach(cleanup);

describe("/admin/workspaces 工作台列表", () => {
	it("渲染列表行（name/slug/joinPolicy/memberCount）与创建链接", async () => {
		fetchWorkspaces.mockResolvedValue(wsShape);

		render(<AdminWorkspacesPage />);

		expect(await screen.findByText("CGC 学院")).toBeInTheDocument();
		expect(screen.getByText("cgc-academy")).toBeInTheDocument();
		expect(screen.getByText("申请审批")).toBeInTheDocument();
		expect(screen.getByText("12")).toBeInTheDocument();
		expect(
			screen.getByRole("link", { name: "创建工作台" }),
		).toHaveAttribute("href", "/admin/workspaces/create");
		expect(
			screen.getByRole("link", { name: /CGC 学院/ }),
		).toHaveAttribute("href", "/admin/workspaces/ws1");
	});

	it("搜索后 fetchWorkspaces 带 search 重新拉取", async () => {
		fetchWorkspaces.mockResolvedValue(wsShape);

		render(<AdminWorkspacesPage />);
		await screen.findByText("CGC 学院");

		fireEvent.change(screen.getByPlaceholderText(/搜索/), {
			target: { value: "academy" },
		});
		fireEvent.click(screen.getByRole("button", { name: "搜索" }));

		await vi.waitFor(() => {
			expect(fetchWorkspaces).toHaveBeenLastCalledWith("academy", {
				first: 50,
				after: "0",
			});
		});
	});

	it("分页：下一页传 offset，上一页回退", async () => {
		fetchWorkspaces.mockResolvedValue(wsShape);

		render(<AdminWorkspacesPage />);
		await screen.findByText("CGC 学院");

		fireEvent.click(screen.getByRole("button", { name: "下一页" }));

		await vi.waitFor(() => {
			expect(fetchWorkspaces).toHaveBeenLastCalledWith("", {
				first: 50,
				after: "1",
			});
		});

		fireEvent.click(screen.getByRole("button", { name: "上一页" }));
	});

	it("加载失败显示错误提示", async () => {
		fetchWorkspaces.mockRejectedValue(new Error("network"));

		render(<AdminWorkspacesPage />);

		expect(await screen.findByText(/加载失败/)).toBeInTheDocument();
	});

	it("空列表显示空态", async () => {
		fetchWorkspaces.mockResolvedValue([]);

		render(<AdminWorkspacesPage />);

		expect(await screen.findByText(/暂无工作台/)).toBeInTheDocument();
	});
});
