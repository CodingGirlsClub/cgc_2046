import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, fireEvent, screen, within } from "@testing-library/react";
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
		// 十周年主 campaign 排首位（活动期站内唯一入口）；金句墙/许愿树殿后（许愿树为公开顶导第 7 项）
		expect(labels).toEqual([
			"Hacker Start 1024",
			"活动",
			"课程",
			"我的报名",
			"我的学习",
			"我的闪念间",
			"倡导活动",
			"闪念间",
			"金句墙",
			"许愿树",
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
		expect(screen.getByRole("link", { name: "我的闪念间" })).toHaveAttribute("href", "/flashback/capsule");
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

describe("SiteHeader 窄屏菜单抽屉", () => {
	function openDrawer() {
		const button = screen.getByRole("button", { name: "菜单" });
		expect(button).toHaveAttribute("aria-expanded", "false");
		fireEvent.click(button);
		expect(button).toHaveAttribute("aria-expanded", "true");
		// 桌面导航与抽屉导航并存（CSS 按视口显隐，jsdom 均在 DOM 中）
		const navs = screen.getAllByRole("navigation", { name: "主导航" });
		expect(navs).toHaveLength(2);
		const drawer = document.getElementById("site-nav-drawer");
		expect(drawer).not.toBeNull();
		return drawer as HTMLElement;
	}

	it("默认无抽屉；点击菜单按钮展开：含全部公开导航、登录、加入我们、语言切换", () => {
		render(<SiteHeader active="events" />);
		expect(screen.getAllByRole("navigation", { name: "主导航" })).toHaveLength(1);

		const drawer = openDrawer();
		// 抽屉内导航与桌面同源同序（只取抽屉导航内链接，不含抽屉登录/注册区）
		const drawerNav = within(drawer).getByRole("navigation", { name: "主导航" });
		expect(
			Array.from(drawerNav.querySelectorAll("a")).map((a) =>
				a.textContent.trim(),
			),
		).toEqual([
			"Hacker Start 1024",
			"活动",
			"课程",
			"倡导活动",
			"闪念间",
			"金句墙",
			"许愿树",
		]);
		// active 态在抽屉中同步
		expect(
			within(drawer).getByRole("link", { name: "活动" }),
		).toHaveAttribute("aria-current", "page");
		// 匿名：抽屉提供登录（带 next 回跳）与加入我们
		expect(
			within(drawer).getByRole("link", { name: /登录/ }),
		).toHaveAttribute(
			"href",
			`/login?next=${encodeURIComponent("/events/1024-changsha-01")}`,
		);
		expect(
			within(drawer).getByRole("link", { name: /加入我们/ }),
		).toHaveAttribute(
			"href",
			`/register?next=${encodeURIComponent("/events/1024-changsha-01")}`,
		);
		// 语言切换在抽屉中可达（桌面/抽屉各一组）
		expect(
			within(drawer).getByRole("group", { name: "语言" }),
		).toBeInTheDocument();
	});

	it("再点菜单按钮 / 按 Escape 均收起抽屉", () => {
		render(<SiteHeader active="events" />);
		openDrawer();
		fireEvent.click(screen.getByRole("button", { name: "菜单" }));
		expect(screen.getAllByRole("navigation", { name: "主导航" })).toHaveLength(1);

		openDrawer();
		fireEvent.keyDown(document, { key: "Escape" });
		expect(screen.getAllByRole("navigation", { name: "主导航" })).toHaveLength(1);
		expect(screen.getByRole("button", { name: "菜单" })).toHaveAttribute(
			"aria-expanded",
			"false",
		);
	});

	it("已登录：抽屉含我的报名/我的学习与工作台，无登录入口", () => {
		useAuthed.mockReturnValue({ authed: true, confirmed: true });
		render(<SiteHeader active="events" />);
		const drawer = openDrawer();
		expect(
			within(drawer).getByRole("link", { name: "我的报名" }),
		).toHaveAttribute("href", "/participations");
		expect(
			within(drawer).getByRole("link", { name: "我的学习" }),
		).toHaveAttribute("href", "/learning");
		expect(
			within(drawer).getByRole("link", { name: "工作台" }),
		).toBeInTheDocument();
		expect(
			within(drawer).queryByRole("link", { name: /登录/ }),
		).not.toBeInTheDocument();
	});

	it("路径变化（页面跳转）后抽屉自动收起", () => {
		const { rerender } = render(<SiteHeader active="events" />);
		openDrawer();
		pathnameRef.value = "/courses";
		rerender(<SiteHeader active="events" />);
		expect(screen.getAllByRole("navigation", { name: "主导航" })).toHaveLength(1);
	});
});
