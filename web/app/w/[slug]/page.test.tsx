import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { screen, cleanup, fireEvent, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import WorkspacePage from "./page";

/** 测试本地 fixture（#1 mock 已删除；页面只消费 fetchMyWorkspaces 返回值） */
const TEST_WORKSPACES = [
	{
		id: "ws_02",
		slug: "cgc-academy",
		name: "CGC 线上学院",
		joinPolicy: "request" as const,
		sponsorshipEnabled: true,
		myRoleNames: ["admin"],
		roles: ["admin"],
		myAbilities: [
			"view_workspace",
			"access_invite_only",
			"list_members",
			"manage_members",
			"assign_roles",
			"update_join_policy",
		],
		membershipStatus: "active" as const,
		memberCount: 342,
	},
	{
		id: "ws_01",
		slug: "cgc-shanghai",
		name: "CGC 上海分社",
		joinPolicy: "open" as const,
		sponsorshipEnabled: true,
		myRoleNames: ["member"],
		roles: ["member"],
		myAbilities: ["view_workspace", "access_invite_only"],
		membershipStatus: "active" as const,
		memberCount: 128,
	},
];

const { push, replace } = vi.hoisted(() => ({
	push: vi.fn(),
	replace: vi.fn(),
}));
const { isAuthenticated, clearSession } = vi.hoisted(() => ({
	isAuthenticated: vi.fn(),
	clearSession: vi.fn(),
}));
const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));

vi.mock("@/lib/use-authed", () => ({ useAuthed }));
const { params } = vi.hoisted(() => ({
	params: { value: { slug: "cgc-academy" } },
}));
const { fetchCurrentProfile } = vi.hoisted(() => ({
	fetchCurrentProfile: vi.fn(),
}));
const { fetchMyWorkspaces } = vi.hoisted(() => ({
	fetchMyWorkspaces: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	useRouter: () => ({ push, replace }),
	useParams: () => params.value,
	// 壳导航激活态由 pathname 派生：概览页 pathname 精确等于 /w/${slug}
	usePathname: () => `/w/${params.value.slug}`,
}));

vi.mock("@/lib/auth", () => ({
	isAuthenticated,
	clearAuthToken: vi.fn(),
	clearSession,
}));

vi.mock("@/lib/profile", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchCurrentProfile };
});

vi.mock("@/lib/workspaces", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return {
		...mod,
		// #70 QA P1：工作区上下文经 useWorkspaceBySlug → fetchMyWorkspaces 解析
		fetchMyWorkspaces,
	};
});

beforeEach(() => {
	vi.clearAllMocks();
	isAuthenticated.mockReturnValue(true);
	useAuthed.mockReturnValue({ authed: true, confirmed: true });
	params.value = { slug: "cgc-academy" };
	fetchMyWorkspaces.mockResolvedValue(TEST_WORKSPACES);
	fetchCurrentProfile.mockResolvedValue({
		id: "u_0202",
		email: "xiaomei@example.com",
		displayName: "小美",
		avatarUrl: null,
		isPlatformAdmin: false,
	});
	// #018：clearSession 返回 { ok } 契约；失败用例单独覆盖
	clearSession.mockResolvedValue({ ok: true });
});

afterEach(cleanup);

/**
 * 等壳内内容就绪（heading 渲染说明壳已过未认证态），返回 main 内容查询域。
 * 侧栏（品牌 / 当前 Workspace / 导航）在 main 之外，内容断言统一走 main，
 * 避免与侧栏同文案（ws.name / ws.slug）撞查询。
 */
async function content() {
	await screen.findByRole("heading", { name: "工作区概览" });
	return within(screen.getByRole("main"));
}

describe("工作区概览页 /w/[slug] (#74)", () => {
	it("未登录：重定向 /login", async () => {
		isAuthenticated.mockReturnValue(false);
		useAuthed.mockReturnValue({ authed: false, confirmed: true });
		render(<WorkspacePage />);
		await waitFor(() => expect(replace).toHaveBeenCalledWith("/login"));
	});

	it("按 slug 匹配：展示名称/slug/加入方式/赞助状态", async () => {
		render(<WorkspacePage />);
		const main = await content();
		// 工作区名出现在面包屑链接与 Hero h2（面包屑 IA 统一后两处）
		expect(main.getAllByText("CGC 线上学院").length).toBeGreaterThan(0);
		expect(main.getByText("cgc-academy")).toBeInTheDocument();
		// 加入方式 label 在 Hero 与信息卡各出现一次
		expect(main.getAllByText("申请审批").length).toBeGreaterThan(0);
		expect(main.getByText("已开放赞助")).toBeInTheDocument();
	});

	it("未知 slug：展示「工作区不可访问」+ 返回工作台（不再有建设中占位）", async () => {
		params.value = { slug: "not-exist" };
		render(<WorkspacePage />);
		expect(await screen.findByText("工作区不可访问")).toBeInTheDocument();
		expect(screen.getByText(/不存在或你没有访问权限/)).toBeInTheDocument();
		const back = screen.getByRole("link", { name: "返回工作台" });
		expect(back).toHaveAttribute("href", "/");
		expect(screen.queryByText(/建设中/)).not.toBeInTheDocument();
		expect(TEST_WORKSPACES.length).toBeGreaterThan(0); // 引用 fixture 防 tree-shake
	});

	it("真实模式（#70 QA P1）：fetchMyWorkspaces 返回真实 ws（不在 mock），详情页按真实数据渲染", async () => {
		fetchMyWorkspaces.mockResolvedValue([
			{
				id: "ws_real_detail",
				slug: "qa70-real-ws-333",
				name: "QA70 真实详情工作区",
				joinPolicy: "invite_only",
				sponsorshipEnabled: false,
				myRoleNames: ["member"],
				roles: ["member"],
				membershipStatus: "active",
				memberCount: 42,
			},
		]);
		params.value = { slug: "qa70-real-ws-333" };

		render(<WorkspacePage />);
		const main = await content();
		// 不再显示「建设中」，展示真实工作区信息
		// 工作区名出现在面包屑链接与 Hero h2
		expect(main.getAllByText("QA70 真实详情工作区").length).toBeGreaterThan(0);
		expect(main.getByText("qa70-real-ws-333")).toBeInTheDocument();
		expect(main.getAllByText("仅邀请").length).toBeGreaterThan(0);
		expect(main.getByText("暂未开放赞助")).toBeInTheDocument();
		expect(screen.queryByText(/建设中/)).not.toBeInTheDocument();
		// 成员管理入口指向真实 slug（无 assign_roles 能力 → 只读门控文案）
		const link = main.getByRole("link", {
			name: /查看成员列表与自己的角色/,
		});
		expect(link).toHaveAttribute("href", "/w/qa70-real-ws-333/settings/members");
	});

	it("P1：展示成员数量（meWorkspaces memberCount 计算字段）", async () => {
		fetchMyWorkspaces.mockResolvedValue([
			{
				id: "ws_mc",
				slug: "qa70-count-ws",
				name: "成员数工作区",
				joinPolicy: "open",
				sponsorshipEnabled: true,
				myRoleNames: ["member"],
				roles: ["member"],
				membershipStatus: "active",
				memberCount: 12,
			},
		]);
		params.value = { slug: "qa70-count-ws" };

		render(<WorkspacePage />);
		expect(
			await screen.findByTestId("workspace-member-count"),
		).toHaveTextContent("12 位成员");
	});

	it("提供返回工作台链接（面包屑）", async () => {
		render(<WorkspacePage />);
		const back = await screen.findByRole("link", { name: "工作台" });
		expect(back).toHaveAttribute("href", "/");
	});

	it("提供成员管理入口链接到 /w/[slug]/members（canAssign 门控 true）", async () => {
		render(<WorkspacePage />);
		const link = await screen.findByRole("link", {
			name: /管理成员列表与角色分配/,
		});
		expect(link).toHaveAttribute("href", "/w/cgc-academy/settings/members");
	});

	it("壳导航「概览」选中（aria-current=page）", async () => {
		render(<WorkspacePage />);
		const nav = await screen.findByRole("navigation", {
			name: "工作区导航",
		});
		const overview = within(nav).getByRole("link", { name: "概览" });
		expect(overview).toHaveAttribute("href", "/w/cgc-academy");
		expect(overview).toHaveAttribute("aria-current", "page");
	});

	it("壳导航 IA：工作区导航组仅 概览（成员/设置已迁入 settings 页）", async () => {
		render(<WorkspacePage />);
		const nav = await screen.findByRole("navigation", {
			name: "工作区导航",
		});
		// 工作区导航组：仅概览
		expect(within(nav).getByRole("link", { name: "概览" })).toBeInTheDocument();
		expect(
			within(nav).queryByRole("link", { name: "成员与角色" }),
		).not.toBeInTheDocument();
		// 设置项已迁入 settings 页（下拉框 Settings 入口），非 settings 路由不再渲染
		expect(
			screen.queryByRole("navigation", { name: "设置" }),
		).not.toBeInTheDocument();
		expect(
			screen.queryByRole("link", { name: "加入策略" }),
		).not.toBeInTheDocument();
		expect(
			screen.queryByRole("link", { name: "加入审批" }),
		).not.toBeInTheDocument();
		expect(
			screen.queryByRole("link", { name: "邀请管理" }),
		).not.toBeInTheDocument();
		expect(
			screen.queryByRole("link", { name: "个人资料" }),
		).not.toBeInTheDocument();
		// footer 已删（ProfileEntry 迁入 settings）
		expect(screen.queryByTestId("profile-entry")).not.toBeInTheDocument();
	});

	it("壳导航权限过滤（#79）：普通成员仅见 概览", async () => {
		params.value = { slug: "cgc-shanghai" };
		render(<WorkspacePage />);
		const nav = await screen.findByRole("navigation", {
			name: "工作区导航",
		});
		// 管理项不渲染
		expect(
			within(nav).queryByRole("link", { name: "成员与角色" }),
		).not.toBeInTheDocument();
		// 概览仍在；设置项已迁入 settings 页
		expect(within(nav).getByRole("link", { name: "概览" })).toBeInTheDocument();
		expect(
			screen.queryByRole("navigation", { name: "设置" }),
		).not.toBeInTheDocument();
	});

	it("展示我的角色 chips（Admin，Hero 与信息卡各一处）", async () => {
		render(<WorkspacePage />);
		const main = await content();
		expect((await main.findAllByText("Admin")).length).toBeGreaterThan(0);
	});

	it("提供权限映射入口链接到 /w/[slug]/permissions", async () => {
		render(<WorkspacePage />);
		const link = await screen.findByRole("link", { name: /权限映射/ });
		expect(link).toHaveAttribute("href", "/w/cgc-academy/settings/permissions");
	});

	it("Workflow 产出为真实链接卡（切片 C 已落地，plan 016 替换过期占位卡）", async () => {
		render(<WorkspacePage />);
		const main = await content();
		const link = main.getByRole("link", { name: /Workflow 产出/ });
		expect(link).toHaveAttribute("href", "/w/cgc-academy/workflows");
		// 报名/赞助（切片 E）仍为 aria-disabled 占位卡
		const placeholder = main.getByText("报名 / 赞助");
		expect(placeholder.closest("[aria-disabled='true']")).not.toBeNull();
		expect(main.queryByRole("link", { name: /报名/ })).not.toBeInTheDocument();
	});

	it("canAssign=false：成员与角色入口显示只读门控文案", async () => {
		params.value = { slug: "cgc-shanghai" };
		render(<WorkspacePage />);
		const main = await content();
		expect(
			await main.findByText("查看成员列表与自己的角色"),
		).toBeInTheDocument();
		expect(main.queryByText("管理成员列表与角色分配")).not.toBeInTheDocument();
	});

	it("品牌下拉菜单：一级操作项 + Switch workspace 展开二级工作区列表", async () => {
		render(<WorkspacePage />);
		await content();
		// 打开 dropdown
		fireEvent.click(
			screen.getByRole("button", { name: "CGC 线上学院 Workspace Menu" }),
		);
		const menu = await screen.findByRole("menu");
		// 一级：操作项
		expect(
			within(menu).getByRole("menuitem", { name: "Settings" }),
		).toHaveAttribute("href", "/w/cgc-academy/settings/account/preferences");
		expect(
			within(menu).getByRole("menuitem", { name: "邀请管理" }),
		).toHaveAttribute("href", "/w/cgc-academy/settings/invitations");
		// 一级：Switch workspace + 退出登录；工作区列表在二级，一级不可见
		expect(
			within(menu).getByRole("menuitem", { name: "Switch workspace" }),
		).toBeInTheDocument();
		expect(
			within(menu).queryByText("xiaomei@example.com"),
		).not.toBeInTheDocument();

		// 展开二级
		fireEvent.click(
			within(menu).getByRole("menuitem", { name: "Switch workspace" }),
		);
		// 二级：邮箱行可见（一级不可见的标志内容现在出现）
		const email = await screen.findByText("xiaomei@example.com");
		const sub = email.closest("[role='menu']") as HTMLElement;
		expect(sub).not.toBe(menu);
		// 工作区项：名称 + 当前项 ✓
		expect(
			within(sub).getByRole("menuitem", { name: /CGC 线上学院/ }),
		).toHaveAttribute("href", "/w/cgc-academy");
		expect(
			within(sub).getByRole("menuitem", { name: /CGC 上海分社/ }),
		).toHaveAttribute("href", "/w/cgc-shanghai");
		expect(within(sub).getByText("✓")).toBeInTheDocument();
		// 操作项
		expect(
			within(sub).getByRole("menuitem", { name: "发现 / 加入工作区" }),
		).toHaveAttribute("href", "/join");
		// 个人资料已迁入 settings（Personal 组），菜单不再重复
		expect(
			within(sub).queryByRole("menuitem", { name: "个人资料" }),
		).not.toBeInTheDocument();
		// 退出登录触发 clearSession + 跳转（一级）
		fireEvent.click(
			within(menu).getByRole("menuitem", { name: "退出登录" }),
		);
		await waitFor(() => expect(clearSession).toHaveBeenCalledTimes(1));
		await waitFor(() => expect(push).toHaveBeenCalledWith("/login"));
	});

	it("登出失败（#018）：不导航 /login，菜单内渲染错误文案可重试", async () => {
		render(<WorkspacePage />);
		await content();
		fireEvent.click(
			screen.getByRole("button", { name: "CGC 线上学院 Workspace Menu" }),
		);
		const menu = await screen.findByRole("menu");
		clearSession.mockResolvedValue({ ok: false, error: new Error("boom") });

		fireEvent.click(within(menu).getByRole("menuitem", { name: "退出登录" }));

		// mutation 失败 → clearSession 被调但不导航，错误文案渲染在菜单内
		await waitFor(() => expect(clearSession).toHaveBeenCalledTimes(1));
		expect(push).not.toHaveBeenCalled();
		expect(await screen.findByText("退出登录失败，请重试")).toBeInTheDocument();
	});
});
