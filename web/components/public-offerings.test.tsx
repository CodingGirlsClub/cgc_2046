import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import PublicOfferingsPage from "./public-offerings";

/**
 * 公开发现页 /events 与 /courses（E-5 #50 G4；U4 全暗重建）。
 *
 * 视觉：.ld-root 固定深色门面（AE4：浅色系统主题下仍深色，token 暗色值由
 * lib/design-tokens.test.ts 锚定）；列表复用 landing OfferingRow 行式语言
 * （.ld-offer-row，R8），行内状态标签为后端派生报名 badge（KTD1），
 * meta 行排报名政策/截止/开始时间/地点（地点仅 event，R3）。
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

describe("公开发现页行式列表（U4/R8）", () => {
	it("badge 三态 + meta 行（政策/截止/开始/venue），行链接到详情", async () => {
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
		]);
		const { container } = render(<PublicOfferingsPage kind="event" />);

		// 公开发现页不要求登录（游客可浏览）
		expect(screen.getByRole("heading", { name: "公开活动" })).toBeInTheDocument();

		const rowA = await screen.findByRole("link", { name: /活动甲/ });
		expect(rowA).toHaveAttribute("href", "/events/a");
		expect(rowA).toHaveClass("ld-offer-row");
		expect(within(rowA).getByText("报名中")).toBeInTheDocument();
		expect(within(rowA).getByText(/直接报名/)).toBeInTheDocument();
		expect(within(rowA).getByText(/截止 不设截止/)).toBeInTheDocument();
		expect(within(rowA).getByText(/开始 2/)).toBeInTheDocument();
		expect(within(rowA).getByText(/中国 上海 上海 徐汇/)).toBeInTheDocument();
		// EventStatusTag（开放报名）从公开面移除，仅留工作区内部页
		expect(within(rowA).queryByText("开放报名")).toBeNull();

		expect(
			within(screen.getByRole("link", { name: /活动乙/ })).getByText("即将开始"),
		).toBeInTheDocument();
		expect(
			within(screen.getByRole("link", { name: /活动丙/ })).getByText("已满"),
		).toBeInTheDocument();

		// AE4 结构断言：固定深色门面根在场（html.light 下 .ld-root 重声明暗色 token）
		expect(container.querySelector("main.ld-root")).not.toBeNull();
	});

	it("无开始时间：时间位显示「时间待定」，不出现「即将开始」（AE2）；空 venue → 「地点待定」（R3）", async () => {
		fetchPublicOfferings.mockResolvedValue([
			{ ...BASE, enrollmentBadge: "enrolling", startsAt: null, venue: null },
		]);
		render(<PublicOfferingsPage kind="event" />);

		const row = await screen.findByRole("link", { name: /程序媛夜读会/ });
		expect(within(row).getByText(/时间待定/)).toBeInTheDocument();
		expect(within(row).queryByText(/即将开始/)).toBeNull();
		expect(within(row).getByText(/地点待定/)).toBeInTheDocument();
	});

	it("course 行无地点槽（R3：Course 无位置概念）", async () => {
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

		const row = await screen.findByRole("link", { name: /入门营/ });
		expect(row).toHaveAttribute("href", "/courses/bootcamp");
		expect(within(row).getByText(/时间待定/)).toBeInTheDocument();
		expect(within(row).queryByText(/地点待定/)).toBeNull();
	});

	it("加载中：暗色骨架（landing 同款 ld-skeleton ×3）", () => {
		fetchPublicOfferings.mockReturnValue(new Promise(() => {}));
		const { container } = render(<PublicOfferingsPage kind="event" />);

		expect(container.querySelectorAll(".ld-skeleton")).toHaveLength(3);
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
