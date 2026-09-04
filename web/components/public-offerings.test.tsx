import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import PublicOfferingsPage from "./public-offerings";

/**
 * 公开发现页 /events 与 /courses（E-5 #50 G4；方向 B 主题目录）。
 *
 * 视觉：.public-catalog 跟随全局主题 token，品牌导航提供活动/课程/语言/登录
 * 入口；列表以 .public-catalog-card 信息卡展示后端派生报名 badge（KTD1）与
 * 报名政策/截止/开始时间/地点（地点仅 event，R3）。
 */

const { fetchPublicOfferings } = vi.hoisted(() => ({
	fetchPublicOfferings: vi.fn(),
}));

// fetchPublicOfferings 走 mock；parseVenue/formatVenue 用真实实现（venue 展示路径一并覆盖）
vi.mock("@/lib/public-offerings", async (importOriginal) => {
	const actual = await importOriginal<typeof import("@/lib/public-offerings")>();
	return { ...actual, fetchPublicOfferings };
});

// next-intl createNavigation 顶层 import redirect/permanentRedirect；ThemeProvider 依赖 usePathname
vi.mock("next/navigation", () => ({
	usePathname: () => "/events",
	useRouter: () => ({ replace: vi.fn(), push: vi.fn(), prefetch: vi.fn() }),
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
}));

const BASE = {
	id: "ev_1",
	slug: "reading-night",
	title: "程序媛夜读会",
	description: null,
	status: "open",
	visibility: "public",
	enrollmentPolicy: "open",
	registrationDeadline: null,
} as const;

beforeEach(() => {
	vi.clearAllMocks();
	fetchPublicOfferings.mockResolvedValue([]);
});

afterEach(cleanup);

describe("公开发现页方向 B 信息卡", () => {
	it("品牌导航 + badge 四态 + 分层信息（政策/截止/开始/venue），卡片链接到详情", async () => {
		fetchPublicOfferings.mockResolvedValue([
			{
				...BASE,
				id: "e1",
				slug: "a",
				title: "活动甲",
				enrollmentBadge: "enrolling",
				startsAt: "2026-09-01T10:00:00+08:00",
				venue: JSON.stringify({
					country: "中国",
					province: "上海",
					city: "上海",
					district: "徐汇",
				}),
			},
			{
				...BASE,
				id: "e2",
				slug: "b",
				title: "活动乙",
				enrollmentBadge: "starting_soon",
				startsAt: "2026-09-02T10:00:00+08:00",
				venue: null,
			},
			{
				...BASE,
				id: "e3",
				slug: "c",
				title: "活动丙",
				enrollmentBadge: "full",
				startsAt: null,
				venue: null,
			},
			{
				...BASE,
				id: "e4",
				slug: "d",
				title: "活动丁",
				enrollmentBadge: "closed",
				registrationDeadline: "2026-08-01T10:00:00+08:00",
				startsAt: null,
				venue: null,
			},
		]);
		const { container } = render(<PublicOfferingsPage kind="event" />);

		// 公开发现页不要求登录（游客可浏览）
		expect(screen.getByRole("heading", { name: "公开活动" })).toBeInTheDocument();

		// 统一 SiteHeader：aria-label 取 landing.nav.ariaLabel（主导航）
		const nav = screen.getByRole("navigation", { name: "主导航" });
		expect(within(nav).getByRole("link", { name: "活动" })).toHaveAttribute(
			"aria-current",
			"page",
		);
		expect(within(nav).getByRole("link", { name: "课程" })).toHaveAttribute(
			"href",
			"/courses",
		);

		const cardA = await screen.findByRole("link", { name: /活动甲/ });
		expect(cardA).toHaveAttribute("href", "/events/a");
		expect(cardA).toHaveClass("public-catalog-card");
		expect(within(cardA).getByText("报名中")).toBeInTheDocument();
		expect(within(cardA).getByText(/直接报名/)).toBeInTheDocument();
		expect(within(cardA).getByText(/截止 不设截止/)).toBeInTheDocument();
		expect(within(cardA).getByText("开始")).toBeInTheDocument();
		expect(within(cardA).getByText(/2026/)).toBeInTheDocument();
		expect(within(cardA).getByText("地点")).toBeInTheDocument();
		expect(within(cardA).getByText(/中国 上海 徐汇/)).toBeInTheDocument();
		// EventStatusTag（开放报名）从公开面移除，仅留工作区内部页
		expect(within(cardA).queryByText("开放报名")).toBeNull();

		expect(
			within(screen.getByRole("link", { name: /活动乙/ })).getByText("即将开始"),
		).toBeInTheDocument();
		expect(
			within(screen.getByRole("link", { name: /活动丙/ })).getByText("已满"),
		).toBeInTheDocument();
		expect(
			within(screen.getByRole("link", { name: /活动丁/ })).getByText("报名截止"),
		).toBeInTheDocument();

		// 方向 B：公开目录不再进入固定深色 .ld-root，跟随站点主题 token。
		expect(container.querySelector(".public-catalog")).not.toBeNull();
		expect(container.querySelector("main.public-catalog-main")).not.toBeNull();
		expect(container.querySelector("main.ld-root")).toBeNull();
	});

	it("无开始时间：时间位显示「时间待定」，不出现「即将开始」（AE2）；空 venue → 「地点待定」（R3）", async () => {
		fetchPublicOfferings.mockResolvedValue([
			{ ...BASE, enrollmentBadge: "enrolling", startsAt: null, venue: null },
		]);
		render(<PublicOfferingsPage kind="event" />);

		const card = await screen.findByRole("link", { name: /程序媛夜读会/ });
		expect(within(card).getByText(/时间待定/)).toBeInTheDocument();
		expect(within(card).queryByText(/即将开始/)).toBeNull();
		expect(within(card).getByText(/地点待定/)).toBeInTheDocument();
	});

	it("course 卡片无地点槽（R3：Course 无位置概念）", async () => {
		fetchPublicOfferings.mockResolvedValue([
			{
				...BASE,
				id: "c1",
				slug: "bootcamp",
				title: "入门营",
				enrollmentBadge: "enrolling",
				startsAt: null,
			},
		]);
		render(<PublicOfferingsPage kind="course" />);

		const card = await screen.findByRole("link", { name: /入门营/ });
		expect(card).toHaveAttribute("href", "/courses/bootcamp");
		expect(within(card).getByText(/时间待定/)).toBeInTheDocument();
		expect(within(card).queryByText("地点")).toBeNull();
		expect(within(card).queryByText(/地点待定/)).toBeNull();
	});

	it("加载中：主题信息卡骨架 ×3", () => {
		fetchPublicOfferings.mockReturnValue(new Promise(() => {}));
		const { container } = render(<PublicOfferingsPage kind="event" />);

		expect(container.querySelectorAll(".public-catalog-skeleton")).toHaveLength(3);
	});

	it("空列表：纯文案兜底（不抄 landing 跨页链接，避免 /events→/events 自环）", async () => {
		render(<PublicOfferingsPage kind="course" />);

		const empty = await screen.findByText("暂无公开课程。");
		expect(empty.closest("p")?.querySelector("a")).toBeNull();
	});

	it("拉取失败：错误消息 + 重试按钮；点击重试触发重新拉取", async () => {
		fetchPublicOfferings.mockRejectedValueOnce(new Error("network down"));
		render(<PublicOfferingsPage kind="event" />);

		const alert = await screen.findByRole("alert");
		expect(alert).toHaveTextContent("加载失败");
		expect(alert).toHaveTextContent("network down");

		fetchPublicOfferings.mockResolvedValueOnce([
			{ ...BASE, enrollmentBadge: "enrolling", startsAt: null, venue: null },
		]);
		fireEvent.click(screen.getByRole("button", { name: "重试" }));

		await waitFor(() => expect(fetchPublicOfferings).toHaveBeenCalledTimes(2));
		expect(
			await screen.findByRole("link", { name: /程序媛夜读会/ }),
		).toBeInTheDocument();
	});
});
