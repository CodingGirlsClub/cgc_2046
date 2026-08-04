import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import ProfilePortfolioPage from "./page";

const { router, searchParams } = vi.hoisted(() => ({
	router: { push: vi.fn(), replace: vi.fn() },
	searchParams: { get: vi.fn() },
}));
const { useAuthed } = vi.hoisted(() => ({
	useAuthed: vi.fn(),
}));
const { fetchProfile, fetchRoles, fetchPortfolio } = vi.hoisted(() => ({
	fetchProfile: vi.fn(),
	fetchRoles: vi.fn(),
	fetchPortfolio: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	useRouter: () => router,
	useSearchParams: () => searchParams,
	usePathname: () => "/profile/portfolio",
}));
vi.mock("@/lib/use-authed", () => ({
	useAuthed,
}));
vi.mock("@/lib/profile", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return {
		...mod,
		fetchCurrentProfile: fetchProfile,
		fetchProfileRoleSummary: fetchRoles,
		fetchPortfolioItems: fetchPortfolio,
	};
});

const TEST_PORTFOLIO = [
	{
		id: "p1",
		title: "AI 入门工作坊课程大纲",
		description: "一套面向零基础学习者的 6 周课程设计。",
		url: "https://example.com/ai-course",
		icon: "document" as const,
	},
	{
		id: "p2",
		title: "社区导师手册",
		description: "导师协作原则、答疑流程与课堂支持清单。",
		url: "https://example.com/mentor-guide",
		icon: "book" as const,
	},
	{
		id: "p3",
		title: "OpenClacky 入门指南",
		description: "从安装到连接 CGC 的完整上手指引。",
		url: "https://example.com/openclacky-guide",
		icon: "guide" as const,
	},
];

const defaultProfile = () => ({
	id: "u_0201",
	email: "linxi@cgc2046.org",
	displayName: "林溪",
	avatarUrl: null,
	isPlatformAdmin: false,
	workspaceSlug: "cgc-shanghai",
	workspaceRoles: ["owner", "tutor"] as const,
});

beforeEach(() => {
	vi.clearAllMocks();
	useAuthed.mockReturnValue({ authed: true, confirmed: true });
	searchParams.get.mockReturnValue(null);
	fetchProfile.mockResolvedValue(defaultProfile());
	fetchPortfolio.mockResolvedValue(TEST_PORTFOLIO);
	fetchRoles.mockResolvedValue([
		{
			workspaceId: "ws_01",
			workspaceSlug: "cgc-shanghai",
			workspaceName: "上海 Coding Girls Club",
			myRoleNames: ["owner", "tutor"],
		},
	]);
});

afterEach(() => cleanup());

async function renderReady() {
	render(<ProfilePortfolioPage />);
	await screen.findByRole("heading", { name: "全部作品集" });
	await waitFor(() =>
		expect(screen.queryByText("正在加载作品集…")).not.toBeInTheDocument(),
	);
}

describe("/profile/portfolio 作品集全量页", () => {
	it("渲染标题、作品计数与面包屑", async () => {
		await renderReady();

		expect(
			screen.getByRole("heading", { name: "全部作品集" }),
		).toBeInTheDocument();
		expect(screen.getByText("来自 林溪 的 3 个作品")).toBeInTheDocument();
		expect(screen.getByText("共 3 个作品")).toBeInTheDocument();
		expect(screen.getByText("已显示全部 3 个作品")).toBeInTheDocument();
		// 面包屑（scope 到 breadcrumb 区域避免 sidebar 同名干扰）
		const breadcrumb = screen.getByLabelText("页面路径");
		expect(within(breadcrumb).getByText("个人资料")).toBeInTheDocument();
		expect(within(breadcrumb).getByText("全部作品集")).toBeInTheDocument();
	});

	it("列表展示所有作品条目", async () => {
		await renderReady();

		const list = screen.getByTestId("portfolio-full-list");
		expect(list).toBeInTheDocument();
		for (const item of TEST_PORTFOLIO) {
			expect(list).toHaveTextContent(item.title);
			expect(list).toHaveTextContent(item.description);
		}
		// 每个条目都是链接
		const links = list.querySelectorAll("a");
		expect(links).toHaveLength(TEST_PORTFOLIO.length);
		expect(links[0]).toHaveAttribute("href", "https://example.com/ai-course");
	});

	it("空作品集显示空态提示", async () => {
		fetchPortfolio.mockResolvedValue([]);
		await renderReady();

		expect(screen.getByText("还没有添加作品集。")).toBeInTheDocument();
		expect(
			screen.queryByTestId("portfolio-full-list"),
		).not.toBeInTheDocument();
	});

	it("加载中显示 loading 文案", async () => {
		// 让 Promise 不 resolve，保持 loading 态
		fetchProfile.mockImplementation(() => new Promise(() => {}));
		render(<ProfilePortfolioPage />);

		expect(screen.getByText("正在加载作品集…")).toBeInTheDocument();
	});

	it("数据加载失败显示错误态与返回链接", async () => {
		fetchProfile.mockRejectedValue(new Error("网络错误"));
		render(<ProfilePortfolioPage />);

		await screen.findByText("无法加载作品集");
		expect(screen.getByText("网络错误")).toBeInTheDocument();
		const backLink = screen.getByRole("link", { name: "返回个人资料" });
		expect(backLink).toHaveAttribute("href", "/profile");
	});

	it("面包屑和头部均包含返回个人资料链接", async () => {
		await renderReady();

		// 面包屑中的返回链接（scope 到 breadcrumb 区域）
		const breadcrumb = screen.getByLabelText("页面路径");
		const breadcrumbLink = within(breadcrumb).getByRole("link", { name: "个人资料" });
		expect(breadcrumbLink).toHaveAttribute("href", "/profile?ws=cgc-shanghai");

		// 头部按钮返回链接
		const headerBackLink = screen.getByRole("link", { name: "返回个人资料" });
		expect(headerBackLink).toHaveAttribute("href", "/profile?ws=cgc-shanghai");
	});

	it("未认证时不加载数据", async () => {
		useAuthed.mockReturnValue({ authed: false, confirmed: true });
		render(<ProfilePortfolioPage />);

		await waitFor(() =>
			expect(fetchProfile).not.toHaveBeenCalled(),
		);
		expect(fetchPortfolio).not.toHaveBeenCalled();
	});

	it("角色 chips 正确渲染", async () => {
		await renderReady();

		expect(screen.getByText("Owner")).toBeInTheDocument();
		expect(screen.getByText("Tutor")).toBeInTheDocument();
	});
});
