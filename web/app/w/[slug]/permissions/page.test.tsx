import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import PermissionsPage from "./page";
import {
	PERMISSION_ABILITIES,
	PERMISSION_ROLE_ORDER,
	type PermissionMatrixRow,
} from "@/lib/permissions";

/** 测试本地矩阵 fixture（#1 mock 已删除；形状 = mapPermissionMatrixRows 输出） */
const TEST_MATRIX: PermissionMatrixRow[] = [
	{
		role: "owner",
		abilities: {
			view_workspace: true,
			access_invite_only: true,
			list_members: true,
			manage_members: true,
			assign_roles: true,
			update_join_policy: true,
			create_workspace: false,
		},
	},
	{
		role: "admin",
		abilities: {
			view_workspace: true,
			access_invite_only: true,
			list_members: true,
			manage_members: true,
			assign_roles: true,
			update_join_policy: true,
			create_workspace: false,
		},
	},
	{
		role: "tutor",
		abilities: {
			view_workspace: true,
			access_invite_only: true,
			list_members: false,
			manage_members: false,
			assign_roles: false,
			update_join_policy: false,
			create_workspace: false,
		},
	},
	{
		role: "volunteer",
		abilities: {
			view_workspace: true,
			access_invite_only: true,
			list_members: false,
			manage_members: false,
			assign_roles: false,
			update_join_policy: false,
			create_workspace: false,
		},
	},
	{
		role: "learner",
		abilities: {
			view_workspace: true,
			access_invite_only: true,
			list_members: false,
			manage_members: false,
			assign_roles: false,
			update_join_policy: false,
			create_workspace: false,
		},
	},
];

const { router } = vi.hoisted(() => ({
	router: { push: vi.fn(), replace: vi.fn() },
}));
const { isAuthenticated, clearAuthToken, clearSession } = vi.hoisted(() => ({
	isAuthenticated: vi.fn(),
	clearAuthToken: vi.fn(),
	clearSession: vi.fn(),
}));
const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));

vi.mock("@/lib/use-authed", () => ({ useAuthed }));
const { fetchMatrix } = vi.hoisted(() => ({ fetchMatrix: vi.fn() }));
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
	usePathname: () => `/w/${params.value.slug}/permissions`,
}));

vi.mock("@/lib/auth", () => ({
	isAuthenticated,
	clearAuthToken,
	clearSession,
}));

vi.mock("@/lib/profile", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchCurrentProfile };
});

vi.mock("@/lib/permissions", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchPermissionsMatrix: fetchMatrix };
});

vi.mock("@/lib/workspaces", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchMyWorkspaces };
});

beforeEach(() => {
	vi.clearAllMocks();
	isAuthenticated.mockReturnValue(true);
	useAuthed.mockReturnValue({ authed: true, confirmed: true });
	params.value = { slug: "cgc-academy" };
	fetchMyWorkspaces.mockResolvedValue([
		{
			id: "ws_02",
			slug: "cgc-academy",
			name: "CGC 线上学院",
			joinPolicy: "request",
			sponsorshipEnabled: true,
			myRoleNames: ["admin"],
			roles: ["admin"],
			// #79 IA：管理导航过滤依赖能力列表，管理员夹具需含管理能力
			myAbilities: [
				"view_workspace",
				"access_invite_only",
				"list_members",
				"manage_members",
				"assign_roles",
				"update_join_policy",
			],
			membershipStatus: "active",
		},
	]);
	fetchCurrentProfile.mockResolvedValue({
		id: "u_0202",
		email: "chenyu@cgc2046.org",
		displayName: "陈雨",
		avatarUrl: null,
		isPlatformAdmin: false,
	});
	fetchMatrix.mockResolvedValue(TEST_MATRIX);
});

afterEach(() => cleanup());

async function renderReadyPage() {
	render(<PermissionsPage />);
	await screen.findByRole("heading", {
		name: "查看角色到能力的映射与 can? 判定",
	});
	await waitFor(() =>
		expect(screen.queryByTestId("permissions-loading")).not.toBeInTheDocument(),
	);
}

describe("/w/[slug]/permissions 权限映射页", () => {
	it("未登录重定向到 /login，且不请求权限矩阵", async () => {
		isAuthenticated.mockReturnValue(false);
	useAuthed.mockReturnValue({ authed: false, confirmed: true });
		render(<PermissionsPage />);

		await waitFor(() => expect(router.replace).toHaveBeenCalledWith("/login"));
		expect(fetchMatrix).not.toHaveBeenCalled();
	});

	it("按设计稿渲染工作区设置壳、页签、规则提示和标题", async () => {
		await renderReadyPage();

		expect(screen.getByText("上海 Coding Girls Club")).toBeInTheDocument();
		expect(
			screen.getByRole("heading", { name: "查看角色到能力的映射与 can? 判定" }),
		).toBeInTheDocument();
		expect(screen.getByRole("link", { name: "成员" })).toHaveAttribute(
			"href",
			"/w/cgc-academy/members",
		);
		expect(screen.getByRole("link", { name: "权限映射" })).toHaveAttribute(
			"aria-current",
			"page",
		);
		const shellNav = screen.getByRole("navigation", { name: "工作区设置" });
		const shellLink = within(shellNav).getByRole("link", { name: "加入策略" });
		// #78/#79：壳导航项「加入策略」指向设置页（breadcrumb 首项同名，须限定 nav 内查询）
		expect(shellLink).toHaveAttribute("href", "/w/cgc-academy/settings");
		// 壳 nav 激活态：/permissions 归「成员与角色」子页（⑤ review P3-4）
		expect(
			within(shellNav).getByRole("link", { name: "成员与角色" }),
		).toHaveAttribute("aria-current", "page");
		expect(screen.getByText("多角色取并集")).toBeInTheDocument();
		expect(screen.getByText("租户边界优先")).toBeInTheDocument();
		expect(screen.getByText("Owner 专门指派")).toBeInTheDocument();
	});

	it("展示五个设计角色和七项能力", async () => {
		await renderReadyPage();

		expect(
			screen.getByRole("heading", { name: "权限矩阵" }),
		).toBeInTheDocument();
		for (const role of ["Owner", "Admin", "Tutor", "Volunteer", "Learner"]) {
			expect(
				screen.getByText(role, { selector: ".permissions-role-header" }),
			).toBeInTheDocument();
		}
		for (const ability of PERMISSION_ABILITIES) {
			expect(
				screen.getByTestId(`permission-row-${ability.id}`),
			).toBeInTheDocument();
			expect(
				screen.getByText(ability.label, {
					selector: ".permissions-ability-label strong",
				}),
			).toBeInTheDocument();
		}
		expect(screen.getAllByTestId("permission-ability-status")).toHaveLength(
			PERMISSION_ABILITIES.length,
		);
	});

	it("矩阵语义对齐后端七能力：Owner/Admin 可管理，其他角色只读，create_workspace 平台级不授予", async () => {
		await renderReadyPage();

		expect(screen.getByTestId("cell-owner-manage_members")).toHaveTextContent(
			"✓",
		);
		expect(screen.getByTestId("cell-admin-manage_members")).toHaveTextContent(
			"✓",
		);
		for (const role of ["tutor", "volunteer", "learner"]) {
			expect(
				screen.getByTestId(`cell-${role}-manage_members`),
			).toHaveTextContent("—");
			expect(screen.getByTestId(`cell-${role}-assign_roles`)).toHaveTextContent(
				"—",
			);
		}
		expect(screen.getByTestId("cell-owner-view_workspace")).toHaveTextContent(
			"✓",
		);
		expect(
			screen.getByTestId("cell-owner-access_invite_only"),
		).toHaveTextContent("✓");
		expect(screen.getByTestId("cell-owner-list_members")).toHaveTextContent(
			"✓",
		);
		expect(screen.getByTestId("cell-admin-list_members")).toHaveTextContent(
			"✓",
		);
		for (const role of ["tutor", "volunteer", "learner"]) {
			expect(screen.getByTestId(`cell-${role}-list_members`)).toHaveTextContent(
				"—",
			);
			expect(
				screen.getByTestId(`cell-${role}-view_workspace`),
			).toHaveTextContent("✓");
		}
		// create_workspace 为平台级能力：五角色均不授予（review SUGGESTED 笔误修正）
		for (const role of PERMISSION_ROLE_ORDER) {
			expect(
				screen.getByTestId(`cell-${role}-create_workspace`),
			).toHaveTextContent("—");
		}
		expect(screen.getByText("不含 Owner 角色授予")).toBeInTheDocument();
	});

	it("判定示例展示林溪的 Owner + Tutor 并集，create_workspace 平台级仍拒绝", async () => {
		await renderReadyPage();

		const example = screen.getByTestId("permission-example");
		expect(within(example).getByText("林溪")).toBeInTheDocument();
		expect(within(example).getByText("Owner")).toBeInTheDocument();
		expect(within(example).getByText("Tutor")).toBeInTheDocument();
		expect(within(example).getByText("can? = true")).toBeInTheDocument();
		expect(
			within(example).getByText("允许", {
				selector: ".permissions-example__result span",
			}),
		).toBeInTheDocument();

		const statuses = within(example).getAllByTestId(
			"permission-ability-status",
		);
		// #78：新增 update_join_policy（Owner+Tutor 并集 → 允许），拒绝项为平台级 create_workspace
		expect(statuses).toHaveLength(7);
		expect(
			statuses.slice(0, 6).every((item) => item.textContent?.includes("允许")),
		).toBe(true);
		expect(statuses[6]).toHaveTextContent("创建工作台");
		expect(statuses[6]).toHaveTextContent("拒绝");
	});

	it("未知 slug 显示不可访问状态，不请求权限矩阵", async () => {
		params.value = { slug: "no-such-ws" };
		render(<PermissionsPage />);

		expect(
			await screen.findByRole("heading", { name: "工作区不可访问" }),
		).toBeInTheDocument();
		expect(
			screen.getByText("no-such-ws", { exact: false }),
		).toBeInTheDocument();
		expect(fetchMatrix).not.toHaveBeenCalled();
	});

	it("按当前 slug 解析真实 workspace，并在切换 slug 时重新请求矩阵", async () => {
		await renderReadyPage();
		expect(fetchMatrix).toHaveBeenCalledTimes(1);

		params.value = { slug: "be-verify-ws-456" };
		// 双 useWorkspaceBySlug 实例（壳 + 页面）会各消费一次 mock：用持久 mockResolvedValue
		// 建模生产语义（两实例拿到相同数据，Apollo 同查询去重），不用 mockResolvedValueOnce
		fetchMyWorkspaces.mockResolvedValue([
			{
				id: "ws_real_perm",
				slug: "be-verify-ws-456",
				name: "BE 验证权限工作区",
				joinPolicy: "request",
				sponsorshipEnabled: true,
				myRoleNames: ["admin", "member"],
				roles: ["admin", "member"],
				membershipStatus: "active",
			},
		]);
		cleanup();
		fetchMatrix.mockClear();
		await renderReadyPage();
		expect(fetchMatrix).toHaveBeenCalledTimes(1);
	});

	it("工作区列表没有匹配 slug 时不渲染矩阵", async () => {
		params.value = { slug: "not-in-any-list" };
		render(<PermissionsPage />);

		expect(
			await screen.findByRole("heading", { name: "工作区不可访问" }),
		).toBeInTheDocument();
		expect(fetchMatrix).not.toHaveBeenCalled();
	});

	it("矩阵 fixture 完整性：五角色 × 七能力，每个能力都有 boolean", () => {
		expect(TEST_MATRIX).toHaveLength(5);
		expect(TEST_MATRIX.map((row) => row.role)).toEqual(PERMISSION_ROLE_ORDER);
		for (const row of TEST_MATRIX) {
			for (const ability of PERMISSION_ABILITIES) {
				expect(typeof row.abilities[ability.id]).toBe("boolean");
			}
		}
	});

	it("提供个人资料入口并支持退出登录", async () => {
		await renderReadyPage();

		expect(screen.getByTestId("profile-entry")).toHaveAttribute(
			"href",
			"/profile?ws=cgc-academy",
		);
		screen.getByRole("button", { name: "退出登录" }).click();
		expect(clearSession).toHaveBeenCalledTimes(1);
		await waitFor(() => expect(router.push).toHaveBeenCalledWith("/login"));
	});
});
