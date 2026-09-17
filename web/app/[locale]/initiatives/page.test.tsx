import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import { formatDeadline } from "@/lib/events";
import InitiativeIndexPage from "./page";

const { fetchPublicInitiatives } = vi.hoisted(() => ({
	fetchPublicInitiatives: vi.fn(),
}));

vi.mock("@/lib/graphql/initiatives", () => ({ fetchPublicInitiatives }));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useRouter: () => ({ push: vi.fn(), replace: vi.fn(), back: vi.fn() }),
	usePathname: () => "/initiatives",
}));

const OPEN_ROW = {
	id: "i1",
	name: "Hackerstart 1024 全国黑客松",
	slug: "hackerstart1024",
	status: "open",
	hashtag: "#hackerstart1024",
	description: "1024 程序员节全国巡回黑客松。",
	windowStartsAt: "2026-10-24T00:00:00Z",
	windowEndsAt: "2026-11-24T00:00:00Z",
};

const CLOSED_ROW = {
	id: "i2",
	name: "Maker Recap 2025（已结束届）",
	slug: "maker-recap-2025",
	status: "closed",
	hashtag: "#makerrecap2025",
	description: "上一届回顾。",
	windowStartsAt: "2025-10-24T00:00:00Z",
	windowEndsAt: "2025-11-24T00:00:00Z",
};

const NO_WINDOW_ROW = {
	id: "i3",
	name: "长期开放场",
	slug: "always-on",
	status: "open",
	hashtag: null,
	description: null,
	windowStartsAt: null,
	windowEndsAt: null,
};

beforeEach(() => {
	vi.clearAllMocks();
	fetchPublicInitiatives.mockResolvedValue([OPEN_ROW, CLOSED_ROW]);
});

afterEach(cleanup);

describe("/initiatives 公开列表页", () => {
	it("AE3：open 与 closed 都列出、open 在前、卡片字段与链接正确", async () => {
		render(<InitiativeIndexPage />);

		// 顶导「倡导活动」高亮当前目录页（aria-current + active 类）
		expect(
			screen.getByRole("link", { name: "倡导活动" }),
		).toHaveAttribute("aria-current", "page");

		const openLink = await screen.findByRole("link", {
			name: /Hackerstart 1024 全国黑客松/,
		});
		const closedLink = screen.getByRole("link", {
			name: /Maker Recap 2025/,
		});

		expect(openLink).toHaveAttribute("href", "/initiatives/hackerstart1024");
		expect(closedLink).toHaveAttribute("href", "/initiatives/maker-recap-2025");

		// open 在前（按返回顺序渲染）
		const links = screen
			.getAllByRole("link")
			.filter((a) => a.getAttribute("href")?.startsWith("/initiatives/"));
		expect(links[0]).toBe(openLink);

		// 卡片字段：品牌标签、时间窗、状态徽章（期望值经组件同款 formatDeadline
		// 计算，时区无关——code-review 缺口修复）
		expect(screen.getByText("#hackerstart1024")).toBeInTheDocument();
		expect(
			screen.getByText(
				`${formatDeadline(OPEN_ROW.windowStartsAt, "时间待定", "zh-CN")} – ${formatDeadline(OPEN_ROW.windowEndsAt, "时间待定", "zh-CN")}`,
			),
		).toBeInTheDocument();
		expect(screen.getByText("开放报名")).toBeInTheDocument();
		expect(screen.getByText("已结束")).toBeInTheDocument();
	});

	// #628：cancelled（中止）与 closed（收尾）卡片文案分叉；两者都仍是留档可直达
	it("#628：cancelled 卡片渲染「已取消」，与 closed / open 文案不同", async () => {
		fetchPublicInitiatives.mockResolvedValue([
			{ ...CLOSED_ROW, id: "i3", name: "Winter Sprint（已中止届）", slug: "winter-sprint", status: "cancelled" },
		]);

		render(<InitiativeIndexPage />);

		const link = await screen.findByRole("link", { name: /Winter Sprint/ });
		expect(link).toHaveAttribute("href", "/initiatives/winter-sprint");
		expect(link.textContent).toContain("已取消");
		expect(link.textContent).not.toContain("已结束");
		expect(link.textContent).not.toContain("开放报名");
	});

	it("时间窗为空显示「时间待定」", async () => {
		fetchPublicInitiatives.mockResolvedValue([NO_WINDOW_ROW]);
		render(<InitiativeIndexPage />);

		expect(await screen.findByText("时间待定")).toBeInTheDocument();
	});

	it("空列表渲染空态", async () => {
		fetchPublicInitiatives.mockResolvedValue([]);
		render(<InitiativeIndexPage />);

		expect(await screen.findByText("暂无倡导活动")).toBeInTheDocument();
	});

	it("加载失败渲染错误态，重试重新拉取", async () => {
		fetchPublicInitiatives.mockRejectedValueOnce(new Error("network"));
		render(<InitiativeIndexPage />);

		expect(await screen.findByRole("alert")).toBeInTheDocument();

		fetchPublicInitiatives.mockResolvedValue([OPEN_ROW]);
		fireEvent.click(screen.getByRole("button", { name: "重试" }));

		expect(
			await screen.findByRole("link", { name: /Hackerstart 1024/ }),
		).toBeInTheDocument();
		expect(fetchPublicInitiatives).toHaveBeenCalledTimes(2);
	});

	it("加载中渲染骨架屏", async () => {
		let resolve: (v: unknown[]) => void = () => {};
		fetchPublicInitiatives.mockImplementation(
			() => new Promise((r) => (resolve = r)),
		);
		render(<InitiativeIndexPage />);

		expect(
			document.querySelectorAll(".public-catalog-skeleton").length,
		).toBeGreaterThan(0);
		resolve([]);
		await waitFor(() =>
			expect(
				document.querySelectorAll(".public-catalog-skeleton").length,
			).toBe(0),
		);
	});
});
