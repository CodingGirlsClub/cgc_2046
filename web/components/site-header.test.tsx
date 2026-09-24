import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import SiteHeader from "./site-header";

const { pathnameRef } = vi.hoisted(() => ({
	pathnameRef: { value: "/events/1024-changsha-01" },
}));
const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));

vi.mock("next/navigation", () => ({
	usePathname: () => pathnameRef.value,
	useRouter: () => ({ push: vi.fn(), replace: vi.fn(), prefetch: vi.fn() }),
	useParams: () => ({}),
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
}));

vi.mock("@/lib/use-authed", () => ({ useAuthed }));

beforeEach(() => {
	vi.clearAllMocks();
	pathnameRef.value = "/events/1024-changsha-01";
	useAuthed.mockReturnValue({ authed: false, confirmed: true });
});

afterEach(cleanup);

describe("SiteHeader 报名引导回跳（UAT 断链修复）", () => {
	it("公开页面上：登录/注册链接携带当前页 next", () => {
		render(<SiteHeader active="events" />);

		expect(
			screen.getByRole("link", { name: /登录/ }),
		).toHaveAttribute(
			"href",
			`/login?next=${encodeURIComponent("/events/1024-changsha-01")}`,
		);
		expect(
			screen.getByRole("link", { name: /加入我们/ }),
		).toHaveAttribute(
			"href",
			`/register?next=${encodeURIComponent("/events/1024-changsha-01")}`,
		);
	});

	it("首页与登录/注册页不构造 next（避免回环）", () => {
		pathnameRef.value = "/";
		const { unmount } = render(<SiteHeader />);
		expect(screen.getByRole("link", { name: /登录/ })).toHaveAttribute(
			"href",
			"/login",
		);
		unmount();

		pathnameRef.value = "/login";
		render(<SiteHeader />);
		expect(screen.getByRole("link", { name: /登录/ })).toHaveAttribute(
			"href",
			"/login",
		);
	});

	it("已登录：「我的报名」「我的学习」位于中央导航「课程」之后；匿名不显示", () => {
		useAuthed.mockReturnValue({ authed: true, confirmed: true });
		const { unmount } = render(<SiteHeader active="events" />);

		const nav = screen.getByRole("navigation", { name: "主导航" });
		const labels = Array.from(nav.querySelectorAll("a")).map((a) =>
			a.textContent.trim(),
		);
		// 十周年主 campaign 排首位（活动期站内唯一入口）
		expect(labels).toEqual([
			"Hacker Start 1024",
			"活动",
			"课程",
			"我的报名",
			"我的学习",
			"倡导活动",
			"闪念间",
			"金句墙",
		]);
		expect(
			screen.getByRole("link", { name: "Hacker Start 1024" }),
		).toHaveAttribute("href", "/hackerstart-1024");
		expect(
			screen.getByRole("link", { name: "我的报名" }),
		).toHaveAttribute("href", "/participations");
		expect(
			screen.getByRole("link", { name: "我的学习" }),
		).toHaveAttribute("href", "/learning");
		unmount();

		useAuthed.mockReturnValue({ authed: false, confirmed: true });
		render(<SiteHeader active="events" />);
		expect(
			screen.queryByRole("link", { name: "我的报名" }),
		).not.toBeInTheDocument();
		expect(
			screen.queryByRole("link", { name: /我的学习/ }),
		).not.toBeInTheDocument();
		// 倡导活动是公开目录：匿名也可见（与活动/课程同列公开入口）
		expect(
			screen.getByRole("link", { name: "倡导活动" }),
		).toHaveAttribute("href", "/initiatives");
	});

	it("campaign 项：active 传 campaign 时高亮（aria-current）", () => {
		render(<SiteHeader active="campaign" />);
		const link = screen.getByRole("link", { name: "Hacker Start 1024" });
		expect(link).toHaveAttribute("aria-current", "page");
		expect(link.className).toContain("site-nav__link--active");
		// 其余项不高亮
		expect(screen.getByRole("link", { name: "活动" })).not.toHaveAttribute(
			"aria-current",
		);
	});
});
