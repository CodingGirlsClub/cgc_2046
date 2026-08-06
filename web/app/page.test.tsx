import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
	screen,
	fireEvent,
	cleanup,
	waitFor,
} from "@testing-library/react";
import { render } from "@/test-utils";
import HomePage from "./page";

/** 测试本地工作台 fixture（#1 mock 已删除） */
const TEST_WORKSPACES = [
	{
		id: "ws_01",
		slug: "cgc-shanghai",
		name: "CGC 上海分社",
		joinPolicy: "open" as const,
		sponsorshipEnabled: true,
		description: "上海线下活动 + 线上学院课程，面向全平台开放加入。",
		memberCount: 128,
		unreadCount: 3,
		myRoleNames: ["member"],
		roles: ["member"],
		myAbilities: ["view_workspace", "access_invite_only"],
		membershipStatus: "active" as const,
	},
	{
		id: "ws_02",
		slug: "cgc-academy",
		name: "CGC 线上学院",
		joinPolicy: "request" as const,
		sponsorshipEnabled: true,
		description: "系统化编程课程与教研中心，需申请审批后加入。",
		memberCount: 342,
		unreadCount: 0,
		myRoleNames: ["admin"],
		roles: ["admin"],
		myAbilities: [
			"view_workspace",
			"access_invite_only",
			"list_members",
			"manage_members",
			"assign_roles",
		],
		membershipStatus: "active" as const,
	},
	{
		id: "ws_03",
		slug: "cgc-sponsor-hub",
		name: "赞助商俱乐部",
		joinPolicy: "invite_only" as const,
		sponsorshipEnabled: false,
		description: "核心赞助商私密空间，仅凭邀请加入。",
		memberCount: 24,
		unreadCount: 0,
		myRoleNames: [],
		roles: [],
		myAbilities: [],
		membershipStatus: "invited" as const,
	},
];

/**
 * 工作台页测试（#63 / #83）。
 * mock：useRouter（next/navigation）、useAuthed、clearSession、fetchMyWorkspaces、
 * fetchCurrentProfile、apollo client（ThemeToggle fire-and-forget 持久化用）。
 * #83：侧栏 nav item 改为 <Link href="/w/:slug">，首页为 Hub 占位，不再内联详情。
 */

const { push, replace } = vi.hoisted(() => ({
	push: vi.fn(),
	replace: vi.fn(),
}));
const { clearSession } = vi.hoisted(() => ({
	clearSession: vi.fn(),
}));

const { useAuthed } = vi.hoisted(() => ({
	useAuthed: vi.fn(),
}));
const { fetchMyWorkspaces } = vi.hoisted(() => ({
	fetchMyWorkspaces: vi.fn(),
}));
const { fetchCurrentProfile } = vi.hoisted(() => ({
	fetchCurrentProfile: vi.fn(),
}));
const { mutate } = vi.hoisted(() => ({ mutate: vi.fn().mockResolvedValue({}) }));

vi.mock("@/lib/use-authed", () => ({
	useAuthed,
}));
vi.mock("next/navigation", () => ({
	useRouter: () => ({ push, replace }),
}));

vi.mock("@/lib/auth", () => ({
	clearSession,
}));

vi.mock("@/lib/workspaces", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchMyWorkspaces };
});

vi.mock("@/lib/profile", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchCurrentProfile };
});

vi.mock("@/lib/apollo-client", () => ({
	client: { mutate },
}));

beforeEach(() => {
	vi.clearAllMocks();
	window.history.replaceState({}, "", "/");
	useAuthed.mockReturnValue({ authed: true, confirmed: true });
	fetchMyWorkspaces.mockResolvedValue(TEST_WORKSPACES);
	fetchCurrentProfile.mockResolvedValue({
		id: "u_0202",
		email: "xiaomei@example.com",
		displayName: "小美",
		avatarUrl: null,
		isPlatformAdmin: false,
	});
	mutate.mockResolvedValue({});
});

afterEach(cleanup);

describe("工作台页 (#63 #83)", () => {
	it("未登录：重定向 /login，不渲染列表", async () => {
		useAuthed.mockReturnValue({ authed: false, confirmed: true });
		render(<HomePage />);
		await waitFor(() => expect(replace).toHaveBeenCalledWith("/login"));
		expect(fetchMyWorkspaces).not.toHaveBeenCalled();
	});

	it("默认展示侧栏 + Hub 占位（#83：不再内联工作区详情）", async () => {
		render(<HomePage />);

		expect(
			await screen.findByRole("heading", { name: "工作台" }),
		).toBeInTheDocument();
		// Hub 占位文案
		expect(
			screen.getByText("从左侧选择一个工作区开始"),
		).toBeInTheDocument();
		// 侧栏品牌可点回首页
		expect(screen.getByRole("link", { name: "CGC 2046" })).toHaveAttribute(
			"href",
			"/",
		);
	});

	it("侧栏 nav item 为 Link 跳 /w/:slug（#83：URL 即资源）", async () => {
		render(<HomePage />);
		await screen.findByRole("heading", { name: "工作台" });

		const shanghaiLink = screen.getByRole("link", {
			name: /CGC 上海分社/,
		});
		expect(shanghaiLink).toHaveAttribute("href", "/w/cgc-shanghai");

		const academyLink = screen.getByRole("link", {
			name: /CGC 线上学院/,
		});
		expect(academyLink).toHaveAttribute("href", "/w/cgc-academy");
	});

	it("侧栏显示活跃工作区计数与待处理数", async () => {
		fetchMyWorkspaces.mockResolvedValue([
			{
				id: "ws_a",
				slug: "real-a",
				name: "真实工作区 A",
				joinPolicy: "open",
				sponsorshipEnabled: true,
				myRoleNames: ["owner"],
				roles: ["owner"],
				membershipStatus: "active",
			},
			{
				id: "ws_c",
				slug: "real-c",
				name: "真实工作区 C",
				joinPolicy: "request",
				sponsorshipEnabled: true,
				myRoleNames: [],
				roles: [],
				myMembershipId: "wm_p",
				membershipStatus: "pending",
			},
		]);

		render(<HomePage />);
		expect(
			await screen.findByText("你加入了 1 个工作区 · 1 个待处理"),
		).toBeInTheDocument();
	});

	it("view=grid：展示首次登录卡片网格，只有 active 可进入", async () => {
		window.history.replaceState({}, "", "/?view=grid");
		fetchMyWorkspaces.mockResolvedValue([
			{
				...TEST_WORKSPACES[0],
				name: "上海 Coding Girls Club",
				slug: "shanghai-cgc",
				membershipStatus: "active",
			},
			{
				...TEST_WORKSPACES[1],
				name: "北京 Women in AI",
				slug: "beijing-wai",
				membershipStatus: "pending",
				myRoleNames: [],
				roles: [],
			},
			{
				...TEST_WORKSPACES[2],
				name: "杭州创客空间",
				slug: "hangzhou-makers",
				membershipStatus: "invited",
			},
		]);
		render(<HomePage />);

		expect(
			await screen.findByRole("heading", { name: "选择你的工作区" }),
		).toBeInTheDocument();
		expect(screen.getAllByText("active")).toHaveLength(1);
		expect(screen.getByText("pending")).toBeInTheDocument();
		expect(screen.getByText("invited")).toBeInTheDocument();
		expect(screen.getAllByRole("link", { name: "进入工作台" })).toHaveLength(1);
		expect(
			screen.getByRole("link", { name: /发现 \/ 申请加入新工作区/ }),
		).toBeInTheDocument();
	});

	it("退出登录：清 token 并跳转 /login", async () => {
		render(<HomePage />);
		const signOut = await screen.findByRole("button", { name: "退出登录" });
		fireEvent.click(signOut);
		expect(clearSession).toHaveBeenCalledTimes(1);
		await waitFor(() => expect(push).toHaveBeenCalledWith("/login"));
	});

	it("加载失败：展示错误态与重试，不混淆为真实空数据", async () => {
		fetchMyWorkspaces.mockRejectedValueOnce(new Error("network down"));
		render(<HomePage />);

		expect(await screen.findByRole("alert")).toBeInTheDocument();
		expect(screen.getByText("工作区加载失败")).toBeInTheDocument();
		expect(
			screen.queryByText("从左侧选择一个工作区开始"),
		).not.toBeInTheDocument();

		// 重试成功：回到 Hub
		fireEvent.click(screen.getByRole("button", { name: "重试" }));
		expect(
			await screen.findByRole("heading", { name: "工作台" }),
		).toBeInTheDocument();
		expect(screen.queryByRole("alert")).not.toBeInTheDocument();
	});

	it("提供个人资料入口链接到 settings (#69)", async () => {
		render(<HomePage />);
		const entry = await screen.findByTestId("profile-entry");
		expect(entry).toHaveAttribute("href", "/settings/account/profile");
		expect(await screen.findByText("小美")).toBeInTheDocument();
	});

	it("品牌区链接回首页（#83：补回首页入口）", async () => {
		render(<HomePage />);
		const brand = await screen.findByRole("link", { name: "CGC 2046" });
		expect(brand).toHaveAttribute("href", "/");
	});

	it("发现项链接到 /join（侧栏 + Hub 占位各一处）", async () => {
		render(<HomePage />);
		await screen.findByRole("heading", { name: "工作台" });
		const discoverLinks = screen.getAllByRole("link", {
			name: /发现 \/ 申请加入新工作区/,
		});
		expect(discoverLinks.length).toBeGreaterThanOrEqual(1);
		for (const link of discoverLinks) {
			expect(link).toHaveAttribute("href", "/join");
		}
	});
});