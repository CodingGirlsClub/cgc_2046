import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
	render,
	screen,
	fireEvent,
	cleanup,
	waitFor,
} from "@testing-library/react";
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
 * 工作台页测试（#63）。
 * mock：useRouter（next/navigation）、isAuthenticated（lib/auth）、fetchMyWorkspaces（lib/workspaces）。
 */

const { push, replace } = vi.hoisted(() => ({
	push: vi.fn(),
	replace: vi.fn(),
}));
const { isAuthenticated, clearAuthToken, clearSession } = vi.hoisted(() => ({
	isAuthenticated: vi.fn(),
	clearAuthToken: vi.fn(),
	clearSession: vi.fn(),
}));

const { useAuthed } = vi.hoisted(() => ({
	useAuthed: vi.fn(),
}));

vi.mock("@/lib/use-authed", () => ({
	useAuthed,
}));
const { fetchMyWorkspaces } = vi.hoisted(() => ({
	fetchMyWorkspaces: vi.fn(),
}));
const { fetchCurrentProfile } = vi.hoisted(() => ({
	fetchCurrentProfile: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	useRouter: () => ({ push, replace }),
}));

vi.mock("@/lib/auth", () => ({
	isAuthenticated,
	clearAuthToken,
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

beforeEach(() => {
	vi.clearAllMocks();
	window.history.replaceState({}, "", "/");
	isAuthenticated.mockReturnValue(true);
	useAuthed.mockReturnValue({ authed: true, confirmed: true });
	fetchMyWorkspaces.mockResolvedValue(TEST_WORKSPACES);
	fetchCurrentProfile.mockResolvedValue({
		id: "u_0202",
		email: "xiaomei@example.com",
		displayName: "小美",
		avatarUrl: null,
		isPlatformAdmin: false,
	});
});

afterEach(cleanup);

describe("工作台页 (#63)", () => {
	it("未登录：重定向 /login，不渲染列表", async () => {
		isAuthenticated.mockReturnValue(false);
		useAuthed.mockReturnValue({ authed: false, confirmed: true });
		render(<HomePage />);
		await waitFor(() => expect(replace).toHaveBeenCalledWith("/login"));
		expect(fetchMyWorkspaces).not.toHaveBeenCalled();
	});

	it("默认展示侧栏 + active 工作区详情", async () => {
		render(<HomePage />);

		expect(
			await screen.findByRole("heading", { name: "工作区详情" }),
		).toBeInTheDocument();
		expect(screen.getAllByText("CGC 上海分社")).toHaveLength(2);
		expect(screen.getByText("cgc-shanghai")).toBeInTheDocument();
		expect(screen.getAllByText("开放加入").length).toBeGreaterThanOrEqual(1);
		expect(screen.getByText("最近动态")).toBeInTheDocument();
		expect(screen.getByRole("link", { name: /进入工作台/ })).toHaveAttribute(
			"href",
			"/w/cgc-shanghai",
		);
		expect(screen.getByRole("link", { name: /成员与角色/ })).toHaveAttribute(
			"href",
			"/w/cgc-shanghai/members",
		);
	});

	it("点击侧栏工作区后，详情区跟随切换", async () => {
		render(<HomePage />);
		await screen.findByText("最近动态");

		fireEvent.click(screen.getByRole("button", { name: /CGC 线上学院/ }));
		expect(screen.getAllByText("CGC 线上学院")).toHaveLength(2);
		expect(screen.getAllByText("申请制").length).toBeGreaterThanOrEqual(1);
		expect(screen.getByRole("link", { name: /进入工作台/ })).toHaveAttribute(
			"href",
			"/w/cgc-academy",
		);
	});

	it("选择 invited workspace：展示待凭据状态，不显示进入入口", async () => {
		render(<HomePage />);
		await screen.findByText("最近动态");

		fireEvent.click(screen.getByRole("button", { name: /赞助商俱乐部/ }));
		expect(screen.getAllByText("待凭据加入").length).toBeGreaterThanOrEqual(2);
		expect(screen.getByText("邀请制")).toBeInTheDocument();
		expect(
			screen.queryByRole("link", { name: /进入工作台/ }),
		).not.toBeInTheDocument();
		expect(screen.getByRole("button", { name: "输入邀请凭据" })).toBeDisabled();
	});

	it("角色标签复用共享 ROLE_LABEL：tutor/volunteer/learner 渲染规范名（P2-3）", async () => {
		fetchMyWorkspaces.mockResolvedValue([
			{
				id: "ws_roles",
				slug: "roles-demo",
				name: "角色演示工作区",
				joinPolicy: "open",
				sponsorshipEnabled: true,
				myRoleNames: ["tutor", "volunteer", "learner"],
				roles: ["tutor", "volunteer", "learner"],
				membershipStatus: "active",
			},
		]);
		render(<HomePage />);

		expect(
			await screen.findByText("Tutor / Volunteer / Learner"),
		).toBeInTheDocument();
		expect(screen.queryByText("tutor")).not.toBeInTheDocument();
		expect(screen.queryByText("volunteer")).not.toBeInTheDocument();
		expect(screen.queryByText("learner")).not.toBeInTheDocument();
	});

	it("真实模式：active / pending 状态跟随侧栏选择", async () => {
		fetchMyWorkspaces.mockResolvedValue([
			{
				id: "ws_real_a",
				slug: "real-a",
				name: "真实工作区 A",
				joinPolicy: "open",
				sponsorshipEnabled: true,
				myRoleNames: ["owner"],
				roles: ["owner"],
				membershipStatus: "active",
			},
			{
				id: "ws_real_b",
				slug: "real-b",
				name: "真实工作区 B",
				joinPolicy: "request",
				sponsorshipEnabled: true,
				myRoleNames: ["member"],
				roles: ["member"],
				membershipStatus: "active",
			},
			{
				id: "ws_real_c",
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
			await screen.findByText("你加入了 2 个工作区 · 1 个待处理"),
		).toBeInTheDocument();
		expect(screen.getByRole("link", { name: /进入工作台/ })).toHaveAttribute(
			"href",
			"/w/real-a",
		);

		fireEvent.click(screen.getByRole("button", { name: /真实工作区 C/ }));
		expect(screen.getByText("申请进度")).toBeInTheDocument();
		expect(screen.getAllByText("申请审批中").length).toBeGreaterThanOrEqual(2);
		expect(
			screen.queryByRole("link", { name: /进入工作台/ }),
		).not.toBeInTheDocument();
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
			screen.getByRole("button", { name: /发现 \/ 申请加入新工作区/ }),
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
		expect(screen.queryByText("还没有可进入的工作区")).not.toBeInTheDocument();

		// 重试成功：回到工作台侧栏
		fireEvent.click(screen.getByRole("button", { name: "重试" }));
		expect(
			await screen.findByRole("heading", { name: "工作区详情" }),
		).toBeInTheDocument();
		expect(screen.queryByRole("alert")).not.toBeInTheDocument();
	});

	it("提供个人资料入口链接到 /profile (#69)", async () => {
		render(<HomePage />);
		const entry = await screen.findByTestId("profile-entry");
		expect(entry).toHaveAttribute("href", "/profile");
		expect(await screen.findByText("小美")).toBeInTheDocument();
	});
});
