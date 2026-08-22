import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { screen, cleanup, fireEvent, waitFor, within, act } from "@testing-library/react";
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
		myRoleNames: [],
		roles: [],
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
const { fetchWorkspaceBySlug } = vi.hoisted(() => ({
	fetchWorkspaceBySlug: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
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
vi.mock("@/lib/requests", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchWorkspaceBySlug };
});

// 首公里 onboarding（plan first-mile-onboarding U3）：页面消费 useOnboardingState +
// KTD4 session 旗标 + dismiss mutation，全部 mock 以保证门控矩阵确定性
const { useOnboardingState } = vi.hoisted(() => ({ useOnboardingState: vi.fn() }));
const { markInviteShown } = vi.hoisted(() => ({ markInviteShown: vi.fn() }));
const { dismissOnboardingInvitation } = vi.hoisted(() => ({
	dismissOnboardingInvitation: vi.fn(),
}));

vi.mock("@/lib/onboarding", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return {
		...mod,
		useOnboardingState,
		markInviteShown,
		dismissOnboardingInvitation,
	};
});

/** onboarding 就绪基线：未接入/未拒绝/未通联/本 session 未展示 */
const ONBOARDING_BASE = {
	dismissed: false,
	hasActiveToken: false,
	connected: false,
	loading: false,
	error: null,
	userId: "u_0202",
	inviteShownThisSession: false,
	// 等待首联态会挂 effect 调 refreshSilently；base 给空实现保 mock 拟真
	refreshSilently: vi.fn(),
};

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
	fetchWorkspaceBySlug.mockReset();
	// onboarding 默认 loading（fail-closed）：既有用例零感知——不弹模态、不挂卡
	useOnboardingState.mockReturnValue({ ...ONBOARDING_BASE, loading: true });
	dismissOnboardingInvitation.mockResolvedValue(undefined);
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

	it("非成员 PlatformAdmin：fallback 到 workspace 并渲染只读审计页", async () => {
		params.value = { slug: "audit-ws" };
		fetchMyWorkspaces.mockResolvedValue([]);
		fetchCurrentProfile.mockResolvedValue({
			id: "u-admin",
			email: "admin@example.com",
			displayName: "Platform Admin",
			isPlatformAdmin: true,
		});
		fetchWorkspaceBySlug.mockResolvedValue({
			id: "ws-audit",
			slug: "audit-ws",
			name: "审计工作台",
			joinPolicy: "invite_only",
			sponsorshipEnabled: true,
			sponsorshipTiers: ['{"name":"金牌","amount":1000}'],
			memberCount: 42,
		});
		render(<WorkspacePage />);

		const main = await content();

		expect(main.getByRole("heading", { name: "工作区概览" })).toBeInTheDocument();
		expect(screen.getByRole("status")).toHaveTextContent(
			"平台管理员 · 只读审计视图",
		);
		expect(main.getByTestId("workspace-member-count")).toHaveTextContent("42 位成员");
		expect(main.getByText("已开放赞助")).toBeInTheDocument();
		expect(fetchWorkspaceBySlug).toHaveBeenCalledWith("audit-ws");

	});
	it("真实模式（#70 QA P1）：fetchMyWorkspaces 返回真实 ws（不在 mock），详情页按真实数据渲染", async () => {
		fetchMyWorkspaces.mockResolvedValue([
			{
				id: "ws_real_detail",
				slug: "qa70-real-ws-333",
				name: "QA70 真实详情工作区",
				joinPolicy: "invite_only",
				sponsorshipEnabled: false,
				myRoleNames: [],
				roles: [],
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
		// 无 list_members 能力 → 管理入口卡整卡不渲染（与侧栏同源门控）
		expect(main.queryByText("成员与角色")).not.toBeInTheDocument();
		expect(main.queryByText("权限映射")).not.toBeInTheDocument();
	});

	it("P1：展示成员数量（meWorkspaces memberCount 计算字段）", async () => {
		fetchMyWorkspaces.mockResolvedValue([
			{
				id: "ws_mc",
				slug: "qa70-count-ws",
				name: "成员数工作区",
				joinPolicy: "open",
				sponsorshipEnabled: true,
				myRoleNames: [],
				roles: [],
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

	it("Workflow 产出、活动与课程为真实链接卡（切片 C/E 已落地，plan 016 替换过期占位卡）", async () => {
		render(<WorkspacePage />);
		const main = await content();
		const link = main.getByRole("link", { name: /Workflow 产出/ });
		expect(link).toHaveAttribute("href", "/w/cgc-academy/workflows");
		const agentsLink = main.getByRole("link", { name: /Agents 与助手协作/ });
		expect(agentsLink).toHaveAttribute("href", "/w/cgc-academy/agents");
		// plan 020 U1 新增 Agents 卡后 /活动/ 会同时命中「查看助手活动…」——锚定卡片名前缀
		const eventsLink = main.getByRole("link", { name: /^活动/ });
		expect(eventsLink).toHaveAttribute("href", "/w/cgc-academy/events");
		const coursesLink = main.getByRole("link", { name: /课程/ });
		expect(coursesLink).toHaveAttribute("href", "/w/cgc-academy/courses");
		expect(main.queryByText("报名 / 赞助")).not.toBeInTheDocument();
		expect(main.queryByText(/切片 E|即将开放|草稿/)).not.toBeInTheDocument();
		expect(eventsLink).toHaveTextContent("活动");
		expect(eventsLink).toHaveTextContent("报名");
		expect(eventsLink.textContent).not.toMatch(/管理/);
	});

	it("member 视角同样渲染活动与课程入口卡且无 jargon", async () => {
		params.value = { slug: "cgc-shanghai" };
		render(<WorkspacePage />);
		const main = await content();
		expect(main.getByRole("link", { name: /^活动/ })).toHaveAttribute(
			"href",
			"/w/cgc-shanghai/events",
		);
		expect(main.getByRole("link", { name: /课程/ })).toHaveAttribute(
			"href",
			"/w/cgc-shanghai/courses",
		);
		expect(main.queryByText(/切片 E|即将开放|草稿/)).not.toBeInTheDocument();
	});

	it("普通成员（无 list_members）：管理入口卡（成员与角色/权限映射）整卡不渲染", async () => {
		params.value = { slug: "cgc-shanghai" };
		render(<WorkspacePage />);
		const main = await content();
		// 先等成员视角内容就绪（Hero 渲染完成），再断言管理卡缺席
		await main.findByText("cgc-shanghai");
		expect(main.queryByText("成员与角色")).not.toBeInTheDocument();
		expect(main.queryByText("权限映射")).not.toBeInTheDocument();
		expect(main.queryByText(/查看成员列表与自己的角色/)).not.toBeInTheDocument();
		// 成员可用入口不受影响
		expect(main.getByRole("link", { name: /^活动/ })).toBeInTheDocument();
	});

	it("普通成员空角色标签：Hero 与信息卡显示基准身份「成员」而非「暂无角色」", async () => {
		params.value = { slug: "cgc-shanghai" };
		render(<WorkspacePage />);
		const main = await content();
		// Hero 与「我的角色」信息卡各一处
		expect((await main.findAllByText("成员")).length).toBe(2);
		expect(main.queryByText("暂无角色")).not.toBeInTheDocument();
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
			within(menu).getByRole("menuitem", { name: "Agents" }),
		).toHaveAttribute("href", "/w/cgc-academy/agents");
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

/**
 * 首公里 onboarding 触点（plan 2026-08-22 first-mile-onboarding U3，R1/R2/R8，KTD4/KTD5）。
 *
 * F2（带目的地注册不被打断）由结构保证：邀请模态/常驻卡仅挂本概览页，
 * 登录分发器（home-client.tsx / use-auth-submit.ts）零改动由 diff 保证，
 * 此处锚定「模态确在概览页组件树内」。
 */
describe("首公里 onboarding：邀请模态门控矩阵 + 常驻卡真值表", () => {
	it("未接入 active 成员：模态弹出（展示即 markInviteShown，KTD4），F2 锚点——模态确在概览页", async () => {
		useOnboardingState.mockReturnValue({ ...ONBOARDING_BASE });
		render(<WorkspacePage />);

		expect(await screen.findByRole("dialog")).toBeInTheDocument();
		expect(markInviteShown).toHaveBeenCalledTimes(1);
		// KTD4 旗标按 userId 命名空间写入（共享机器换账号不互相抑制）
		expect(markInviteShown).toHaveBeenCalledWith("u_0202");
	});

	it("关闭路径：「再看看」→ 模态关闭，后续渲染不再复弹（onClose → inviteClosed）", async () => {
		useOnboardingState.mockReturnValue({ ...ONBOARDING_BASE });
		const { rerender } = render(<WorkspacePage />);

		const dialog = await screen.findByRole("dialog");
		fireEvent.click(within(dialog).getByRole("button", { name: "再看看" }));

		await waitFor(() =>
			expect(screen.queryByRole("dialog")).not.toBeInTheDocument(),
		);
		// 后续渲染保持关闭：inviteClosed 已置位，模态不因重渲染复弹
		rerender(<WorkspacePage />);
		await screen.findByRole("heading", { name: "工作区概览" });
		expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
	});

	it("关闭路径：Esc 关闭模态（dialog keyDown 冒泡到 overlay 处理器）", async () => {
		useOnboardingState.mockReturnValue({ ...ONBOARDING_BASE });
		render(<WorkspacePage />);

		const dialog = await screen.findByRole("dialog");
		fireEvent.keyDown(dialog, { key: "Escape" });

		await waitFor(() =>
			expect(screen.queryByRole("dialog")).not.toBeInTheDocument(),
		);
	});

	it("已接入成员（hasActiveToken && connected）：不弹不挂卡（AE5 后半 + DoD 已接入成员零变化）", async () => {
		useOnboardingState.mockReturnValue({
			...ONBOARDING_BASE,
			hasActiveToken: true,
			connected: true,
		});
		render(<WorkspacePage />);

		const main = await content();
		await main.findByText("cgc-academy");
		expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
		expect(
			screen.queryByTestId("onboarding-connect-card"),
		).not.toBeInTheDocument();
	});

	it("已拒绝（dismissed）：不弹，但常驻卡仍在（AE2/R2：dismissed 不影响卡）", async () => {
		useOnboardingState.mockReturnValue({ ...ONBOARDING_BASE, dismissed: true });
		render(<WorkspacePage />);

		const main = await content();
		await main.findByText("cgc-academy");
		expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
		expect(screen.getByTestId("onboarding-connect-card")).toHaveAttribute(
			"data-variant",
			"invite",
		);
	});

	it("readOnlyVisitor（PlatformAdmin 审计视图）：不弹不挂卡", async () => {
		params.value = { slug: "audit-ws" };
		fetchMyWorkspaces.mockResolvedValue([]);
		fetchCurrentProfile.mockResolvedValue({
			id: "u-admin",
			email: "admin@example.com",
			displayName: "Platform Admin",
			isPlatformAdmin: true,
		});
		fetchWorkspaceBySlug.mockResolvedValue({
			id: "ws-audit",
			slug: "audit-ws",
			name: "审计工作台",
			joinPolicy: "invite_only",
			sponsorshipEnabled: true,
			memberCount: 42,
		});
		useOnboardingState.mockReturnValue({ ...ONBOARDING_BASE });
		render(<WorkspacePage />);

		const main = await content();
		await main.findByText("audit-ws");
		expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
		expect(
			screen.queryByTestId("onboarding-connect-card"),
		).not.toBeInTheDocument();
	});

	it("isActiveMember 隔离：pending 成员（成员路径命中，readOnlyVisitor=false）不弹不挂卡", async () => {
		// 只 false isActiveMember 这一个合取项：pending 成员走 fetchMyWorkspaces 正常
		// 成员路径（readOnlyVisitor=false），排除与 readOnlyVisitor 同时 false 的掩盖
		fetchMyWorkspaces.mockResolvedValue([
			{
				id: "ws_pending",
				slug: "cgc-pending",
				name: "待加入工作区",
				joinPolicy: "request" as const,
				sponsorshipEnabled: false,
				myRoleNames: [],
				roles: [],
				myAbilities: ["view_workspace"],
				membershipStatus: "pending" as const,
				memberCount: 7,
			},
		]);
		params.value = { slug: "cgc-pending" };
		useOnboardingState.mockReturnValue({ ...ONBOARDING_BASE });
		render(<WorkspacePage />);

		const main = await content();
		await main.findByText("cgc-pending");
		expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
		expect(
			screen.queryByTestId("onboarding-connect-card"),
		).not.toBeInTheDocument();
	});

	it("onboarding 数据 error：不弹不挂卡（KTD5 fail-closed）", async () => {
		useOnboardingState.mockReturnValue({
			...ONBOARDING_BASE,
			error: new Error("boom"),
		});
		render(<WorkspacePage />);

		const main = await content();
		await main.findByText("cgc-academy");
		expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
		expect(
			screen.queryByTestId("onboarding-connect-card"),
		).not.toBeInTheDocument();
	});

	it("onboarding 数据 loading：不弹不挂卡（KTD5 fail-closed）", async () => {
		// beforeEach 默认即 loading:true；显式重写一遍表意
		useOnboardingState.mockReturnValue({ ...ONBOARDING_BASE, loading: true });
		render(<WorkspacePage />);

		const main = await content();
		await main.findByText("cgc-academy");
		expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
		expect(
			screen.queryByTestId("onboarding-connect-card"),
		).not.toBeInTheDocument();
	});

	it("本 session 已展示过：不再弹（KTD4 旗标），常驻卡仍在，markInviteShown 不再写", async () => {
		useOnboardingState.mockReturnValue({
			...ONBOARDING_BASE,
			inviteShownThisSession: true,
		});
		render(<WorkspacePage />);

		const main = await content();
		await main.findByText("cgc-academy");
		expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
		expect(markInviteShown).not.toHaveBeenCalled();
		expect(screen.getByTestId("onboarding-connect-card")).toBeInTheDocument();
	});

	it("卡真值表：未接入（!active && !connected）→ 邀请态，CTA 跳区入口页", async () => {
		// dismissed:true 避免模态同屏干扰；dismissed 不影响卡（R2）
		useOnboardingState.mockReturnValue({ ...ONBOARDING_BASE, dismissed: true });
		render(<WorkspacePage />);

		await content();
		const card = screen.getByTestId("onboarding-connect-card");
		expect(card).toHaveAttribute("data-variant", "invite");
		expect(
			within(card).getByTestId("onboarding-connect-card-cta"),
		).toHaveAttribute("href", "/w/cgc-academy/settings/integrations/agents");
	});

	it("卡真值表：回归成员（token 全撤销/过期但历史 connected，R1）→ 仍呈邀请态", async () => {
		useOnboardingState.mockReturnValue({
			...ONBOARDING_BASE,
			dismissed: true,
			connected: true,
		});
		render(<WorkspacePage />);

		await content();
		expect(screen.getByTestId("onboarding-connect-card")).toHaveAttribute(
			"data-variant",
			"invite",
		);
	});

	it("卡真值表：已签发未首联（active && !connected）→ 「等待你的 Agent 第一次连接」提醒态（AE5 前半）", async () => {
		useOnboardingState.mockReturnValue({
			...ONBOARDING_BASE,
			hasActiveToken: true,
			connected: false,
		});
		render(<WorkspacePage />);

		await content();
		expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
		const card = screen.getByTestId("onboarding-connect-card");
		expect(card).toHaveAttribute("data-variant", "waiting");
		expect(card).toHaveTextContent("等待你的 Agent 第一次连接");
	});

	it("等待首联态自动撤卡（P2）：window focus 触发静默刷新，connected 置真后卡消失", async () => {
		const refreshSilently = vi.fn();
		let connected = false;
		useOnboardingState.mockImplementation(() => ({
			...ONBOARDING_BASE,
			hasActiveToken: true,
			connected,
			refreshSilently,
		}));
		const { rerender } = render(<WorkspacePage />);

		const card = await screen.findByTestId("onboarding-connect-card");
		expect(card).toHaveAttribute("data-variant", "waiting");

		// 用户切回浏览器：focus 触发静默刷新
		fireEvent.focus(window);
		expect(refreshSilently).toHaveBeenCalledTimes(1);

		// 刷新落地：服务端已写入 lastUsedAt → connected 翻真 → 卡免整页刷新消失
		connected = true;
		rerender(<WorkspacePage />);
		await waitFor(() =>
			expect(
				screen.queryByTestId("onboarding-connect-card"),
			).not.toBeInTheDocument(),
		);
	});

	it("等待首联态（P2）：静默刷新失败（无新数据落地）→ 既有态保持、等待卡不消失", async () => {
		const refreshSilently = vi.fn();
		useOnboardingState.mockReturnValue({
			...ONBOARDING_BASE,
			hasActiveToken: true,
			connected: false,
			refreshSilently,
		});
		render(<WorkspacePage />);

		const card = await screen.findByTestId("onboarding-connect-card");
		expect(card).toHaveAttribute("data-variant", "waiting");

		// 失败轮次不翻状态（hook 保留上次成功快照，契约见 lib/onboarding 测试）
		fireEvent.focus(window);
		expect(refreshSilently).toHaveBeenCalledTimes(1);
		expect(screen.getByTestId("onboarding-connect-card")).toHaveAttribute(
			"data-variant",
			"waiting",
		);
	});

	it("等待首联态（P2）：30s interval 兜底触发静默刷新（分屏不切窗场景）", async () => {
		const refreshSilently = vi.fn();
		useOnboardingState.mockReturnValue({
			...ONBOARDING_BASE,
			hasActiveToken: true,
			connected: false,
			refreshSilently,
		});
		// fake timers 必须先于 render 安装：effect 挂载时建的 interval 才受 fake 时钟管辖
		vi.useFakeTimers();
		try {
			render(<WorkspacePage />);
			// mock fetchers 走微任务落地，无定时器依赖
			await act(async () => {});
			expect(screen.getByTestId("onboarding-connect-card")).toHaveAttribute(
				"data-variant",
				"waiting",
			);

			vi.advanceTimersByTime(30_000);
			expect(refreshSilently).toHaveBeenCalledTimes(1);
			vi.advanceTimersByTime(30_000);
			expect(refreshSilently).toHaveBeenCalledTimes(2);
		} finally {
			vi.useRealTimers();
		}
	});
});
