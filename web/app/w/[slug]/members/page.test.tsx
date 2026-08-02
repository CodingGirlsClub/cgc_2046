import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
	cleanup,
	fireEvent,
	screen,
	waitFor,
	within,
} from "@testing-library/react";
import { render } from "@/test-utils";
import MembersPage from "./page";
import type { WorkspaceMember } from "@/lib/workspaces";

/** 测试本地工作台 fixture（#1 mock 已删除；canAssign 现消费 ws.myAbilities 能力接口） */
const TEST_WORKSPACES = [
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
	},
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
		],
		membershipStatus: "active" as const,
	},
];

/** 测试本地成员 fixture（与旧 MOCK_MEMBERS 同形状） */
const TEST_MEMBERS: Record<string, WorkspaceMember[]> = {
	ws_01: [
		{
			membershipId: "wm_0101",
			userId: "u_0101",
			email: "xiaomei@example.com",
			displayName: "小美",
			joinedAt: "2024-03-12",
			roles: ["owner"],
		},
		{
			membershipId: "wm_0102",
			userId: "u_0102",
			email: "cheng@example.com",
			displayName: "阿成",
			joinedAt: "2024-04-08",
			roles: ["admin", "member"],
		},
		{
			membershipId: "wm_0103",
			userId: "u_0103",
			email: "lucy@example.com",
			displayName: "Lucy",
			joinedAt: "2025-01-16",
			roles: ["member"],
		},
		{
			membershipId: "wm_0104",
			userId: "u_0104",
			email: "frank@example.com",
			displayName: "Frank",
			joinedAt: "2025-05-21",
			roles: ["member"],
		},
	],
	ws_02: [
		{
			membershipId: "wm_0201",
			userId: "u_0201",
			email: "linxi@cgc2046.org",
			displayName: "林溪",
			joinedAt: "2024-03-12",
			roles: ["owner", "tutor"],
		},
		{
			membershipId: "wm_0202",
			userId: "u_0202",
			email: "chenyu@cgc2046.org",
			displayName: "陈雨",
			joinedAt: "2024-04-08",
			roles: ["admin"],
		},
		{
			membershipId: "wm_0203",
			userId: "u_0203",
			email: "zhouning@cgc2046.org",
			displayName: "周宁",
			joinedAt: "2025-01-16",
			roles: ["tutor", "volunteer"],
		},
		{
			membershipId: "wm_0204",
			userId: "u_0204",
			email: "suman@cgc2046.org",
			displayName: "苏曼",
			joinedAt: "2025-05-21",
			roles: ["volunteer"],
		},
		{
			membershipId: "wm_0205",
			userId: "u_0205",
			email: "hemiao@cgc2046.org",
			displayName: "何苗",
			joinedAt: "2026-07-30",
			roles: ["learner"],
		},
	],
};

const { router } = vi.hoisted(() => ({
	router: { push: vi.fn(), replace: vi.fn() },
}));
const { isAuthenticated, clearAuthToken } = vi.hoisted(() => ({
	isAuthenticated: vi.fn(),
	clearAuthToken: vi.fn(),
}));
const { fetchMembers, assignRoles } = vi.hoisted(() => ({
	fetchMembers: vi.fn(),
	assignRoles: vi.fn(),
}));
const { fetchMyWorkspaces } = vi.hoisted(() => ({
	fetchMyWorkspaces: vi.fn(),
}));
const { params } = vi.hoisted(() => ({
	params: { value: { slug: "cgc-academy" } },
}));
const { fetchCurrentProfile } = vi.hoisted(() => ({
	fetchCurrentProfile: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	useRouter: () => router,
	useParams: () => params.value,
	usePathname: () => `/w/${params.value.slug}/members`,
}));

vi.mock("@/lib/auth", () => ({ isAuthenticated, clearAuthToken }));

vi.mock("@/lib/profile", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchCurrentProfile };
});

vi.mock("@/lib/workspaces", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return {
		...mod,
		fetchWorkspaceMembers: fetchMembers,
		assignMemberRoles: assignRoles,
		fetchMyWorkspaces,
	};
});

beforeEach(() => {
	vi.clearAllMocks();
	isAuthenticated.mockReturnValue(true);
	params.value = { slug: "cgc-academy" };
	fetchMyWorkspaces.mockResolvedValue(
		TEST_WORKSPACES.map((ws) =>
			ws.slug === "cgc-academy" ? { ...ws, memberCount: 5 } : ws,
		),
	);
	fetchCurrentProfile.mockResolvedValue({
		id: "u_0202",
		email: "xiaomei@example.com",
		displayName: "小美",
		avatarUrl: null,
		isPlatformAdmin: false,
	});
	fetchMembers.mockResolvedValue(TEST_MEMBERS.ws_02);
	assignRoles.mockImplementation(
		async (membershipId: string, roleNames: string[]) => {
			const member = TEST_MEMBERS.ws_02.find(
				(item) => item.membershipId === membershipId,
			);
			if (!member) throw new Error("member not found");
			return { ...member, roles: roleNames } as WorkspaceMember;
		},
	);
});

afterEach(cleanup);

describe("成员与角色管理页 /w/[slug]/members (#65)", () => {
	it("未登录：重定向 /login 且不请求成员", async () => {
		isAuthenticated.mockReturnValue(false);
		render(<MembersPage />);
		await waitFor(() => expect(router.replace).toHaveBeenCalledWith("/login"));
		expect(fetchMembers).not.toHaveBeenCalled();
	});

	it("按设计稿渲染 Workspace 管理壳、成员表和角色并集提示", async () => {
		render(<MembersPage />);

		expect(
			await screen.findByRole("heading", { name: "成员与角色" }),
		).toBeInTheDocument();
		expect(screen.getByText("管理工作区成员与角色分配")).toBeInTheDocument();
		expect(screen.getByText("多角色权限取并集")).toBeInTheDocument();
		expect(
			screen.getByText(/租户数据仅在当前 Workspace 内可见/),
		).toBeInTheDocument();
		expect(screen.getAllByText("CGC 线上学院").length).toBeGreaterThan(0);
		expect(
			(await screen.findAllByText("linxi@cgc2046.org")).length,
		).toBeGreaterThan(0);
		expect(screen.getAllByText("Owner").length).toBeGreaterThan(0);
		expect(screen.getAllByText("Admin").length).toBeGreaterThan(0);
		expect(screen.getAllByText("Tutor").length).toBeGreaterThan(0);
		expect(screen.getAllByText("Volunteer").length).toBeGreaterThan(0);
		expect(screen.getAllByText("Learner").length).toBeGreaterThan(0);
		expect(screen.getByText("共 5 位成员")).toBeInTheDocument();
		expect(screen.getAllByTestId("member-row")).toHaveLength(5);
	});

	it("角色并集展示：同一成员的多个角色在同一行同时出现", async () => {
		render(<MembersPage />);
		const rows = await screen.findAllByTestId("member-row");
		const memberRow = rows.find((row) =>
			within(row).queryByText("林溪"),
		) as HTMLElement;
		expect(memberRow).toBeDefined();
		expect(within(memberRow).getAllByTestId("role-badge")).toHaveLength(2);
		expect(within(memberRow).getByText("Owner")).toBeInTheDocument();
		expect(within(memberRow).getByText("Tutor")).toBeInTheDocument();
	});

	it("U2：Owner 行锁定专门指派，不提供行内 Owner 编辑", async () => {
		render(<MembersPage />);
		const ownerRow = (await screen.findAllByTestId("member-row"))[0];
		const dedicated = within(ownerRow).getByRole("button", {
			name: /专门指派/,
		});
		expect(dedicated).toBeDisabled();
		expect(dedicated).toHaveAttribute(
			"title",
			expect.stringContaining("专门指派流程"),
		);
		expect(
			within(ownerRow).queryByRole("button", { name: /编辑角色/ }),
		).not.toBeInTheDocument();
	});

	it("Owner/Admin 可打开非 Owner 行编辑器，选项排除 Owner 并保存整组角色", async () => {
		render(<MembersPage />);
		const rows = await screen.findAllByTestId("member-row");
		const memberRow = rows.find((row) =>
			within(row).queryByText("陈雨"),
		) as HTMLElement;
		fireEvent.click(
			within(memberRow).getByRole("button", { name: "编辑角色" }),
		);

		expect(within(memberRow).getByTestId("role-editor")).toBeInTheDocument();
		expect(within(memberRow).getAllByRole("checkbox")).toHaveLength(4);
		expect(
			within(memberRow).queryByLabelText("Owner 角色"),
		).not.toBeInTheDocument();

		// 陈雨当前为 Admin，新增 Tutor 后保存为两角色并集。
		fireEvent.click(
			within(memberRow).getByRole("checkbox", { name: "Admin 角色" }),
		);
		fireEvent.click(
			within(memberRow).getByRole("checkbox", { name: "Tutor 角色" }),
		);
		fireEvent.click(
			within(memberRow).getByRole("button", { name: "保存角色" }),
		);
		await waitFor(() =>
			expect(assignRoles).toHaveBeenCalledWith("wm_0202", ["tutor"]),
		);
		expect(within(memberRow).getByText("Tutor")).toBeInTheDocument();
		expect(
			within(memberRow).queryByTestId("role-editor"),
		).not.toBeInTheDocument();
	});

	it("搜索与角色筛选只影响当前表格可见行", async () => {
		render(<MembersPage />);
		await screen.findAllByTestId("member-row");
		fireEvent.change(screen.getByRole("textbox", { name: "搜索姓名或邮箱" }), {
			target: { value: "linxi" },
		});
		expect(screen.getAllByTestId("member-row")).toHaveLength(1);
		expect(screen.getByText("林溪")).toBeInTheDocument();

		fireEvent.change(screen.getByRole("combobox", { name: "筛选角色" }), {
			target: { value: "learner" },
		});
		expect(screen.queryAllByTestId("member-row")).toHaveLength(0);
		expect(screen.getByText("没有匹配的成员")).toBeInTheDocument();
	});

	it("非 Owner/Admin 只能查看角色，没有编辑操作", async () => {
		params.value = { slug: "cgc-shanghai" };
		fetchMembers.mockResolvedValue(TEST_MEMBERS.ws_01);
		render(<MembersPage />);
		expect((await screen.findAllByText("仅查看")).length).toBeGreaterThan(0);
		expect(
			screen.queryByRole("button", { name: /编辑角色/ }),
		).not.toBeInTheDocument();
		expect(screen.queryAllByRole("checkbox")).toHaveLength(0);
		expect(screen.getAllByTestId("member-row")).toHaveLength(4);
		expect(assignRoles).not.toHaveBeenCalled();
	});

	it("P2-5：非 Owner/Admin 视角下，主计数用 memberCount 并标注可见范围", async () => {
		// 模拟 QA 场景：工作区物理总人数 2（owner + learner），但 learner 经 read policy
		// 只能看到自己 1 条 membership → memberCount=2 vs workspaceMembers=1。
		params.value = { slug: "cgc-academy" };
		fetchMyWorkspaces.mockResolvedValue([
			{
				id: "ws_02",
				slug: "cgc-academy",
				name: "CGC 线上学院",
				joinPolicy: "request",
				sponsorshipEnabled: true,
				memberCount: 2,
				myRoleNames: ["learner"],
				roles: ["learner"],
				myAbilities: ["view_workspace", "access_invite_only"],
				membershipStatus: "active",
			},
		]);
		fetchMembers.mockResolvedValue([TEST_MEMBERS.ws_02[4]]); // learner 只能看到自己（何苗）
		render(<MembersPage />);

		// 先等成员列表落地再断言计数（findByTestId 只等元素出现，不等 fetch；
		// 计数文本与成员行同一次 setState，行出现后文本必然正确）
		await screen.findAllByTestId("member-row");
		expect(screen.getByTestId("members-count")).toHaveTextContent(
			"共 2 位成员（当前仅显示你有权查看的 1 位）",
		);
		expect(screen.getByTestId("members-visibility-note")).toHaveTextContent(
			"仅显示你有权查看的成员（工作区共 2 位成员）",
		);
		expect(screen.getAllByTestId("member-row")).toHaveLength(1);
		// 非 Owner/Admin 不提供行内编辑入口
		expect(
			screen.queryByRole("button", { name: /编辑角色/ }),
		).not.toBeInTheDocument();
	});

	it("P2-5：Owner/Admin 视角 memberCount 与可见列表一致时不加标注", async () => {
		// 默认 beforeEach：cgc-academy 为 admin，memberCount 覆盖为 5 与列表一致。
		render(<MembersPage />);
		await screen.findAllByTestId("member-row");
		expect(screen.getByTestId("members-count")).toHaveTextContent(
			"共 5 位成员",
		);
		expect(
			screen.queryByTestId("members-visibility-note"),
		).not.toBeInTheDocument();
	});

	it("页签入口：成员选中，权限映射指向 #67，个人资料指向 #69", async () => {
		render(<MembersPage />);
		expect(
			await screen.findByRole("link", { name: "权限映射" }),
		).toHaveAttribute("href", "/w/cgc-academy/permissions");
		expect(screen.getByRole("link", { name: "成员与角色" })).toHaveAttribute(
			"aria-current",
			"page",
		);
		expect(screen.getByTestId("profile-entry")).toHaveAttribute(
			"href",
			"/profile?ws=cgc-academy",
		);
	});

	it("未知 slug：展示不可访问提示和返回工作台", async () => {
		params.value = { slug: "not-exist" };
		render(<MembersPage />);
		expect(
			await screen.findByText(/不存在或你没有访问权限/),
		).toBeInTheDocument();
		expect(screen.getByRole("link", { name: "返回工作台" })).toHaveAttribute(
			"href",
			"/",
		);
		expect(fetchMembers).not.toHaveBeenCalled();
	});

	it("自杀式降权防护：Admin 编辑自己行移除 admin，确认框取消则不提交", async () => {
		fetchMyWorkspaces.mockResolvedValue([
			{
				id: "ws_02",
				slug: "cgc-academy",
				name: "CGC 线上学院",
				joinPolicy: "request",
				sponsorshipEnabled: true,
				myRoleNames: ["admin"],
				myMembershipId: "wm_0202",
				roles: ["admin"],
				myAbilities: [
					"view_workspace",
					"access_invite_only",
					"list_members",
					"manage_members",
					"assign_roles",
				],
				membershipStatus: "active",
			},
		]);
		const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(false);
		render(<MembersPage />);
		const rows = await screen.findAllByTestId("member-row");
		const selfRow = rows.find((row) =>
			within(row).queryByText("陈雨"),
		) as HTMLElement;
		fireEvent.click(within(selfRow).getByRole("button", { name: "编辑角色" }));
		// 取消 Admin 勾选（原本仅 admin）
		fireEvent.click(
			within(selfRow).getByRole("checkbox", { name: "Admin 角色" }),
		);
		fireEvent.click(within(selfRow).getByRole("button", { name: "保存角色" }));
		await waitFor(() => expect(confirmSpy).toHaveBeenCalled());
		expect(assignRoles).not.toHaveBeenCalled();
		confirmSpy.mockRestore();
	});

	it("自杀式降权防护：确认后允许移除自身 admin", async () => {
		fetchMyWorkspaces.mockResolvedValue([
			{
				id: "ws_02",
				slug: "cgc-academy",
				name: "CGC 线上学院",
				joinPolicy: "request",
				sponsorshipEnabled: true,
				myRoleNames: ["admin"],
				myMembershipId: "wm_0202",
				roles: ["admin"],
				myAbilities: [
					"view_workspace",
					"access_invite_only",
					"list_members",
					"manage_members",
					"assign_roles",
				],
				membershipStatus: "active",
			},
		]);
		const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(true);
		render(<MembersPage />);
		const rows = await screen.findAllByTestId("member-row");
		const selfRow = rows.find((row) =>
			within(row).queryByText("陈雨"),
		) as HTMLElement;
		fireEvent.click(within(selfRow).getByRole("button", { name: "编辑角色" }));
		fireEvent.click(
			within(selfRow).getByRole("checkbox", { name: "Admin 角色" }),
		);
		fireEvent.click(within(selfRow).getByRole("button", { name: "保存角色" }));
		await waitFor(() =>
			expect(assignRoles).toHaveBeenCalledWith("wm_0202", []),
		);
		confirmSpy.mockRestore();
	});

	it("自杀式降权防护：编辑他人（非自己）移除 admin 不弹确认", async () => {
		fetchMyWorkspaces.mockResolvedValue([
			{
				id: "ws_02",
				slug: "cgc-academy",
				name: "CGC 线上学院",
				joinPolicy: "request",
				sponsorshipEnabled: true,
				myRoleNames: ["admin"],
				myMembershipId: "wm_0202",
				roles: ["admin"],
				myAbilities: [
					"view_workspace",
					"access_invite_only",
					"list_members",
					"manage_members",
					"assign_roles",
				],
				membershipStatus: "active",
			},
		]);
		const confirmSpy = vi.spyOn(window, "confirm");
		render(<MembersPage />);
		const rows = await screen.findAllByTestId("member-row");
		// 周宁（wm_0203）不是自己，但持有 tutor+volunteer；无 admin，不会触发确认。
		const otherRow = rows.find((row) =>
			within(row).queryByText("周宁"),
		) as HTMLElement;
		fireEvent.click(within(otherRow).getByRole("button", { name: "编辑角色" }));
		fireEvent.click(
			within(otherRow).getByRole("checkbox", { name: "Tutor 角色" }),
		);
		fireEvent.click(within(otherRow).getByRole("button", { name: "保存角色" }));
		await waitFor(() => expect(assignRoles).toHaveBeenCalled());
		expect(confirmSpy).not.toHaveBeenCalled();
		confirmSpy.mockRestore();
	});

	it("真实 Workspace 上下文仍通过 fetchMyWorkspaces 与成员数据渲染", async () => {
		fetchMyWorkspaces.mockResolvedValue([
			{
				id: "ws_real_9",
				slug: "qa70-owner-ws-999",
				name: "QA70 真实工作区",
				joinPolicy: "open",
				sponsorshipEnabled: true,
				myRoleNames: ["owner"],
				roles: ["owner"],
				membershipStatus: "active",
			},
		]);
		params.value = { slug: "qa70-owner-ws-999" };
		fetchMembers.mockResolvedValue([
			{
				membershipId: "wm_r9",
				userId: "u_r9",
				email: "qa.member@example.com",
				roles: ["owner"],
			},
		]);

		render(<MembersPage />);
		expect(
			(await screen.findAllByText("QA70 真实工作区")).length,
		).toBeGreaterThan(0);
		expect(
			(await screen.findAllByText("qa.member@example.com")).length,
		).toBeGreaterThan(0);
		expect(screen.getByRole("link", { name: "权限映射" })).toHaveAttribute(
			"href",
			"/w/qa70-owner-ws-999/permissions",
		);
		expect(fetchMembers).toHaveBeenCalledWith("ws_real_9");
	});

	it("真实 Workspace 的普通成员视角不显示编辑按钮", async () => {
		fetchMyWorkspaces.mockResolvedValue([
			{
				id: "ws_real_m",
				slug: "dbg5-member-ws-777",
				name: "DBG5 成员工作区",
				joinPolicy: "request",
				sponsorshipEnabled: true,
				myRoleNames: ["member"],
				roles: ["member"],
				membershipStatus: "active",
			},
		]);
		params.value = { slug: "dbg5-member-ws-777" };
		fetchMembers.mockResolvedValue([
			{
				membershipId: "wm_rm",
				userId: "u_rm",
				email: "me@example.com",
				roles: ["member"],
			},
		]);

		render(<MembersPage />);
		expect(
			(await screen.findAllByText("DBG5 成员工作区")).length,
		).toBeGreaterThan(0);
		expect(
			screen.queryByRole("button", { name: /编辑角色/ }),
		).not.toBeInTheDocument();
		expect((await screen.findAllByText("仅查看")).length).toBeGreaterThan(0);
	});

	it("P1 平铺字段：真实分支返回 userEmail/userDisplayName/joinedAt → 成员表展示平铺数据", async () => {
		fetchMyWorkspaces.mockResolvedValue([
			{
				id: "ws_real_t",
				slug: "p1-flat-ws-666",
				name: "P1 平铺字段工作区",
				joinPolicy: "open",
				sponsorshipEnabled: true,
				myRoleNames: ["owner"],
				roles: ["owner"],
				membershipStatus: "active",
			},
		]);
		params.value = { slug: "p1-flat-ws-666" };
		// 直接按后端 workspaceMembers 契约形状返回平铺字段
		fetchMembers.mockResolvedValue([
			{
				membershipId: "wm_ft",
				userId: "u_ft",
				email: "flat.member@example.com",
				displayName: "平铺成员",
				joinedAt: "2026-08-02T03:00:00Z",
				roles: ["tutor"],
			},
		]);

		render(<MembersPage />);
		expect((await screen.findAllByText("平铺成员")).length).toBeGreaterThan(0);
		expect(
			(await screen.findAllByText("flat.member@example.com")).length,
		).toBeGreaterThan(0);
		// ISO joinedAt 格式化为中文年月（P1）
		expect(screen.getByText("2026 年 8 月")).toBeInTheDocument();
	});
});

describe("成员角色数据源（测试 fixture）", () => {
	it("fixture 包含设计稿所需的成员数量与角色并集", () => {
		expect(TEST_MEMBERS.ws_01.length).toBeGreaterThan(0);
		expect(TEST_MEMBERS.ws_02).toHaveLength(5);
		expect(TEST_MEMBERS.ws_02.map((member) => member.displayName)).toEqual([
			"林溪",
			"陈雨",
			"周宁",
			"苏曼",
			"何苗",
		]);
		expect(TEST_MEMBERS.ws_02[0].roles).toEqual(["owner", "tutor"]);
		expect(TEST_MEMBERS.ws_02.some((member) => member.roles.length > 1)).toBe(
			true,
		);
		expect(
			TEST_WORKSPACES.find((workspace) => workspace.slug === "cgc-academy")
				?.myRoleNames,
		).toEqual(["admin"]);
	});
});
